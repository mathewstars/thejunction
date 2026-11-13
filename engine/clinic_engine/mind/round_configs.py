"""The fixed catalog of round configs (docs/game-interface.md, section 5).

Design values for the game designer to tune. Ordered from gentlest to
hardest: code steps up and down this ladder one place at a time.
"""

from __future__ import annotations

ROUND_CONFIGS: dict[str, dict] = {
    "seated_gentle": {"mode_hint": "seated", "lights_total": 8, "distance_band": "reach",
                      "height_band": "low_mid", "light_life_s": 10, "catch_radius_m": 0.35},
    "near_gentle": {"mode_hint": "standing", "lights_total": 10, "distance_band": "near",
                    "height_band": "mid", "light_life_s": 9, "catch_radius_m": 0.35},
    "standard": {"mode_hint": "standing", "lights_total": 12, "distance_band": "mid",
                 "height_band": "mid", "light_life_s": 8, "catch_radius_m": 0.35},
    "wide": {"mode_hint": "standing", "lights_total": 12, "distance_band": "wide",
             "height_band": "mid", "light_life_s": 8, "catch_radius_m": 0.35},
    "wide_high": {"mode_hint": "standing", "lights_total": 14, "distance_band": "wide",
                  "height_band": "low_high", "light_life_s": 7, "catch_radius_m": 0.35},
}
LADDER = list(ROUND_CONFIGS)
DEFAULT_CONFIG = "standard"
ROUND_DURATION_S = 120
