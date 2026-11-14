"""Clinician scope. Every call is limited to the clinician's own clinic:
keys are built from the token's clinic id, never from the request."""

from datetime import timedelta

from typing import Optional

from fastapi import APIRouter, Depends, Path, Query, Request

from .. import service
from ..audit import write_audit
from ..mind import trace as trace_mod
from ..mind import views
from ..mind.watchers import compute_status
from ..mind import associations as assoc
from ..models import (AssociationsOut, ClinicMeOut, FaceRawOut, LoginIn, LoginOut, RatingIn,
                      RatingOut, RatingsOut, TraceOut)
from ..security import (Principal, dummy_verify, issue_token, new_id, sha256_hex,
                        verify_password)
from ..service import ApiError
from .deps import (clinician_only, clinician_or_admin, ctx_of, demo_clinic_id, errors,
                   open_rate_limit, rid_of)

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


@router.get("/me", response_model=ClinicMeOut, responses=errors(401, 403, 429),
            summary="What the clinician page needs to start: product name, clinic, demo mode")
async def me(request: Request, p: Principal = Depends(clinician_only)):
    """`demo.enabled` is true only while DEMO_ENABLED is on AND this clinician
    belongs to the seeded demo clinic; only then may the page show the demo
    panel (the demo endpoints check the same rule)."""
    ctx = ctx_of(request)
    clinic = ctx.store.get(f"clinics/{p.clinic_id}/clinic.json") or {}
    demo_on = demo_clinic_id(ctx) == p.clinic_id
    st = (ctx.store.get("demo/state.json") or {}) if demo_on else {}
    return {"product_name": ctx.settings.product_name,
            "clinic_name": clinic.get("name", ""),
            "demo": {"enabled": demo_on, "patient_id": st.get("patient_id")}}


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
    # The patient index, not a listing of every object the clinic holds.
    for clinic_id, pid in ctx.mind.all_patients():
        if clinic_id == p.clinic_id:
            lines.append(views.clinician_line(ctx.mind, ctx.mind.repo(p.clinic_id, pid)))
    order = {"urgent": 0, "attention": 1, "watch": 2, None: 3}
    status_order = {"outside": 0, "no_data": 1, "no_baseline": 2, "within": 3}
    lines.sort(key=lambda x: (order[x["level"]], status_order.get(x["status"], 4), x["label"]))
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
    ctx = ctx_of(request)
    out = views.clinician_round(_patient_repo(request, p, patient_id), round_id, ctx.mind)
    if out is None:
        raise ApiError(404, "not_found", "Round not found.")
    return out


@router.get("/patients/{patient_id}/activities/{activity_id}/face-raw",
            response_model=FaceRawOut, responses=errors(401, 403, 404, 429),
            summary="Raw face frames of one activity, as the phone sent them (research download)")
async def patient_face_raw(request: Request, patient_id: str = Path(pattern=SID),
                           activity_id: str = Path(pattern=CID),
                           p: Principal = Depends(clinician_only)):
    """Only for focus and breathing sessions sent with `face_raw`; 404 otherwise.
    Numbers only: blend-shape coefficients and head angles per frame. Each
    download is audited (which activity, never any values)."""
    ctx = ctx_of(request)
    repo = _patient_repo(request, p, patient_id)
    raw = repo.get(f"faceraw/{activity_id}.json")
    if raw is None:
        raise ApiError(404, "not_found", "No raw face frames for this activity.")
    write_audit(ctx.store, ctx.clock.now(), clinic_id=p.clinic_id, patient_id=patient_id,
                actor=p.actor, action="face_raw_read", detail={"activity_id": activity_id},
                request_id=rid_of(request))
    return raw


@router.get("/patients/{patient_id}/exchanges", responses=errors(401, 403, 404, 422, 429),
            summary="Raw model exchanges: what was sent to a model and what it answered")
