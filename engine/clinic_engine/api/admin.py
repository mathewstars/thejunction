"""Admin scope: demo controls and on-demand review."""

from fastapi import APIRouter, Depends, Request

from .. import seed
from ..audit import write_audit
from ..models import AnalyzeIn, ReviewIn, ScenarioIn
from ..security import Principal
from ..service import ApiError
from .deps import admin_only, ctx_of, errors, rid_of

router = APIRouter(prefix="/v1", tags=["admin"])


def _demo(request: Request) -> dict:
    ctx = ctx_of(request)
    if not ctx.settings.demo_enabled:
        raise ApiError(404, "not_found", "Demo endpoints are off.")
    st = ctx.store.get("demo/state.json")
    if not st:
        raise ApiError(404, "not_found", "No demo seeded.")
    return st


def _locate(request: Request, patient_id: str) -> str:
    idx = ctx_of(request).store.get(f"patients/{patient_id}.json")
    if not idx:
        raise ApiError(404, "not_found", "Patient not found.")
    return idx["clinic_id"]


def _audit(request: Request, p: Principal, action: str, **detail) -> None:
    ctx = ctx_of(request)
    write_audit(ctx.store, ctx.clock.now(), clinic_id=None, patient_id=None, actor=p.actor,
                action=action, detail=detail, request_id=rid_of(request))


@router.post("/demo/reset", responses=errors(401, 403, 404, 429),
             summary="Regenerate the demo patient's 28 normal days, rounds and history")
async def demo_reset(request: Request, p: Principal = Depends(admin_only)):
    """Keeps the clinic, the patient and the paired device."""
    st, ctx = _demo(request), ctx_of(request)
    c, pid = st["clinic_id"], st["patient_id"]
    async with ctx.mind.lock(c, pid):
        seed.wipe_patient(ctx.store, c, pid)
        seed.fill_patient(ctx.store, c, pid, ctx.clock.now(), seed=14)
    await ctx.mind.idle()
    await seed.settle(ctx.mind, c, pid)
    _audit(request, p, "demo_reset", patient_id=pid)
    return {"ok": True, "patient_id": pid}


@router.post("/demo/scenario", responses=errors(401, 403, 404, 422, 429),
             summary="Switch the recent days to a dip, or back to normal")
async def demo_scenario(body: ScenarioIn, request: Request, p: Principal = Depends(admin_only)):
    st, ctx = _demo(request), ctx_of(request)
    pid = body.patient_id or st["patient_id"]
    c = _locate(request, pid)
    repo = ctx.mind.repo(c, pid)
    async with ctx.mind.lock(c, pid):
        today = repo.local(ctx.clock.now()).date()
        seed.apply_scenario(ctx.store, c, pid, today, body.name, seed=14)
        seed.write_rounds(ctx.store, c, pid, today, repo.tz(), seed=14, dip=body.name == "dip")
        await ctx.mind.publish("scenario", c, pid, name=body.name)
    _audit(request, p, "demo_scenario", patient_id=pid, name=body.name)
    from ..mind.watchers import compute_status
    return {"ok": True, "patient_id": pid, "status": compute_status(ctx.mind.build_view(repo))}


@router.post("/demo/tick", responses=errors(401, 403, 429),
             summary="Run the periodic tick now (silence, expiry, queued notices)")
async def demo_tick(request: Request, p: Principal = Depends(admin_only)):
    await ctx_of(request).mind.tick()
    _audit(request, p, "demo_tick")
    return {"ok": True}


@router.post("/review/run", responses=errors(401, 403, 404, 422, 429),
             summary="Run the learning review for one patient now")
async def review_run(body: ReviewIn, request: Request, p: Principal = Depends(admin_only)):
    ctx = ctx_of(request)
    c = _locate(request, body.patient_id)
    async with ctx.mind.lock(c, body.patient_id):
        review = await ctx.mind.run_review(ctx.mind.repo(c, body.patient_id), "on_demand")
    _audit(request, p, "review_run", patient_id=body.patient_id)
    return review


@router.post("/demo/analyze", responses=errors(401, 403, 404, 422, 429),
             summary="Run the movement reading again for one round")
async def demo_analyze(body: AnalyzeIn, request: Request, p: Principal = Depends(admin_only)):
    ctx = ctx_of(request)
    c = _locate(request, body.patient_id)
    repo = ctx.mind.repo(c, body.patient_id)
    if repo.get(f"rounds/{body.round_id}.json") is None:
        raise ApiError(404, "not_found", "Round not found.")
    analysis = await ctx.mind.run_reading(repo, body.round_id, take_lock=True)
    _audit(request, p, "demo_analyze", patient_id=body.patient_id, round_id=body.round_id)
    return analysis
