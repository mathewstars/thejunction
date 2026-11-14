"""Lanvi's growth: every value the designer may tune, in one place.

Rules that never change (docs/game-design.md):
- XP is for showing up, never for playing well. The same XP whatever the score.
- XP never goes down. Nothing removes an award once it is given.
- No streaks. Nothing here counts days in a row.
- Count each thing once: by record id, and by day where a cap is set.
"""

from __future__ import annotations

# XP per thing the person did.
XP = {
    "focus": 10,  # Revontulet (or Sparks and snow) played, finished or not
    "breathing": 10,  # Breathe with Lanvi done (finished or not)
    "checkin": 10,  # evening check-in done
    "plan_done": 15,  # yesterday's plan done (the person said yes)
    "day_normal": 5,  # walked or slept around own normal that day (Apple Health)
}

# At most this many awards per activity type per local day (each record id
# still counts once). Stops tapping the same game twenty times for XP.
MAX_AWARDS_PER_DAY = {"focus": 2, "breathing": 2, "checkin": 1}

# An activity shorter than this earns nothing (an accidental open).
MIN_SECONDS_FOR_XP = 5.0

# "Around own normal" for the daily award: steps not clearly below normal,
# or sleep near normal. In robust z against the person's own days.
DAY_STEPS_Z_AT_LEAST = -1.0
DAY_SLEEP_ABS_Z_AT_MOST = 1.0

# Stages: (id, XP needed). Growth never goes back.
STAGES = [("kit", 0), ("young_fox", 100), ("grown_fox", 300)]

# The glow meter fills with XP. When full, a wandering starts.
GLOW_CAPACITY_XP = 50
WANDERING_HOURS = 3.0

# Lanvi says "welcome back" when the last visit is at least this many days ago.
WELCOME_BACK_AFTER_DAYS = 3

# Onboarding: what helps the person. The starting order of suggestions
# before any lesson exists (first listed preference first).
PREFERENCE_ACTIONS = {
    "moving": ("walk_10min", "daylight_10min"),
    "music": ("breathing", "focus_game"),
    "people": ("call_someone",),
    "quiet": ("breathing", "checkin"),
}


def stage_for(xp: int) -> tuple[str, int | None]:
    """(stage id, XP of the next stage or None at the last stage)."""
    current, nxt = STAGES[0][0], None
    for i, (sid, need) in enumerate(STAGES):
        if xp >= need:
            current = sid
            nxt = STAGES[i + 1][1] if i + 1 < len(STAGES) else None
    return current, nxt
