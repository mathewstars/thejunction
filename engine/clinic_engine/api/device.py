"""Device scope: the calls the iPhone app makes. The patient is always the
one the device token is bound to; no device call takes a patient id."""

from datetime import timezone

from fastapi import APIRouter, Depends, Path, Request

from .. import service
from ..mind import views
from ..models import (ActivityIn, ActivityOut, ActivityReadingOut, AnalysisOut, AnswerIn,
                      CheckinOptionsOut, DailyIn, DailyOut, FeedbackIn, NoteIn, NoteOut, PairIn,
                      PairOut, PreferencesIn, PreferencesOut, RoundIn, RoundOut, RuleWrap,
                      TodayOut, WanderingAnswerIn)
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


@router.post("/activities", response_model=ActivityOut,
             responses=errors(401, 403, 404, 409, 413, 422, 429),
             summary="Send one activity record: focus, breathing or check-in")
async def activities(body: ActivityIn, request: Request, p: Principal = Depends(device_only)):
    """One record per activity, idempotent by `id`: the same record again is
    answered without new XP; a different record under a used id is refused
    (409). Values that cannot be true are rejected (422) and logged.

    Typed words in a check-in are untrusted data with exactly the note's
    treatment: classified into enums only, never followed, never logged,
    never sent outside the server. If they ask for help, `crisis` is true and
    the help block is included, as for a note.

    The answer says what Lanvi shows next: XP gained, the new total, stage,
    glow and one line from the fixed set. XP is for showing up: the same
    whatever the score.

    Sensors: `sensors` (docs/sensors.md) carries the Apple Watch's heart-rate and
    HRV samples during the activity and every game moment, with one clock anchor
    that lines them up with `face_raw`. The server computes the summary and keeps
    the rows.

    The face: send `face_raw` (raw ARKit frames, numbers only; the server
    computes every face measure, docs/face-raw.md) or, from older clients,
    `face` (a summary the phone computed). Not both (422). This route accepts
    bodies up to MAX_FACE_RAW_BODY_BYTES (4 MiB by default); other routes keep
    the general limit."""
    rec = body.model_dump(mode="json")
    if rec.get("face_raw", "absent") is None:
        del rec["face_raw"]  # so a record without raw frames hashes as it always did
    if rec.get("sensors", "absent") is None:
        del rec["sensors"]  # the same for a record without watch data
    rec["started_at"] = body.started_at.astimezone(timezone.utc).isoformat()
    return await service.record_activity(ctx_of(request), p, rec, rid_of(request))


@router.get("/activities/{activity_id}/reading", response_model=ActivityReadingOut,
            responses=errors(401, 403, 404, 429), summary="Status of the session reading")
async def activity_reading(request: Request, activity_id: str = Path(pattern=CID),
                           p: Principal = Depends(device_only)):
    """A neutral line from a fixed set when the reading is ready. Never the
    reading itself, never anything about mood or the face."""
    return service.activity_reading(ctx_of(request), p, activity_id)


@router.get("/checkin/options", response_model=CheckinOptionsOut,
            responses=errors(401, 403, 429), summary="What the evening check-in offers to tap")
async def checkin_options(request: Request, p: Principal = Depends(device_only)):
    return service.checkin_options()


@router.put("/preferences", response_model=PreferencesOut, responses=AUTH_ERRORS,
            summary="Onboarding: what helps (music, moving, people, quiet)")
async def preferences(body: PreferencesIn, request: Request, p: Principal = Depends(device_only)):
    """Stored as the starting order of suggestions, used until the first lesson
    exists. Replaces the earlier answer. Lanvi answers with one fixed line."""
    return await service.set_preferences(ctx_of(request), p, body.helps, rid_of(request))


@router.post("/lanvi/wanderings/{wandering_id}/answer",
             responses=errors(401, 403, 404, 422, 429),
             summary="Answer the question of the story Lanvi brought back")
async def wandering_answer(body: WanderingAnswerIn, request: Request,
                           wandering_id: str = Path(pattern=r"^wander-[0-9]{4,6}$"),
                           p: Principal = Depends(device_only)):
    """Only while `lanvi.wandering.state` is `back` and the id matches. The
    answer is stored as an enum (a or b)."""
    return await service.answer_wandering(ctx_of(request), p, wandering_id, body.answer,
                                          rid_of(request))


@router.post("/rounds", response_model=RoundOut, responses=errors(401, 403, 404, 413, 422, 429),
             summary="Deprecated: send one AR round record (schema 2)", deprecated=True)
async def rounds(body: RoundIn, request: Request, p: Principal = Depends(device_only)):
    """Deprecated: the AR round was cut from the design. Kept so an app still
    on the earlier design does not break; use POST /v1/activities.

    Idempotent by `id`. Implausible values reject the round (422). Weak
    tracking, a small play area or an interrupted round are kept but marked
    low quality. The movement reading (level 2) runs in the background."""
    rec = body.model_dump(mode="json", by_alias=True)
    rec["started_at"] = body.started_at.astimezone(timezone.utc).isoformat()
    return await service.record_round(ctx_of(request), p, rec, rid_of(request))


@router.get("/rounds/{round_id}/analysis", response_model=AnalysisOut,
            responses=errors(401, 403, 404, 429), deprecated=True,
            summary="Deprecated: status of the movement reading of an AR round")
async def round_analysis(request: Request, round_id: str = Path(pattern=CID),
                         p: Principal = Depends(device_only)):
    """Deprecated with POST /v1/rounds. Returns a plain line from a fixed set
    when the reading is ready. Never the reading itself."""
    return service.round_analysis(ctx_of(request), p, round_id)


@router.get("/today", response_model=TodayOut, responses=errors(401, 403, 429),
            summary="Status, today's suggestion, Lanvi and the crisis block")
async def today(request: Request, p: Principal = Depends(device_only)):
    """`crisis` is always present. `status` is one of no_baseline, within,
    outside, no_data; missing data is shown as no_data, never as within.
    `lanvi` holds XP, stage, glow, the wandering (with a story when one waits)
    and the line Lanvi says today. `round_config` is deprecated."""
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
    instruction and never logged. When `crisis` is true the help block is
    included and the reply is the fixed help line.

    CHAT_MODE=fixed (default): the reply is a fixed template and the text is
    never sent outside the server.
    CHAT_MODE=gemini: for a note that did not open the help screen, and only
    for a patient who allowed outside processing, the note and today's earlier
    turns go to Gemini, which writes Lanvi's reply (`template_id: gemini`),
    checked by code. Any failure gives the fixed template."""
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