async def patient_exchanges(request: Request, patient_id: str = Path(pattern=SID),
                            task: Optional[str] = Query(None, pattern=r"^[a-z_]{1,30}$"),
                            chain_id: Optional[str] = Query(None, pattern=SID),
                            limit: int = Query(50, ge=1, le=200),
                            p: Principal = Depends(clinician_only)):
    """Newest first. Each item holds the messages sent, the raw reply (null when the
    model did not answer), the model name, the time it took and the trace chain it
    belongs to. What code did with the reply is in the trace. A note's prompt
    contains the patient's words; that message is hidden unless the patient shares
    their notes."""
    from ..mind import exchanges as ex
    ctx = ctx_of(request)
    repo = _patient_repo(request, p, patient_id)
    share = bool((repo.patient() or {}).get("share_notes"))
    return {"share_notes": share,
            "exchanges": ex.view(ctx.store, p.clinic_id, patient_id, share, limit, task, chain_id)}


@router.get("/patients/{patient_id}/trace", response_model=TraceOut,
            responses=errors(401, 403, 404, 422, 429),
            summary="How the mind reasoned: chains of steps per trigger, newest first")
async def patient_trace(request: Request, patient_id: str = Path(pattern=SID),
                        chain_id: Optional[str] = Query(None, pattern=SID),
                        attention_id: Optional[str] = Query(None, pattern=SID),
                        changed_only: bool = Query(False, description="Only chains that changed "
                                                   "something."),
                        limit: int = Query(30, ge=1, le=100),
                        p: Principal = Depends(clinician_only)):
    """Each chain ties together everything one trigger caused, layer by layer:
    trigger, watchers, attention, response (code), level 1, level 2, notifier,
    learning. `current` explains each held attention item: its level, the rule
    that set it, and what the system last did about it. Codes, ids, enums and
    numbers only: never note text."""
    ctx = ctx_of(request)
    repo = _patient_repo(request, p, patient_id)
    entries = trace_mod.load_entries(ctx.store, p.clinic_id, patient_id)
    return {"status": compute_status(ctx.mind.build_view(repo)),
            "current": trace_mod.current_state(entries, repo.items()),
            "chains": trace_mod.chains(entries, chain_id, attention_id, changed_only, limit)}


@router.post("/attention/{attention_id}/ack", responses=errors(401, 403, 404, 409, 429),
             summary="Acknowledge an attention item")
async def ack(request: Request, attention_id: str = Path(pattern=SID),
              p: Principal = Depends(clinician_only)):
    """Closes the held item. The same evidence does not reopen it; fresh
    evidence does. The status still follows the data."""
    return await service.ack_attention(ctx_of(request), p, attention_id, rid_of(request))


# ---- reference ratings (clinician only) ------------------------------------------------
#
# A clinician's rating (PHQ-9, PHQ-2 or a global rating) is a reference for the
# association appraisal only. The mind never reads it: it changes nothing that
# is offered to the patient and never opens, raises or closes attention.

def _rating_out(r: dict) -> dict:
    return {k: r[k] for k in ("id", "date", "scale", "score", "created_at")} | \
        {"example": bool(r.get("example"))}


def _audit_research(request: Request, p: Principal, patient_id: str, action: str,
                    outcome: str = "ok", reason: str | None = None, **detail) -> None:
    ctx = ctx_of(request)
    write_audit(ctx.store, ctx.clock.now(), clinic_id=p.clinic_id, patient_id=patient_id,
                actor=p.actor, action=action, outcome=outcome, reason=reason, detail=detail,
                request_id=rid_of(request))


@router.post("/patients/{patient_id}/ratings", response_model=RatingOut,
             responses=errors(401, 403, 404, 422, 429),
             summary="Record a reference rating (PHQ-9, PHQ-2 or clinician global)")
async def add_rating(body: RatingIn, request: Request, patient_id: str = Path(pattern=SID),
                     p: Principal = Depends(clinician_only)):
    """Range-checked against the hypotheses file. One rating per day and scale:
    recording the same day and scale again replaces it. Used only as the
    reference of the association appraisal."""
    ctx = ctx_of(request)
    repo = _patient_repo(request, p, patient_id)
    lo, hi = assoc.hypotheses()["reference_scales"][body.scale]["range"]
    today = repo.local(ctx.clock.now()).date()
    reason = None
    if not lo <= body.score <= hi:
        reason = "score_out_of_range"
    elif body.date > today:
        reason = "future_date"
    elif body.date < today - timedelta(days=400):
        reason = "too_old"
    if reason:
        _audit_research(request, p, patient_id, "rating_add", "refused", reason,
                        scale=body.scale)
        raise ApiError(422, "implausible_rating", f"The rating was rejected: {reason}.")
    now = ctx.clock.now().isoformat()
    for old in repo.docs("ratings"):
        if old["date"] == body.date.isoformat() and old["scale"] == body.scale:
            repo.delete(f"ratings/{old['id']}.json")
    rec = {"id": new_id("rat"), "date": body.date.isoformat(), "scale": body.scale,
           "score": body.score, "created_at": now, "by": p.actor, "example": False}
    repo.put(f"ratings/{rec['id']}.json", rec)
    _audit_research(request, p, patient_id, "rating_add", rating_id=rec["id"], scale=body.scale)
    return _rating_out(rec)


