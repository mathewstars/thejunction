"""Request and response models.

All request models forbid unknown fields. There is exactly ONE free-text
field in the whole API: NoteIn.text. Everything else is numbers, dates,
ids and enums.
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Annotated, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator

ClientId = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{8,64}$")]
ServerId = Annotated[str, StringConstraints(pattern=r"^[a-z]{1,6}_[0-9a-f]{24}$")]
Hhmm = Annotated[str, StringConstraints(pattern=r"^([01]\d|2[0-3]):[0-5]\d$")]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


# ---- errors ----------------------------------------------------------------------

class ErrorBody(BaseModel):
    code: str = Field(examples=["not_found"])
    message: str = Field(examples=["Not found."])
    request_id: str = Field(examples=["9f2c4e1a0b7d"])


class ErrorResponse(BaseModel):
    error: ErrorBody


# ---- device: pairing ---------------------------------------------------------------

class PairIn(Strict):
    pairing_code: Annotated[str, StringConstraints(min_length=12, max_length=20)] = Field(
        description="One-time code from the clinic, e.g. ABCD-EFGH-JKLM.")
    device_label: Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9 ._-]{1,40}$")] = Field(
        description="Short label for the device. Not a person's name.", examples=["iPhone 15"])
    platform: Literal["ios"]

    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [
        {"pairing_code": "ABCD-EFGH-JKLM", "device_label": "iPhone 15", "platform": "ios"}]})


class PairOut(BaseModel):
    device_token: str = Field(description="Bearer token. Shown once; store it in the Keychain.")
    patient_id: str


# ---- device: daily data -------------------------------------------------------------

class DayIn(Strict):
    date: date
    steps: int = Field(description="Step count for the day.")
    walking_speed_m_s: Optional[float] = Field(None, description="Average walking speed, m/s.")
    hrv_ms: Optional[float] = Field(None, description="Heart-rate variability (SDNN), ms. Watch only.")
    sleep_h: Optional[float] = Field(None, description="Hours asleep. Watch only.")


class DailyIn(Strict):
    days: list[DayIn] = Field(min_length=1, max_length=400,
                              description="One day, or a batch of history. Upsert by date.")

    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [{"days": [
        {"date": "2026-11-13", "steps": 6400, "walking_speed_m_s": 1.24, "hrv_ms": 42.0,
         "sleep_h": 7.1}]}]})


class Rejected(BaseModel):
    date: str
    reason: str


class DailyOut(BaseModel):
    accepted: list[str]
    rejected: list[Rejected]
    status: str


# ---- device: rounds (schema 2, docs/game-interface.md section 3) ---------------------

class RoundConfigRef(Strict):
    config_id: Literal["seated_gentle", "near_gentle", "standard", "wide", "wide_high"]
    layout_seed: int = Field(ge=0, le=2**31 - 1)
    lights_total: int = Field(ge=1, le=60)


class Tracking(Strict):
    normal_ratio: float
    limited_reasons: list[Literal["excessive_motion", "insufficient_features", "initializing",
                                  "relocalizing", "other"]] = Field(default_factory=list,
                                                                     max_length=10)
    play_area_m2: Optional[float] = None
    light: Literal["dim", "ok", "bright"]
    lidar: bool


class LightLog(Strict):
    i: int = Field(ge=0, le=99)
    spawn_t: float
    dist_m: Optional[float]
    height_m: Optional[float]
    first_move_t: Optional[float]
    end_t: Optional[float]
    caught: bool


class Path(Strict):
    hz: int = Field(ge=1, le=10)
    points: list[Annotated[list[float], Field(min_length=3, max_length=3)]] = Field(max_length=240)


class RoundIn(Strict):
    id: ClientId = Field(description="Client-generated id. Re-sending the same id is an upsert.")
    schema_: Literal[2] = Field(alias="schema")
    suggestion_id: Optional[ServerId] = None
    started_at: datetime
    duration_s: float
    mode: Literal["standing", "seated", "screen"]
    completed: bool
    ended_by: Literal["finished", "user_stopped", "interrupted"]
    config: RoundConfigRef
    tracking: Tracking
    lights: list[LightLog] = Field(max_length=60)
    path: Optional[Path] = None

    model_config = ConfigDict(extra="forbid", populate_by_name=True, json_schema_extra={"examples": [{
        "id": "5b1c0c9e-8d0a-4c57-9a55-3f0f6d1f2a10", "schema": 2, "suggestion_id": None,
        "started_at": "2026-11-14T09:12:03Z", "duration_s": 118.4, "mode": "standing",
        "completed": True, "ended_by": "finished",
        "config": {"config_id": "standard", "layout_seed": 1234, "lights_total": 12},
        "tracking": {"normal_ratio": 0.93, "limited_reasons": ["excessive_motion"],
                     "play_area_m2": 9.5, "light": "ok", "lidar": False},
        "lights": [{"i": 0, "spawn_t": 2.1, "dist_m": 1.8, "height_m": 1.2, "first_move_t": 2.9,
                    "end_t": 6.4, "caught": True}],
        "path": {"hz": 2, "points": [[0.0, 0.0, 0.0], [0.1, -0.2, 0.0]]}}]})

    @field_validator("started_at")
    @classmethod
    def _aware(cls, v: datetime) -> datetime:
        if v.tzinfo is None:
            raise ValueError("started_at needs a time zone, e.g. Z")
        return v


class RoundOut(BaseModel):
    id: str
    quality: Literal["good", "low"]
    energy_bucket: Optional[Literal["low", "usual", "high"]]
    analysis: Literal["pending", "off", "not_allowed"]
    after_round: dict = Field(description="{template_id, text}: one line to show after the round.")


class AnalysisOut(BaseModel):
    status: Literal["pending", "ready", "off", "not_allowed", "failed"]
    line: Optional[str] = Field(None, description="Plain line for the patient, from a fixed set.")


# ---- device: today -------------------------------------------------------------------

class CrisisContact(BaseModel):
    label: str
    phone: str


class CrisisBlock(BaseModel):
    text: str
    contacts: list[CrisisContact]
    reviewed_by_clinician: bool = Field(description="False while the wording is a draft; "
                                                    "show it as draft wording.")


class SuggestionOut(BaseModel):
    id: str
    action: str
    text: str
    created_at: str


class TodayOut(BaseModel):
    status: Literal["no_baseline", "within", "outside", "no_data"]
    suggestion: Optional[SuggestionOut]
    round_config: dict
    attention: str = Field(description="Short patient-safe summary.")
    crisis: CrisisBlock = Field(description="Always present.")
    product_name: str


# ---- device: feedback, notes ----------------------------------------------------------

class FeedbackIn(Strict):
    id: ClientId
    suggestion_id: ServerId
    answer: Literal["did_it", "not_today", "something_else"]
    felt: Optional[Literal["rough", "ok", "good"]] = None


class NoteIn(Strict):
    id: ClientId
    text: Annotated[str, StringConstraints(min_length=1, max_length=280)] = Field(
        description="The ONLY free-text field in the API. Untrusted data: classified, never "
                    "followed, never sent outside the server.")


class NoteReplyOut(BaseModel):
    template_id: str
    text: str


class NoteOut(BaseModel):
    reply: NoteReplyOut
    crisis: bool
    crisis_block: Optional[CrisisBlock] = Field(None, description="Present when crisis is true.")
    suggestion: Optional[SuggestionOut]


# ---- device: mind -----------------------------------------------------------------------

class QuietHours(Strict):
    type: Literal["quiet_hours"]
    params: "QuietHoursParams"


class QuietHoursParams(Strict):
    from_: Hhmm = Field(alias="from")
    to: Hhmm
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


Weekday = Literal["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


class SeatedOnlyParams(Strict):
    weekdays: list[Weekday] = Field(min_length=1, max_length=7)


class SeatedOnly(Strict):
    type: Literal["seated_only"]
    params: SeatedOnlyParams


class MaxPerDayParams(Strict):
    n: int = Field(ge=0, le=5)


class MaxPerDay(Strict):
    type: Literal["max_suggestions_per_day"]
    params: MaxPerDayParams


class NoActionParams(Strict):
    action: Literal["ar_round", "ar_round_seated", "walk_10min", "daylight_10min",
                    "call_someone", "breathing_2min"]


class NoAction(Strict):
    type: Literal["no_action"]
    params: NoActionParams


QuietHours.model_rebuild()
RuleIn = Annotated[Union[QuietHours, SeatedOnly, MaxPerDay, NoAction], Field(discriminator="type")]


class RuleWrap(Strict):
    rule: RuleIn

    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [
        {"rule": {"type": "quiet_hours", "params": {"from": "21:00", "to": "08:00"}}}]})


class AnswerIn(Strict):
    answer: Literal["yes", "no", "not_sure"]


# ---- clinician ------------------------------------------------------------------------

class LoginIn(Strict):
    username: Annotated[str, StringConstraints(min_length=1, max_length=64)]
    password: Annotated[str, StringConstraints(min_length=1, max_length=256)]


class LoginOut(BaseModel):
    session_token: str
    expires_at: str


class ClinicDemo(BaseModel):
    enabled: bool = Field(description="Demo panel allowed for this clinician.")
    patient_id: Optional[str] = Field(None, description="The demo patient, when enabled.")


class ClinicMeOut(BaseModel):
    product_name: str
    clinic_name: str
    demo: ClinicDemo


TraceLayer = Literal["trigger", "watchers", "attention", "response", "level1", "level2",
                     "notifier", "learning"]


class TraceEntryOut(BaseModel):
    id: str
    at: str
    chain_id: str
    layer: TraceLayer = Field(description="Step of the loop, in this order: trigger, watchers, "
                                          "attention, response, level1, level2, notifier, learning.")
    code: str = Field(description="Short machine code for what happened, e.g. opened, suggested.")
    detail: dict = Field(description="Codes, ids, enums and numbers only. Never note text.")
    notable: bool = Field(description="This step changed something: opened or raised attention, "
                                      "made a suggestion, sent or queued a message, or refused "
                                      "a model answer.")


class TraceChainOut(BaseModel):
    chain_id: str
    at: str
    trigger: str
    changed: bool
    entries: list[TraceEntryOut]


class TraceLastAction(BaseModel):
    at: str
    layer: TraceLayer
    code: str
    detail: dict
    chain_id: str


class TraceCurrentItem(BaseModel):
    attention_id: str
    kind: str
    level: str
    since: str
    level_rule: Optional[str] = Field(None, description="The rule that set the current level.")
    level_detail: dict
    level_chain_id: Optional[str] = None
    opened_chain_id: Optional[str] = None
    last_action: Optional[TraceLastAction] = None


class TraceOut(BaseModel):
    status: str
    current: list[TraceCurrentItem]
    chains: list[TraceChainOut] = Field(description="Newest first.")


# ---- admin / demo ---------------------------------------------------------------------

class ScenarioIn(Strict):
    name: Literal["normal", "dip"]
    patient_id: Optional[ServerId] = None


class ReviewIn(Strict):
    patient_id: ServerId


class AnalyzeIn(Strict):
    patient_id: ServerId
    round_id: ClientId
