"""Clinician scope. Every call is limited to the clinician's own clinic:
keys are built from the token's clinic id, never from the request."""

from datetime import timedelta

from fastapi import APIRouter, Depends, Path, Request

from .. import service
from ..audit import write_audit
from ..mind import views
from ..models import LoginIn, LoginOut
from ..security import Principal, dummy_verify, issue_token, sha256_hex, verify_password
from ..service import ApiError
from .deps import clinician_only, ctx_of, errors, open_rate_limit, rid_of

router = APIRouter(prefix="/v1/clinic", tags=["clinician"])

SID = r"^[a-z]{1,6}_[0-9a-f]{24}$"
CID = r"^[A-Za-z0-9_-]{8,64}$"


@router.post("/login", response_model=LoginOut, responses=errors(401, 422, 429),
             summary="Clinician login, returns a short-lived session token")
async def login(body: LoginIn, request: Request):
    open_rate_limit(request, "login")
    ctx = ctx_of(request)
    now = ctx.clock.now()
    idx = ctx.store.get(f"usernames/{sha256_hex(body.username.strip().lower())}.json")
    rec = ctx.store.get(f"clinics/{idx['clinic_id']}/clinicians/{idx['clinician_id']}.json") \
        if idx else None
    if rec is None:
        dummy_verify(body.password)
        ok = False
    else:
        ok = verify_password(body.password, rec["password_hash"])
    if not ok:
        write_audit(ctx.store, now, clinic_id=idx["clinic_id"] if idx else None, patient_id=None,
                    actor="anonymous", action="login", outcome="refused", reason="bad_credentials",
                    request_id=rid_of(request))
        raise ApiError(401, "unauthorized", "Wrong username or password.")
    ttl = timedelta(minutes=ctx.settings.session_ttl_minutes)
    token = issue_token(ctx.store, "clinician", clinic_id=rec["clinic_id"],
                        clinician_id=rec["id"], ttl=ttl, now=now)
    write_audit(ctx.store, now, clinic_id=rec["clinic_id"], patient_id=None,
                actor=f"clinician:{rec['id']}", action="login", request_id=rid_of(request))
    return {"session_token": token, "expires_at": (now + ttl).isoformat()}


def _patient_repo(request: Request, p: Principal, patient_id: str):
    ctx = ctx_of(request)
    repo = ctx.mind.repo(p.clinic_id, patient_id)
    if repo.patient() is None:
        write_audit(ctx.store, ctx.clock.now(), clinic_id=p.clinic_id, patient_id=None,
                    actor=p.actor, action="patient_read", outcome="refused",
                    reason="patient_not_in_clinic", detail={"patient_id": patient_id},
                    request_id=rid_of(request))
        raise ApiError(404, "not_found", "Patient not found.")
    return repo


@router.get("/patients", responses=errors(401, 403, 429),
            summary="One line per patient in your clinic")
async def patients(request: Request, p: Principal = Depends(clinician_only)):
    """Status, held attention items (kind, level, since), last data day and a
    short plain summary. Built from data and thresholds only."""
    ctx = ctx_of(request)
    lines = []
    for key in ctx.store.list(f"clinics/{p.clinic_id}/patients/"):
        if key.endswith("/patient.json"):
            pid = key.split("/")[3]
            lines.append(views.clinician_line(ctx.mind, ctx.mind.repo(p.clinic_id, pid)))
    order = {"urgent": 0, "attention": 1, "watch": 2, None: 3}
    lines.sort(key=lambda x: (order[x["level"]], x["label"]))
    return {"patients": lines}


@router.get("/patients/{patient_id}", responses=errors(401, 403, 404, 429),
            summary="Timeline, attention, suggestions, lessons with provenance, refusals, progress")
async def patient_detail(request: Request, patient_id: str = Path(pattern=SID),
                         p: Principal = Depends(clinician_only)):
    ctx = ctx_of(request)
    return views.clinician_detail(ctx.mind, _patient_repo(request, p, patient_id))


@router.get("/patients/{patient_id}/rounds/{round_id}", responses=errors(401, 403, 404, 429),
            summary="One round: features, path for the trail, checked reading and dropped claims")
async def patient_round(request: Request, patient_id: str = Path(pattern=SID),
                        round_id: str = Path(pattern=CID),
                        p: Principal = Depends(clinician_only)):
    out = views.clinician_round(_patient_repo(request, p, patient_id), round_id)
    if out is None:
        raise ApiError(404, "not_found", "Round not found.")
    return out


@router.post("/attention/{attention_id}/ack", responses=errors(401, 403, 404, 409, 429),
             summary="Acknowledge an attention item")
async def ack(request: Request, attention_id: str = Path(pattern=SID),
              p: Principal = Depends(clinician_only)):
    """Closes the held item. The same evidence does not reopen it; fresh
    evidence does. The status still follows the data."""
    return await service.ack_attention(ctx_of(request), p, attention_id, rid_of(request))
