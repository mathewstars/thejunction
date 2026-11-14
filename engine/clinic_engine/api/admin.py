"""Admin scope: demo controls and on-demand review.

The admin token may always call these. While DEMO_ENABLED is true, a
clinician session of the seeded demo clinic may call them too (the demo panel
on the clinician page), limited to patients of that clinic. With demo mode
off they are admin-only."""

from fastapi import APIRouter, Depends, Request

from .. import seed, service
from ..audit import write_audit
from ..models import AnalyzeIn, RecomputeFaceIn, RecomputeFaceOut, ReviewIn, ScenarioIn
from ..security import Principal
from ..service import ApiError
from .deps import ctx_of, demo_actor, errors, rid_of

router = APIRouter(prefix="/v1", tags=["admin"])


def _demo(request: Request) -> dict:
    ctx = ctx_of(request)
    if not ctx.settings.demo_enabled:
        raise ApiError(404, "not_found", "Demo endpoints are off.")
    st = ctx.store.get("demo/state.json")
    if not st:
        raise ApiError(404, "not_found", "No demo seeded.")
    return st


def _locate(request: Request, p: Principal, patient_id: str) -> str:
    ctx = ctx_of(request)
    idx = ctx.store.get(f"patients/{patient_id}.json")
    if idx and p.scope == "clinician" and idx["clinic_id"] != p.clinic_id:
        write_audit(ctx.store, ctx.clock.now(), clinic_id=p.clinic_id, patient_id=None,
                    actor=p.actor, action="demo", outcome="refused",
                    reason="patient_not_in_clinic", detail={"patient_id": patient_id},
                    request_id=rid_of(request))
        idx = None
    if not idx:
        raise ApiError(404, "not_found", "Patient not found.")
    return idx["clinic_id"]


def _audit(request: Request, p: Principal, action: str, **detail) -> None:
    ctx = ctx_of(request)
    write_audit(ctx.store, ctx.clock.now(), clinic_id=p.clinic_id, patient_id=None,
                actor=p.actor, action=action, detail=detail, request_id=rid_of(request))


@router.post("/demo/reset", responses=errors(401, 403, 404, 429),
             summary="Regenerate the demo patient's 28 normal days, activities and history")
async def demo_reset(request: Request, p: Principal = Depends(demo_actor)):
    """Keeps the clinic, the patient and the paired device."""
    st, ctx = _demo(request), ctx_of(request)
    c, pid = st["clinic_id"], st["patient_id"]
    async with ctx.mind.lock(c, pid):
        seed.wipe_patient(ctx.store, c, pid)
        seed.fill_patient(ctx.store, c, pid, ctx.clock.now(), seed=14)
    await ctx.mind.idle()
    await seed.settle(ctx.mind, c, pid, appraise=True)
    _audit(request, p, "demo_reset", patient_id=pid)
    return {"ok": True, "patient_id": pid}


@router.post("/demo/scenario", responses=errors(401, 403, 404, 422, 429),
             summary="Switch the recent days to a dip, or back to normal")
async def demo_scenario(body: ScenarioIn, request: Request, p: Principal = Depends(demo_actor)):
    st, ctx = _demo(request), ctx_of(request)
    pid = body.patient_id or st["patient_id"]
    c = _locate(request, p, pid)
    repo = ctx.mind.repo(c, pid)
    async with ctx.mind.lock(c, pid):
        today = repo.local(ctx.clock.now()).date()
        seed.apply_scenario(ctx.store, c, pid, today, body.name, seed=14)
        seed.write_rounds(ctx.store, c, pid, today, repo.tz(), seed=14, dip=body.name == "dip")
        seed.write_activities(ctx.store, c, pid, today, repo.tz(), seed=14,
                              dip=body.name == "dip")
        if repo.docs("ratings"):  # example ratings follow the scenario
            seed.write_ratings(ctx.store, c, pid, today, seed=14, dip=body.name == "dip")
        await ctx.mind.publish("scenario", c, pid, name=body.name)
    _audit(request, p, "demo_scenario", patient_id=pid, name=body.name)
    from ..mind.watchers import compute_status
    return {"ok": True, "patient_id": pid, "status": compute_status(ctx.mind.build_view(repo))}