@router.get("/patients/{patient_id}/ratings", response_model=RatingsOut,
            responses=errors(401, 403, 404, 429), summary="List the reference ratings")
async def list_ratings(request: Request, patient_id: str = Path(pattern=SID),
                       p: Principal = Depends(clinician_only)):
    repo = _patient_repo(request, p, patient_id)
    rs = sorted(repo.docs("ratings"), key=lambda r: (r["date"], r["scale"], r["created_at"]))
    return {"ratings": [_rating_out(r) for r in rs]}


@router.delete("/patients/{patient_id}/ratings/{rating_id}",
               responses=errors(401, 403, 404, 429), summary="Delete one reference rating")
async def delete_rating(request: Request, patient_id: str = Path(pattern=SID),
                        rating_id: str = Path(pattern=SID),
                        p: Principal = Depends(clinician_only)):
    repo = _patient_repo(request, p, patient_id)
    if repo.get(f"ratings/{rating_id}.json") is None:
        raise ApiError(404, "not_found", "Rating not found.")
    repo.delete(f"ratings/{rating_id}.json")
    _audit_research(request, p, patient_id, "rating_delete", rating_id=rating_id)
    return {"id": rating_id, "deleted": True}


# ---- the association appraisal (clinician-only research output) ----------------------

def _assoc_out(doc: dict | None) -> dict:
    if not doc:
        return {"status": "none", "rows": [], "data_notes": [], "corrections": [],
                "disclaimer": assoc.DISCLAIMER}
    return {**doc, "disclaimer": assoc.DISCLAIMER}


@router.get("/patients/{patient_id}/associations", response_model=AssociationsOut,
            responses=errors(401, 403, 404, 429),
            summary="The latest association appraisal: how the measures moved with the reference")
async def associations(request: Request, patient_id: str = Path(pattern=SID),
                       p: Principal = Depends(clinician_only)):
    """A within-person description of how this person's measurements moved
    together over time. Not validated, not a diagnosis; never shown to the
    patient. Statistics by code; a level-1 model may add caveats and the
    overall judgement, and code corrects whatever it got wrong (per field,
    `*_source` and `sources` say so). `status: none` until it has run."""
    ctx = ctx_of(request)
    repo = _patient_repo(request, p, patient_id)
    return _assoc_out(repo.get(ctx.mind.ASSOC_KEY))


@router.post("/patients/{patient_id}/associations/run", response_model=AssociationsOut,
             responses=errors(401, 403, 404, 429),
             summary="Compute the association appraisal now")
async def associations_run(request: Request, patient_id: str = Path(pattern=SID),
                           p: Principal = Depends(clinician_or_admin)):
    """A clinician of the patient's clinic, or the admin token. Waits for the
    model when one is configured; without it, the code-only appraisal."""
    ctx = ctx_of(request)
    if p.scope == "admin":
        idx = ctx.store.get(f"patients/{patient_id}.json")
        if not idx:
            raise ApiError(404, "not_found", "Patient not found.")
        repo = ctx.mind.repo(idx["clinic_id"], patient_id)
    else:
        repo = _patient_repo(request, p, patient_id)
    out = await ctx.mind.run_appraisal(repo, "on_demand")
    write_audit(ctx.store, ctx.clock.now(), clinic_id=repo.clinic_id, patient_id=patient_id,
                actor=p.actor, action="association_run", detail={"appraised_by": out["appraised_by"]},
                request_id=rid_of(request))
    return _assoc_out(out)
