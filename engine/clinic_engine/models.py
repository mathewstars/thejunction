"""Request and response models.

All request models forbid unknown fields. Free text exists in exactly two
places, and both get the same treatment (classified into enums only, never
followed, never logged): NoteIn.text and the typed items of a check-in
(CheckinItem.text). Neither is sent outside the server, with one switchable
exception: with CHAT_MODE=gemini (default fixed) a note that did not open the
help screen goes to Gemini so it can write Lanvi's reply. Everything else is
numbers, dates, ids and enums.
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Annotated, Literal, Optional, Union

from pydantic import (BaseModel, ConfigDict, Field, StringConstraints, field_validator,
                      model_validator)

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
                              description="One day, or a batch of history. Merged by date: a field left out keeps the stored value.")

    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [{"days": [
        {"date": "2026-11-13", "steps": 6400, "walking_speed_m_s": 1.24, "hrv_ms": 42.0,
         "sleep_h": 7.1}]}]})


class Rejected(BaseModel):
    date: str
    reason: str


# ---- device: Apple Health summary (the HealthKit harness app, a watch companion) -----
#
# The shape is the harness's own `HealthDataSummary` (ios/Lanvi/Sense/Peter/SharedModels.swift),
# so its JSON can be posted as it is. Only the fields named here are read; every other
# field of the summary is ignored and never stored (source names, device names, dates of
# single samples).

class _Lenient(BaseModel):
    model_config = ConfigDict(extra="ignore")


class HealthDailyIn(_Lenient):
    day: date = Field(description="Calendar day, yyyy-MM-dd, in the phone's time zone.")
    count: Optional[int] = Field(None, ge=0, le=1_000_000)
    sum: Optional[float] = None
    mean: Optional[float] = Field(None, description="The day's value: the sum for summed types, "
                                                    "the mean for averaged ones, hours for sleep.")


class HealthMetricIn(_Lenient):
    typeIdentifier: str = Field(pattern=r"^HK[A-Za-z0-9]{1,80}(:[A-Za-z0-9 _-]{1,40})?$",
                                description="The HealthKit identifier, for example "
                                            "HKQuantityTypeIdentifierRestingHeartRate.")
    unit: Optional[str] = Field(None, max_length=24)
    aggregation: Literal["sum", "mean", "durationHours", "latest", "count"] = "mean"
    daily: list[HealthDailyIn] = Field(max_length=400)


class HealthSummaryIn(_Lenient):
    metrics: list[HealthMetricIn] = Field(min_length=1, max_length=200)

    model_config = ConfigDict(extra="ignore", json_schema_extra={"examples": [{"metrics": [
        {"typeIdentifier": "HKQuantityTypeIdentifierStepCount", "unit": "count",
         "aggregation": "sum", "daily": [{"day": "2026-11-13", "count": 212, "sum": 6400,
                                          "mean": 6400}]},
        {"typeIdentifier": "HKQuantityTypeIdentifierRestingHeartRate", "unit": "count/min",
         "aggregation": "mean", "daily": [{"day": "2026-11-13", "count": 1, "mean": 58}]}]}]})


class HealthMetricStored(BaseModel):
    type: str
    days: int = Field(description="Days of this type now stored.")
    last_day: Optional[str]


class HealthSummaryOut(BaseModel):
    stored: list[HealthMetricStored] = Field(description="Every type that was stored.")
    days_updated: list[str] = Field(description="Days whose steps, walking speed, sleep or HRV "
                                                "changed from this upload.")
    rejected: list[Rejected]
    status: str


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


# ---- device: activities (docs/game-design.md) ---------------------------------------

class FaceSummary(Strict):
    """Numbers only, from the front camera during the activity, when the person
    allowed it. No frames, no images, no landmarks."""
    smile_rate_per_min: Optional[float] = Field(None, ge=0, le=120)
    smile_intensity: Optional[float] = Field(None, ge=0, le=1, description="0 to 1.")
    facial_activity: Optional[float] = Field(None, ge=0, le=1,
                                             description="How much the face moved, 0 to 1.")
    blink_rate_per_min: Optional[float] = Field(None, ge=0, le=120)
    look_down_share: Optional[float] = Field(None, ge=0, le=1,
                                             description="Share of time looking down, 0 to 1.")
    head_tilt_deg: Optional[float] = Field(None, ge=-90, le=90)
    # Optional, newer fields. Numbers only; each is compared with the person's own normal.
    smile_time_share: Optional[float] = Field(None, ge=0, le=1,
                                              description="Share of the time smiling, 0 to 1.")
    eye_smile_share: Optional[float] = Field(None, ge=0, le=1,
                                             description="Share of smiles with a cheek raise "
                                                         "(reaching the eyes), 0 to 1.")
    smile_response_share: Optional[float] = Field(None, ge=0, le=1,
                                                  description="Share of marked pleasant moments "
                                                              "in the activity followed by a "
                                                              "smile shortly after, 0 to 1.")
    smile_response_latency_s: Optional[float] = Field(None, ge=0, le=30,
                                                      description="Median delay from a marked "
                                                                  "pleasant moment to the smile, "
                                                                  "seconds.")
    brow_down_share: Optional[float] = Field(None, ge=0, le=1,
                                             description="Share of the time with brows drawn "
                                                         "down, 0 to 1.")
    inner_brow_up_share: Optional[float] = Field(None, ge=0, le=1,
                                                 description="Share of the time with inner "
                                                             "brows raised, 0 to 1.")
    blink_duration_ms: Optional[float] = Field(None, ge=0, le=2000,
                                               description="Median blink length, ms.")
    head_pitch_deg: Optional[float] = Field(None, ge=-90, le=90,
                                            description="Average head angle, degrees; looking "
                                                        "down is higher.")
    head_movement: Optional[float] = Field(None, ge=0, le=1,
                                           description="How much the head moved, 0 to 1.")
    smile_asymmetry: Optional[float] = Field(None, ge=0, le=1,
                                             description="Left-right difference of smiles, "
                                                         "0 (even) to 1.")
    lip_down_share: Optional[float] = Field(None, ge=0, le=1,
                                            description="Share of the time with the lip "
                                                        "corners pulled down, 0 to 1.")
    lip_press_share: Optional[float] = Field(None, ge=0, le=1,
                                             description="Share of the time with the lips "
                                                         "pressed together, 0 to 1.")
    tracking_quality: float = Field(ge=0, le=1, description="0 to 1. Below 0.6 the summary is "
                                    "kept but never used for the person's own normal.")


class FaceRawIn(Strict):
    """Raw ARKit frames from the front camera during the activity, when the
    person allowed it. The phone computes nothing: the server derives the face
    summary (docs/face-raw.md). Numbers only: blend-shape coefficients 0 to 1
    and head angles in degrees. No image, no video, no mesh, no identifiers."""
    rate_hz: float = Field(ge=5, le=60, description="Frames per second of `samples`. 30 is enough.")
    channels: list[Annotated[str, StringConstraints(min_length=1, max_length=40)]] = Field(
        min_length=4, max_length=60,
        description="Names in the order of each sample's values: ARKit blend-shape identifiers "
                    "(e.g. mouthSmileLeft) and headPitch, headYaw, headRoll (degrees, headPitch "
                    "positive = chin down). Must include mouthSmileLeft, mouthSmileRight, "
                    "eyeBlinkLeft, eyeBlinkRight.")
    samples: list[list[float]] = Field(min_length=1, max_length=12000,
                                       description="One row per frame, len(channels) values each.")
    tracked: Optional[list[Annotated[int, Field(ge=0, le=1)]]] = Field(
        None, description="Optional, one per frame: 1 when ARKit tracked the face. Default all 1.")
    moments_ms: Optional[list[Annotated[int, Field(ge=0, le=3_600_000)]]] = Field(
        None, max_length=20,
        description="Optional: times of marked pleasant moments, ms from the first frame.")

    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [{
        "rate_hz": 30, "channels": ["mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft",
                                    "eyeBlinkRight", "headPitch", "headYaw", "headRoll"],
        "samples": [[0.04, 0.05, 0.08, 0.07, 6.2, -1.4, 0.8],
                    [0.05, 0.05, 0.09, 0.08, 6.1, -1.3, 0.8],
                    [0.31, 0.29, 0.07, 0.07, 6.0, -1.3, 0.9]],
        "tracked": [1, 1, 1], "moments_ms": [40]}]})

    @model_validator(mode="after")
    def _check(self):
        from .mind.face_features import check_raw
        problem = check_raw({"channels": self.channels, "samples": self.samples,
                             "tracked": self.tracked, "moments_ms": self.moments_ms})
        if problem:
            raise ValueError(problem)
        return self


class _FaceOneWay(Strict):
    @model_validator(mode="after")
    def _one_face(self):
        if getattr(self, "face", None) is not None and getattr(self, "face_raw", None) is not None:
            raise ValueError("send either face (a summary) or face_raw (raw frames), not both")
        return self


class _ActivityBase(Strict):
    id: ClientId = Field(description="Client-generated id. Re-sending the same record is safe "
                                     "and earns nothing twice; a different record under the same "
                                     "id is refused (409).")
    started_at: datetime
    duration_s: float = Field(ge=0, le=86400)
    completed: bool
    ended_by: Literal["finished", "user_stopped", "interrupted"]
    suggestion_id: Optional[ServerId] = Field(None, description="The suggestion this answers, "
                                                                "if it was played from one.")

    @field_validator("started_at")
    @classmethod
    def _aware(cls, v: datetime) -> datetime:
        if v.tzinfo is None:
            raise ValueError("started_at needs a time zone, e.g. Z")
        return v


class RevontuletRound(Strict):
    """One round of Revontulet: the fault line picked, the half-circle traced,
    the slingshot pull and the embers. Numbers only, no touch paths."""
    effort: Literal["easy", "hard"] = Field(description="The fault line picked: the thin low "
                                                        "crack (easy) or the thick vein (hard).")
    choice_ms: int = Field(ge=0, le=120000, description="Fault lines shown to the tap that "
                                                        "picked one.")
    trace_start_ms: Optional[int] = Field(None, ge=0, le=120000,
                                          description="The half-circle appearing to the first "
                                                      "touch on it. Null on a traced round "
                                                      "means the first-time coach showed the "
                                                      "move: that round is left out of the time "
                                                      "to choose and the tracing speed.")
    trace_ms: Optional[int] = Field(None, ge=0, le=120000,
                                    description="First touch on the half-circle to the light "
                                                "reaching its end. Null if not finished.")
    trace_length_pt: float = Field(0, ge=0, le=20000,
                                   description="Length of the finger's path while tracing, "
                                               "screen points (lifts left out).")
    trace_mean_speed_pt_s: Optional[float] = Field(None, ge=0, le=20000,
                                                   description="Path length over the time the "
                                                               "finger was down, points/s.")
    trace_peak_speed_pt_s: Optional[float] = Field(None, ge=0, le=50000,
                                                   description="Fastest the finger went while "
                                                               "tracing (smoothed), points/s.")
    trace_lifts: int = Field(0, ge=0, le=100, description="Times the finger lifted before the "
                                                          "light reached the end.")
    pull_pt: Optional[float] = Field(None, ge=0, le=2000,
                                     description="How far the spark was pulled at the release, "
                                                 "points. Null if never released.")
    pull_hold_ms: Optional[int] = Field(None, ge=0, le=120000,
                                        description="How long the pull was held before the "
                                                    "release.")
    embers_shown: int = Field(0, ge=0, le=5, description="Embers that flashed in the flight.")
    embers_hit: int = Field(0, ge=0, le=5, description="Embers tapped in time. At most "
                                                       "embers_shown.")
    bonus: bool = Field(False, description="The surprise extra reward was given this round.")

    @model_validator(mode="after")
    def _hits(self):
        if self.embers_hit > self.embers_shown:
            raise ValueError("embers_hit is more than embers_shown")
        return self


class RevontuletStroke(Strict):
    """One slow stroke over the sleeping fox."""
    ms: int = Field(ge=0, le=60000)
    length_pt: float = Field(ge=0, le=20000, description="Screen points.")
    mean_speed_pt_s: float = Field(ge=0, le=20000, description="Points per second.")


class RevontuletIn(Strict):
    """What Revontulet measures beyond the focus record's taps and reaction
    times (docs/revontulet-measures.md). Numbers only: no touch paths, no
    positions, nothing that identifies a person. A record with this object is
    read as a Revontulet game and compared only with the person's earlier
    Revontulet games: reaction times need two ember taps, the error rate is
    embers missed over embers shown, and a game where the wall burst counts as
    played to the end even when the person left during the strokes."""
    rounds: list[RevontuletRound] = Field(default_factory=list, max_length=3,
                                          description="One per round where a fault line was "
                                                      "picked, in order.")
    strokes: list[RevontuletStroke] = Field(default_factory=list, max_length=10,
                                            description="The strokes over the sleeping fox, "
                                                        "in order.")
    broke_through_s: Optional[float] = Field(None, ge=0, le=600,
                                             description="Seconds from the start to the wall "
                                                         "bursting; null if it never burst. At "
                                                         "most duration_s + 1.")
    fox_finished: Optional[bool] = Field(None, description="True when time ran out and the "
                                         "fox's own spark broke the wall. Null if not sent.")
    pt_per_cm: Optional[float] = Field(None, ge=10, le=400,
                                       description="Screen points per centimetre on this phone, "
                                                   "to turn points/s into cm/s.")
    touch_radius_mean_pt: Optional[float] = Field(None, ge=0, le=200,
                                                  description="Mean touch radius over the game, "
                                                              "points. A stand-in for pressure.")
    touch_radius_var: Optional[float] = Field(None, ge=0, le=10000,
                                              description="Variance of the touch radius, "
                                                          "points squared.")

    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [{
        "rounds": [
            {"effort": "easy", "choice_ms": 2310, "trace_start_ms": 1840, "trace_ms": 1650, "trace_length_pt": 288.4,
             "trace_mean_speed_pt_s": 174.8, "trace_peak_speed_pt_s": 362.0, "trace_lifts": 0,
             "pull_pt": 96.5, "pull_hold_ms": 820, "embers_shown": 0, "embers_hit": 0,
             "bonus": False},
            {"effort": "hard", "choice_ms": 940, "trace_start_ms": 960, "trace_ms": 1220, "trace_length_pt": 279.3,
             "trace_mean_speed_pt_s": 228.9, "trace_peak_speed_pt_s": 455.0, "trace_lifts": 0,
             "pull_pt": 108.2, "pull_hold_ms": 540, "embers_shown": 2, "embers_hit": 2,
             "bonus": True}],
        "strokes": [{"ms": 1450, "length_pt": 410.0, "mean_speed_pt_s": 282.8}],
        "broke_through_s": 52.4, "fox_finished": False, "pt_per_cm": 64.2,
        "touch_radius_mean_pt": 21.3,
        "touch_radius_var": 4.7}]})


class FocusActivityIn(_ActivityBase, _FaceOneWay):
    """Revontulet (up to about 90 seconds). The app sends its measures in
    `revontulet`; a record without them is still taken and read from the taps alone."""
    type: Literal["focus"]
    correct_taps: int = Field(ge=0, le=1000)
    wrong_taps: int = Field(ge=0, le=1000, description="Always 0 in Revontulet: there is "
                            "nothing wrong to tap.")
    misses: int = Field(ge=0, le=1000, description="Embers that flashed and were not tapped.")
    reaction_ms: list[Annotated[int, Field(ge=0, le=10000)]] = Field(
        default_factory=list, max_length=200,
        description="Reaction time per tap in whole milliseconds. The server computes its own "
                    "statistics.")
    face: Optional[FaceSummary] = Field(None, description="A summary the phone computed. "
                                        "Prefer face_raw: the server computes the summary.")
    face_raw: Optional[FaceRawIn] = Field(None, description="Raw ARKit frames; the server "
                                          "computes the face summary. Not with face.")
    revontulet: Optional[RevontuletIn] = Field(None, description="Only from Revontulet: the "
                                               "effort choices, tracing, pull and strokes. "
                                               "Without it the record means what it always did.")


class BreathingActivityIn(_ActivityBase, _FaceOneWay):
    """Breathe with Lanvi, 1 minute."""
    type: Literal["breathing"]
    time_played_s: float = Field(ge=0, le=3600)
    breaths_completed: Optional[int] = Field(None, ge=0, le=200)
    face: Optional[FaceSummary] = Field(None, description="A summary the phone computed. "
                                        "Prefer face_raw: the server computes the summary.")
    face_raw: Optional[FaceRawIn] = Field(None, description="Raw ARKit frames; the server "
                                          "computes the face summary. Not with face.")


GoodThingId = Annotated[str, StringConstraints(pattern=r"^[a-z_]{2,40}$")]
TypedText = Annotated[str, StringConstraints(min_length=1, max_length=120)]


class CheckinItem(Strict):
    """Either a catalog id the person tapped, or a few typed words (not both).
    Typed text is untrusted data: classified like a note, never followed,
    never logged, never sent outside the server."""
    catalog_id: Optional[GoodThingId] = None
    text: Optional[TypedText] = None

    @model_validator(mode="after")
    def _one(self):
        if (self.catalog_id is None) == (self.text is None):
            raise ValueError("give either catalog_id or text")
        return self


class CheckinActivityIn(_ActivityBase):
    """Evening check-in, once a day."""
    type: Literal["checkin"]
    good_things: list[CheckinItem] = Field(default_factory=list, max_length=3,
                                           description="Up to 3 good things from today.")
    plan: Optional[CheckinItem] = Field(None, description="One small nice thing for tomorrow.")
    plan_done: Literal["yes", "no", "not_asked"] = Field(
        "not_asked", description="Whether yesterday's plan happened, when the app asked.")


ActivityIn = Annotated[Union[FocusActivityIn, BreathingActivityIn, CheckinActivityIn],
                       Field(discriminator="type")]


class LineOut(BaseModel):
    template_id: str
    text: str


class ActivityOut(BaseModel):
    id: str
    type: str
    xp_gained: int = Field(description="XP this record earned now (0 when re-sent).")
    xp_total: int
    stage: Literal["kit", "young_fox", "grown_fox"]
    next_stage_at: Optional[int]
    glow: float = Field(description="0 to 1. A full glow starts a wandering.")
    wandering: Literal["home", "away", "back"]
    line: LineOut = Field(description="One line for Lanvi to say now, from a fixed set.")
    crisis: bool = Field(False, description="True when typed check-in words asked for help.")
    crisis_block: Optional["CrisisBlock"] = Field(None, description="Present when crisis is true.")
    reading: Literal["pending", "ready", "failed", "off", "not_allowed", "not_applicable"] = Field(
        description="The session reading (level 2) for a focus or breathing session with a face "
                    "summary: pending, or off / not_allowed. not_applicable for a check-in or a "
                    "session without a face summary. Fetch the line from "
                    "GET /v1/activities/{id}/reading.")


class ActivityReadingOut(BaseModel):
    status: Literal["pending", "ready", "failed", "off", "not_allowed", "not_applicable"]
    line: Optional[str] = Field(None, description="Neutral line for the patient, from a fixed "
                                                  "set. Never about mood or the face.")


class CheckinOption(BaseModel):
    id: str
    label: str


class CheckinOptionsOut(BaseModel):
    good_things: list[CheckinOption]
    plans: list[CheckinOption]


class PreferencesIn(Strict):
    helps: list[Literal["music", "moving", "people", "quiet"]] = Field(
        min_length=0, max_length=4, description="What helps, in the order the person chose. "
                                                "The starting order of suggestions.")

    @field_validator("helps")
    @classmethod
    def _unique(cls, v: list[str]) -> list[str]:
        if len(set(v)) != len(v):
            raise ValueError("each preference once")
        return v


class PreferencesOut(BaseModel):
    helps: list[str]
    line: LineOut


class WanderingAnswerIn(Strict):
    answer: Literal["a", "b"]


class StoryAnswer(BaseModel):
    id: Literal["a", "b"]
    text: str


class StoryOut(BaseModel):
    id: str
    text: str
    question: str
    answers: list[StoryAnswer]


class WanderingOut(BaseModel):
    state: Literal["home", "away", "back"] = Field(description="home: nothing going on; away: "
                                                   "Lanvi is wandering until returns_at; back: a "
                                                   "story waits for an answer.")
    id: Optional[str]
    returns_at: Optional[str]
    story: Optional[StoryOut]


class PlanToAsk(BaseModel):
    checkin_id: str
    plan_id: Optional[str] = Field(description="Catalog id, or null when the plan was typed "
                                               "(the app has the words on the phone).")


class LanviOut(BaseModel):
    xp: int
    stage: Literal["kit", "young_fox", "grown_fox"]
    next_stage_at: Optional[int]
    glow: float = Field(description="0 to 1.")
    wandering: WanderingOut
    line: LineOut = Field(description="The line Lanvi says today, from the fixed set.")
    plan_to_ask: Optional[PlanToAsk] = Field(description="Yesterday's plan, to ask about in "
                                                         "tonight's check-in; null if none.")


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
    lanvi: LanviOut
    round_config: dict = Field(description="Deprecated: for apps of the earlier AR design only.")
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
                    "followed. Never sent outside the server, except with CHAT_MODE=gemini "
                    "(default fixed), where a note that did not open the help screen goes "
                    "to Gemini so it can write Lanvi's reply.")


class NoteReplyOut(BaseModel):
    template_id: str = Field(description="A fixed line's id, or `gemini` when Gemini wrote "
                                         "the reply (CHAT_MODE=gemini).")
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
    action: Literal["breathing", "focus_game", "checkin", "walk_10min", "daylight_10min",
                    "call_someone"]


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


ActivityOut.model_rebuild()

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
    headline: str = Field(description="At most 6 words, from a fixed set, for one row.")
    outcome: Literal["attention_opened", "attention_raised", "attention_closed", "suggested",
                     "message_sent", "refused", "nothing"] = Field(
        description="The most important thing the chain did.")
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


class RecomputeFaceIn(Strict):
    patient_id: ServerId


class RecomputeFaceOut(BaseModel):
    patient_id: str
    recomputed: int = Field(description="Raw sessions whose face summary was computed again.")


class FaceRawOut(BaseModel):
    """The stored raw frames of one activity, as the phone sent them, for
    research download. Numbers only."""
    activity_id: str
    type: Literal["focus", "breathing"]
    started_at: str
    received_at: str
    rate_hz: float
    channels: list[str]
    samples: list[list[float]]
    tracked: Optional[list[int]] = Field(description="As sent; null means all frames tracked.")
    moments_ms: Optional[list[int]]
    frames: int
    channel_count: int
    tracked_frames: int


class AnalyzeIn(Strict):
    patient_id: ServerId
    round_id: Optional[ClientId] = Field(None, description="An AR round (earlier design).")
    activity_id: Optional[ClientId] = Field(None, description="A focus or breathing activity.")
    what: Literal["session", "frames", "days"] = Field(
        "session", description="With activity_id: `session` runs the session reading, `frames` "
                               "the frame reading (level 2 reads the raw face frames, code checks "
                               "every item; the activity must have been sent with face_raw). "
                               "`days`, without an id: the day reading (level 2 reads the daily "
                               "numbers of the last weeks, code checks every item).")

    @model_validator(mode="after")
    def _one(self):
        if self.what == "days":
            if self.round_id is not None or self.activity_id is not None:
                raise ValueError("what=days takes no round_id or activity_id")
            return self
        if (self.round_id is None) == (self.activity_id is None):
            raise ValueError("give either round_id or activity_id")
        if self.what == "frames" and self.activity_id is None:
            raise ValueError("what=frames needs activity_id")
        return self


# ---- clinician: reference ratings and the association appraisal ----------------------

_Date = date


class ClinicRuleIn(Strict):
    text: str = Field(min_length=3, max_length=300,
                      description="The rule in the clinician's own words, for this one person.")
    days: int = Field(14, ge=1, le=90, description="How many days the rule applies. After that "
                                                    "it stops being read and the levels are "
                                                    "set without it.")

    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [
        {"text": "She visits her mother on Sundays and walks less; a low Sunday needs no attention."}]})


class ClinicRuleOut(BaseModel):
    id: str
    text: str
    at: str
    by: Optional[str] = None
    expires_at: Optional[str] = Field(None, description="When the rule stops applying.")


class ClinicRulesOut(BaseModel):
    rules: list[ClinicRuleOut]
    applies: bool = Field(description="True when the two model levels set the levels "
                                      "(TRIAGE_MODE=models); otherwise the rules are stored "
                                      "but nothing reads them.")


class RatingIn(Strict):
    date: _Date = Field(description="The day the rating describes (clinic local).")
    scale: Literal["phq9", "phq2", "clinician_global"]
    score: int = Field(description="Total score. Range per scale: phq9 0 to 27, phq2 0 to 6, "
                                   "clinician_global 1 to 7.")

    model_config = ConfigDict(extra="forbid", json_schema_extra={"examples": [
        {"date": "2026-11-13", "scale": "phq9", "score": 9}]})


class RatingOut(BaseModel):
    id: str
    date: str
    scale: Literal["phq9", "phq2", "clinician_global"]
    score: int
    created_at: str
    example: bool = Field(description="True for seeded example ratings.")


class RatingsOut(BaseModel):
    ratings: list[RatingOut] = Field(description="Oldest first.")


Source = Optional[Literal["model", "code", "code_corrected"]]


class AssocCaveatOut(BaseModel):
    code: str
    text: str = Field(description="Plain text for the code, from a fixed set.")
    by: Literal["model", "code"]


class AssocRowOut(BaseModel):
    key: str = Field(examples=["face.smile_time_share"])
    label: str
    group: Literal["face", "activity", "daily"]
    expected: Literal["lower", "higher", "mixed"] = Field(
        description="Direction the research literature leads us to expect when symptoms are worse.")
    support: Literal["stronger", "moderate", "weaker", "mixed"]
    why: str
    status: Literal["tested", "insufficient", "no_variation", "is_reference"] = Field(
        description="insufficient: fewer paired days than design.min_n, no statistics. "
                    "is_reference: this measure is the proxy reference itself.")
    n: int = Field(description="Paired observations: ratings (design.unit rating) or days.")
    rho: Optional[float] = Field(None, description="Spearman rho, oriented: positive = moves in "
                                 "the expected direction when symptoms are worse. For 'mixed' "
                                 "positive = higher when the reference is worse.")
    ci_low: Optional[float] = None
    ci_high: Optional[float] = None
    p_adj: Optional[float] = Field(None, description="Permutation p, Benjamini-Hochberg adjusted.")
    lead_days: Optional[int] = Field(None, description="Lag -3..3 with the largest oriented "
                                     "association; negative = the measure moves first.")
    contrast: Optional[float] = Field(None, description="Cliff's delta, days with attention held "
                                      "against other days, oriented like rho.")
    change_rho: Optional[float] = Field(None, description="With design.unit rating: Spearman rho "
                                        "of the CHANGES from one rating to the next (measure "
                                        "against score), oriented like rho. Two series that only "
                                        "drift over the same weeks are high in rho and low here.")
    change_n: Optional[int] = Field(None, description="Pairs of neighbouring ratings behind change_rho.")
    quality: Optional[float] = Field(None, description="Share of sessions (or days) usable.")
    agreement: Optional[Literal["consistent", "opposite", "inconclusive",
                                "related_no_prediction"]] = None
    strength: Optional[Literal["negligible", "weak", "moderate", "strong"]] = None
    agreement_source: Source = Field(None, description="model, code (no model), or "
                                     "code_corrected (the model's value was replaced).")
    strength_source: Source = None
    caveats: list[AssocCaveatOut]


class AssocOverallOut(BaseModel):
    pattern: Literal["consistent_with_worse_state", "partly_consistent", "no_clear_relation",
                     "opposite_to_expectation", "insufficient_data"]
    confidence: Literal["low", "medium", "high"]
    independent_lines: int
    strongest: list[str]
    leads_reference: bool
    main_alternative: str
    main_alternative_text: str
    next_step: Literal["collect_more_sessions", "add_reference_rating", "review_tracking_quality",
                       "discuss_with_patient", "none"]
    sources: dict[str, Literal["model", "code", "code_corrected"]] = Field(
        description="Per field: model, code, or code_corrected.")


class AssocDesignOut(BaseModel):
    type: Literal["within_person_time_series"]
    days: int
    sessions: int
    first_day: str
    last_day: str
    rows_tested: int
    min_n: int
    unit: Optional[Literal["rating", "day"]] = Field(None, description="What one observation is: "
                                                     "a rating (the measure is averaged over the week "
                                                     "up to it) or a day (proxy reference).")
    observations: Optional[int] = None
    low_below_ratings: Optional[int] = Field(None, description="With design.unit rating, fewer "
                                             "ratings than this always give confidence low.")


class AssocReferenceOut(BaseModel):
    key: str = Field(examples=["phq9", "movement_z"])
    label: str
    kind: Literal["rating", "proxy"]
    worse_is: Literal["higher", "lower"]
    ratings: Optional[int] = Field(None, description="Ratings of that scale, when a rating.")


class AssocNoteOut(BaseModel):
    code: str
    text: str


class AssocCorrectionOut(BaseModel):
    where: Literal["row", "overall"]
    key: Optional[str]
    field: str
    model: Optional[Union[str, int, bool, list[str]]] = Field(
        description="The model's value when it was a known code; null otherwise.")
    code: Optional[Union[str, int, bool, list[str]]]
    reason: str


class AssocInputsOut(BaseModel):
    reference: str
    n_days: int
    n_sessions: int
    generated_at: str
    model: str = Field(description="The model's name, or 'code'.")


class AssociationsOut(BaseModel):
    status: Literal["ready", "none"] = Field(description="none: not computed yet.")
    appraised_by: Optional[Literal["model", "code"]] = None
    checked_by: Optional[Literal["code"]] = None
    generated_at: Optional[str] = None
    design: Optional[AssocDesignOut] = None
    reference: Optional[AssocReferenceOut] = None
    rows: list[AssocRowOut] = Field(default_factory=list)
    overall: Optional[AssocOverallOut] = None
    data_notes: list[AssocNoteOut] = Field(default_factory=list)
    corrections: list[AssocCorrectionOut] = Field(default_factory=list)
    hypotheses_reviewed_by_clinician: bool = False
    disclaimer: str
    series: Optional[dict] = Field(None, description="Day-by-day values behind the statistics, "
                                   "for charts: first_day, last_day, reference [[day, value]] and "
                                   "measures {key: [[day, value]]}; day counts from first_day.")
    inputs: Optional[AssocInputsOut] = None