@router.post("/demo/tick", responses=errors(401, 403, 429),
             summary="Run the periodic tick now (silence, expiry, queued notices)")
async def demo_tick(request: Request, p: Principal = Depends(demo_actor)):
    await ctx_of(request).mind.tick()
    _audit(request, p, "demo_tick")
    return {"ok": True}


@router.post("/review/run", responses=errors(401, 403, 404, 422, 429),
             summary="Run the learning review for one patient now")
async def review_run(body: ReviewIn, request: Request, p: Principal = Depends(demo_actor)):
    ctx = ctx_of(request)
    c = _locate(request, p, body.patient_id)
    async with ctx.mind.lock(c, body.patient_id):
        review = await ctx.mind.run_review(ctx.mind.repo(c, body.patient_id), "on_demand")
    _audit(request, p, "review_run", patient_id=body.patient_id)
    return review


@router.post("/demo/analyze", responses=errors(401, 403, 404, 422, 429),
             summary="Run the level-2 reading again for one activity (or an earlier round)")
async def demo_analyze(body: AnalyzeIn, request: Request, p: Principal = Depends(demo_actor)):
    """With `activity_id`: the session reading of a focus or breathing session
    with a face summary, or with `what: "frames"` the frame reading of a session
    sent with raw face frames (level 2 reads them, code checks every item;
    returns the stored `frames_reading`). With `round_id`: the movement reading
    of an AR round of the earlier design."""
    ctx = ctx_of(request)
    c = _locate(request, p, body.patient_id)
    repo = ctx.mind.repo(c, body.patient_id)
    if body.what == "days":
        result = await ctx.mind.run_days_reading(repo, take_lock=True)
        _audit(request, p, "demo_analyze", patient_id=body.patient_id, what="days",
               status=result.get("status"))
        return result
    if body.activity_id is not None:
        rec = repo.get(f"activities/{body.activity_id}.json")
        if rec is None:
            raise ApiError(404, "not_found", "Activity not found.")
        if body.what == "frames":
            result = await ctx.mind.run_frames_reading(repo, body.activity_id, take_lock=True)
            _audit(request, p, "demo_analyze", patient_id=body.patient_id,
                   activity_id=body.activity_id, what="frames", status=result.get("status"))
            return result
        analysis = await ctx.mind.run_session_reading(repo, body.activity_id, take_lock=True)
        _audit(request, p, "demo_analyze", patient_id=body.patient_id,
               activity_id=body.activity_id)
        return analysis
    if repo.get(f"rounds/{body.round_id}.json") is None:
        raise ApiError(404, "not_found", "Round not found.")
    analysis = await ctx.mind.run_reading(repo, body.round_id, take_lock=True)
    _audit(request, p, "demo_analyze", patient_id=body.patient_id, round_id=body.round_id)
    return analysis


@router.post("/demo/recompute-face", response_model=RecomputeFaceOut,
             responses=errors(401, 403, 404, 422, 429),
             summary="Compute the face summary of a patient's raw sessions again")
async def demo_recompute_face(body: RecomputeFaceIn, request: Request,
                              p: Principal = Depends(demo_actor)):
    """For every focus or breathing session sent with raw face frames: compute
    the summary again from the stored frames with the current thresholds, and
    rewrite its face summary, face quality and face z values. Sessions sent with
    a summary are left as they are. Returns how many were recomputed."""
    ctx = ctx_of(request)
    c = _locate(request, p, body.patient_id)
    async with ctx.mind.lock(c, body.patient_id):
        n = service.recompute_faces(ctx.mind.repo(c, body.patient_id))
    _audit(request, p, "demo_recompute_face", patient_id=body.patient_id, recomputed=n)
    return {"patient_id": body.patient_id, "recomputed": n}
