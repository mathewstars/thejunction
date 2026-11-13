"""Device scope: the calls the iPhone app makes. The patient is always the
one the device token is bound to; no device call takes a patient id."""

from datetime import timezone

from fastapi import APIRouter, Depends, Path, Request

from .. import service
from ..mind import views
from ..models import (AnalysisOut, AnswerIn, DailyIn, DailyOut, FeedbackIn, NoteIn, NoteOut,
                      PairIn, PairOut, RoundIn, RoundOut, RuleWrap, TodayOut)
from ..security import Principal
from .deps import ctx_of, device_only, errors, open_rate_limit, rid_of

router = APIRouter(prefix="/v1", tags=["device"])

SID = r"^[a-z]{1,6}_[0-9a-f]{24}$"
CID = r"^[A-Za-z0-9_-]{8,64}$"
AUTH_ERRORS = errors(401, 403, 413, 422, 429)


@router.post("/devices/pair", response_model=PairOut, responses=errors(400, 422, 429),
             summary="Exchange a one-time pairing code for a device token")
async def pair(body: PairIn, request: Request):
    """No auth. The code is one-time and expires. The returned token is shown
    once: keep it in the Keychain."""
    open_rate_limit(request, "pair")
    return await service.pair_device(ctx_of(request), body.pairing_code, body.device_label,
                                     body.platform, rid_of(request))


@router.post("/daily", response_model=DailyOut, responses=AUTH_ERRORS,
             summary="Upload one day or a batch of history")
async def daily(body: DailyIn, request: Request, p: Principal = Depends(device_only)):
    """Upsert by date. Values that cannot be true (negative, absurd, future
    dates, conflicting duplicates in one batch) are rejected per day, logged,
    and never used for the baseline."""
    days = [d.model_dump(mode="json") for d in body.days]
    return await service.ingest_days(ctx_of(request), p, days, rid_of(request))


@router.post("/rounds", response_model=RoundOut, responses=errors(401, 403, 404, 413, 422, 429),
             summary="Send one AR round record (schema 2)")
async def rounds(body: RoundIn, request: Request, p: Principal = Depends(device_only)):
    """Idempotent by `id`. Implausible values reject the round (422). Weak
    tracking, a small play area or an interrupted round are kept but marked
    low quality. The movement reading (level 2) runs in the background."""
    rec = body.model_dump(mode="json", by_alias=True)
    rec["started_at"] = body.started_at.astimezone(timezone.utc).isoformat()
    return await service.record_round(ctx_of(request), p, rec, rid_of(request))


@router.get("/rounds/{round_id}/analysis", response_model=AnalysisOut,
            responses=errors(401, 403, 404, 429), summary="Status of the movement reading")
async def round_analysis(request: Request, round_id: str = Path(pattern=CID),
                         p: Principal = Depends(device_only)):
    """Returns a plain line from a fixed set when the reading is ready.
    Never the reading itself."""
    return service.round_analysis(ctx_of(request), p, round_id)


@router.get("/today", response_model=TodayOut, responses=errors(401, 403, 429),
            summary="Status, today's suggestion, round config and the crisis block")
async def today(request: Request, p: Principal = Depends(device_only)):
    """`crisis` is always present. `status` is one of no_baseline, within,
    outside, no_data; missing data is shown as no_data, never as within."""
    ctx = ctx_of(request)
    return views.today_view(ctx.mind, service.repo_for(ctx, p), ctx.settings)


@router.post("/feedback", responses=errors(401, 403, 404, 409, 422, 429),
             summary="Answer a suggestion")
async def feedback(body: FeedbackIn, request: Request, p: Principal = Depends(device_only)):
    """Idempotent by `id`. Answers are enums only."""
    return await service.record_feedback(ctx_of(request), p, body.model_dump(), rid_of(request))


@router.post("/notes", response_model=NoteOut, responses=errors(401, 403, 409, 413, 422, 429),
             summary="A few words from the patient (the only free-text field)")
async def notes(body: NoteIn, request: Request, p: Principal = Depends(device_only)):
    """The text is untrusted data. It is classified into enums (code lexicon
    plus the local model through the gates), never followed as an
    instruction, never logged, and never sent outside the server. The reply
    is a fixed template. When `crisis` is true the help block is included."""
    return await service.record_note(ctx_of(request), p, body.id, body.text, rid_of(request))


# ---- mind -------------------------------------------------------------------------------

@router.get("/mind", tags=["mind"], responses=errors(401, 403, 429),
            summary="Rules, active lessons and open questions")
async def mind(request: Request, p: Principal = Depends(device_only)):
    return views.mind_view(service.repo_for(ctx_of(request), p))


@router.post("/mind/rules", tags=["mind"], responses=AUTH_ERRORS,
             summary="Add a rule from the fixed catalog")
async def add_rule(body: RuleWrap, request: Request, p: Principal = Depends(device_only)):
    """Rule templates: quiet_hours {from, to}, seated_only {weekdays},
    max_suggestions_per_day {n}, no_action {action}. Rules always beat lessons."""
    rule = body.rule.model_dump(by_alias=True)
    return await service.add_rule(ctx_of(request), p, rule, rid_of(request))


@router.delete("/mind/rules/{rule_id}", tags=["mind"], responses=errors(401, 403, 404, 429),
               summary="Remove a rule")
async def delete_rule(request: Request, rule_id: str = Path(pattern=SID),
                      p: Principal = Depends(device_only)):
    await service.delete_rule(ctx_of(request), p, rule_id, rid_of(request))
    return {"id": rule_id, "deleted": True}


@router.post("/mind/lessons/{lesson_id}/reject", tags=["mind"],
             responses=errors(401, 403, 404, 429), summary="Say a lesson is not true")
async def reject_lesson(request: Request, lesson_id: str = Path(pattern=SID),
                        p: Principal = Depends(device_only)):
    """A rejected lesson does not come back from the same evidence."""
    return await service.reject_lesson(ctx_of(request), p, lesson_id, rid_of(request))


@router.post("/mind/questions/{question_id}/answer", tags=["mind"],
             responses=errors(401, 403, 404, 422, 429), summary="Answer a question")
async def answer_question(body: AnswerIn, request: Request,
                          question_id: str = Path(pattern=SID),
                          p: Principal = Depends(device_only)):
    return await service.answer_question(ctx_of(request), p, question_id, body.answer,
                                         rid_of(request))
