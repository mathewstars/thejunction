"""Settings, read from environment variables.

Nothing secret has a default here. Copy `.env.example` to `.env`, fill it in,
and load it into the environment (systemd EnvironmentFile, or `set -a; . ./.env`).
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _env_int(name: str, default: int) -> int:
    raw = _env(name)
    return int(raw) if raw else default


def _env_float(name: str, default: float) -> float:
    raw = _env(name)
    return float(raw) if raw else default


def _env_bool(name: str, default: bool) -> bool:
    raw = _env(name).lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")




@dataclass
class Settings:
    product_name: str = "Angel"

    # Storage: memory | dir | s3
    store: str = "dir"
    store_dir: str = "./data"
    store_packed: bool = True  # S3 only: keep a patient's small records together (see PackedStore)
    s3_endpoint_url: str = ""
    s3_bucket: str = ""
    s3_access_key: str = ""
    s3_secret_key: str = ""
    s3_region: str = "us-east-1"

    # HTTP layer
    cors_origins: list[str] = field(default_factory=list)
    max_body_bytes: int = 256 * 1024
    # POST /v1/activities only: an activity may carry raw face frames
    # (12,000 frames x up to 60 numbers at most).
    max_face_raw_body_bytes: int = 4 * 1024 * 1024
    rate_per_minute: int = 120
    rate_burst: int = 60
    session_ttl_minutes: int = 120
    pairing_ttl_hours: int = 24
    # Linking switched off for a demo: the label of the one patient every phone is
    # connected to, whatever pairing code it sends. Empty (the default) = codes are checked.
    open_pairing_patient: str = ""

    # The mind
    default_timezone: str = "Europe/Helsinki"
    tick_seconds: int = 300
    review_inline: bool = False  # run background work (review, reading) inline (tests)
    reading_images: bool = True  # send two small trail pictures with the movement reading

    # Level 1: local model on the private network (OpenAI-compatible)
    local_llm_base_url: str = ""
    local_llm_model: str = ""
    local_llm_api_key: str = ""
    local_llm_timeout_s: float = 8.0
    # The association appraisal lets the model think: it gets a longer timeout.
    local_llm_appraisal_timeout_s: float = 180.0

    # Level 2: Gemini, reached only through outreach.py
    outreach_mode: str = "off"  # off | gemini | standin (the local model answers level 2; nothing leaves)
    session_reader: str = "auto"  # auto (level 2 when it is on) | local (level 1 reads sessions) | off
    gemini_api_key: str = ""
    gemini_model: str = ""  # placeholder: set the model id in the environment
    gemini_timeout_s: float = 15.0
    # The frame reading (level 2 reads the raw face frames; code checks it).
    # Gemini thinks before it answers on a long stream: it gets more room.
    frames_reader: str = "auto"  # auto (when level 2 is on) | off
    days_reader: str = "auto"  # the day reading: auto (when level 2 is on) | off
    # Who sets the level of an attention item. "rules": the fixed rules in
    # watchers.escalate. "models": the watchers stay the triggers, and the two
    # model levels set the level (level 1, then level 2 agrees, raises or
    # lowers); the rules' level is the fallback, and a request for help is
    # always urgent by rule.
    triage_mode: str = "rules"
    triage_retry_minutes: int = 20  # after a run in which no model answered
    gemini_frames_max_tokens: int = 16000  # the model's thinking counts against it
    gemini_frames_retry_wait_s: float = 2.0
    gemini_frames_timeout_s: float = 60.0
    gemini_days_timeout_s: float = 150.0  # the day reading thinks longer over 84 rows
    # How much the model thinks before it answers: low (a few seconds a reading),
    # high, or default (the model's own, about half a minute a reading).
    gemini_thinking: str = "low"
    gemini_fallback_model: str = ""  # used when the main model keeps failing; empty: none

    # Lanvi's reply to a note: fixed (a vetted line, nothing leaves the server)
    # | gemini (Gemini writes the reply for a note that did not open the help screen,
    # checked by code; any failure falls back to the fixed line). Needs GEMINI_API_KEY
    # and a model id (CHAT_MODEL, else GEMINI_MODEL). Independent of OUTREACH_MODE.
    chat_mode: str = "fixed"
    chat_model: str = ""
    chat_timeout_s: float = 4.0
    # How much the chat model thinks before it answers (for example "low"). Empty:
    # the request says nothing and the model uses its own default.
    chat_thinking: str = ""

    # Help (crisis) block, always shown by GET /v1/today. Wording: data/help_block.json
    emergency_number: str = "112"
    clinic_contact_label: str = ""  # e.g. "the clinic's nurse line"
    clinic_contact_phone: str = ""

    # Urgent notifier (outbound, through outreach.py)
    notify_mode: str = "off"  # off | telegram
    telegram_bot_token: str = ""
    telegram_chat_id: str = ""
    clinician_page_url: str = ""
    notify_hours: str = "08-18"  # clinic local hours when a message may be sent
    notify_queue_outside_hours: bool = True  # queue to next window, else drop
    notify_max_per_hour: int = 10
    clinic_timezone: str = "Europe/Helsinki"

    demo_enabled: bool = True

    # The association appraisal (clinician-only research output), once a day per patient.
    associations_enabled: bool = True

    @classmethod
    def from_env(cls) -> "Settings":
        origins = [o.strip() for o in _env("CORS_ORIGINS").split(",") if o.strip()]
        return cls(
            product_name=_env("PRODUCT_NAME", "Angel"),
            store=_env("STORE", "dir").lower(),
            store_dir=_env("STORE_DIR", "./data"),
            store_packed=_env("STORE_PACKED", "true").lower() in ("1", "true", "yes"),
            s3_endpoint_url=_env("S3_ENDPOINT_URL"),
            s3_bucket=_env("S3_BUCKET"),
            s3_access_key=_env("S3_ACCESS_KEY"),
            s3_secret_key=_env("S3_SECRET_KEY"),
            s3_region=_env("S3_REGION", "us-east-1"),
            cors_origins=origins,
            max_body_bytes=_env_int("MAX_BODY_BYTES", 256 * 1024),
            max_face_raw_body_bytes=_env_int("MAX_FACE_RAW_BODY_BYTES", 4 * 1024 * 1024),
            rate_per_minute=_env_int("RATE_PER_MINUTE", 120),
            rate_burst=_env_int("RATE_BURST", 60),
            session_ttl_minutes=_env_int("SESSION_TTL_MINUTES", 120),
            pairing_ttl_hours=_env_int("PAIRING_TTL_HOURS", 24),
            open_pairing_patient=_env("OPEN_PAIRING_PATIENT", ""),
            default_timezone=_env("DEFAULT_TIMEZONE", "Europe/Helsinki"),
            tick_seconds=_env_int("TICK_SECONDS", 300),
            review_inline=_env_bool("REVIEW_INLINE", False),
            reading_images=_env_bool("READING_IMAGES", True),
            local_llm_base_url=_env("LOCAL_LLM_BASE_URL"),
            local_llm_model=_env("LOCAL_LLM_MODEL"),
            local_llm_api_key=_env("LOCAL_LLM_API_KEY"),
            local_llm_timeout_s=_env_float("LOCAL_LLM_TIMEOUT_S", 8.0),
            local_llm_appraisal_timeout_s=_env_float("LOCAL_LLM_APPRAISAL_TIMEOUT_S", 180.0),
            outreach_mode=_env("OUTREACH_MODE", "off").lower(),
            session_reader=_env("SESSION_READER", "auto").lower(),
            gemini_api_key=_env("GEMINI_API_KEY"),
            gemini_model=_env("GEMINI_MODEL"),
            gemini_timeout_s=_env_float("GEMINI_TIMEOUT_S", 15.0),
            frames_reader=_env("FRAMES_READER", "auto").lower(),
            days_reader=_env("DAYS_READER", "auto").lower(),
            triage_mode=_env("TRIAGE_MODE", "rules").lower(),
            triage_retry_minutes=_env_int("TRIAGE_RETRY_MINUTES", 20),
            gemini_frames_max_tokens=_env_int("GEMINI_FRAMES_MAX_TOKENS", 16000),
            gemini_frames_retry_wait_s=_env_float("GEMINI_FRAMES_RETRY_WAIT_S", 2.0),
            gemini_frames_timeout_s=_env_float("GEMINI_FRAMES_TIMEOUT_S", 60.0),
            gemini_days_timeout_s=_env_float("GEMINI_DAYS_TIMEOUT_S", 150.0),
            gemini_thinking=_env("GEMINI_THINKING", "low").lower(),
            gemini_fallback_model=_env("GEMINI_FALLBACK_MODEL", ""),
            chat_mode=_env("CHAT_MODE", "fixed").lower(),
            chat_model=_env("CHAT_MODEL"),
            chat_timeout_s=_env_float("CHAT_TIMEOUT_S", 4.0),
            chat_thinking=_env("CHAT_THINKING", "").lower(),
            emergency_number=_env("EMERGENCY_NUMBER", "112"),
            clinic_contact_label=_env("CLINIC_CONTACT_LABEL"),
            clinic_contact_phone=_env("CLINIC_CONTACT_PHONE"),
            notify_mode=_env("NOTIFY_MODE", "off").lower(),
            telegram_bot_token=_env("TELEGRAM_BOT_TOKEN"),
            telegram_chat_id=_env("TELEGRAM_CHAT_ID"),
            clinician_page_url=_env("CLINICIAN_PAGE_URL"),
            notify_hours=_env("NOTIFY_HOURS", "08-18"),
            notify_queue_outside_hours=_env_bool("NOTIFY_QUEUE_OUTSIDE_HOURS", True),
            notify_max_per_hour=_env_int("NOTIFY_MAX_PER_HOUR", 10),
            clinic_timezone=_env("CLINIC_TIMEZONE", "Europe/Helsinki"),
            demo_enabled=_env_bool("DEMO_ENABLED", True),
            associations_enabled=_env_bool("ASSOCIATIONS_ENABLED", True),
        )
