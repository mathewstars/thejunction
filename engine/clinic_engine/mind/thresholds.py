"""Every threshold the mind uses, in one place.

The values are frozen. Nothing the mind learns (lessons) and nothing a model
says can change them; only a code change can. A test checks this.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Thresholds:
    # Baseline: robust median and MAD over the person's own trailing days.
    baseline_window_days: int = 28
    baseline_exclude_recent: int = 5  # the newest days do not shape "normal"
    baseline_min_days: int = 14
    mad_to_sigma: float = 1.4826

    # Deviation watcher: a sustained drop below own normal.
    low_day_z: float = -1.5  # a day is "clearly below" at or under this
    deviation_lookback: int = 5
    deviation_min_low: int = 3  # at least 3 of the last 5 days with data
    recovery_days: int = 3  # this many days in a row back near normal closes it
    recovered_z: float = -1.0

    # Novelty watcher: one day far from normal, either way.
    novelty_z: float = 3.0
    novelty_close_days: int = 3

    # Silence watcher: no daily data.
    silence_days: int = 3

    # Ignored watcher: suggestions left without an answer in a row.
    ignored_in_a_row: int = 3

    # Oddity watcher: rejected records keep a "watch" item open this long.
    oddity_hold_days: int = 7

    # Escalation to "urgent" (means: a clinician should review this today).
    urgent_deep_z: float = -2.5  # mean movement z of the recent low days
    urgent_deep_min_low: int = 4  # with at least this many low days of the last 5
    urgent_held_days: int = 10  # a deviation held this long needs review

    # Rounds (docs/game-interface.md, section 4).
    round_min_normal_ratio: float = 0.7  # below: low quality, never in a baseline
    round_min_play_area_m2: float = 2.0
    round_baseline_min: int = 5  # good rounds in the same mode
    round_baseline_max: int = 20
    round_energy_low: float = -1.0
    round_energy_high: float = 1.0
    round_fade_z: float = -1.5
    round_stopped_early_of_3: int = 2
    round_not_played_in_a_row: int = 3
    # Two weak rounds in a row let the deviation watcher open one low day earlier.
    round_weak_lowers_deviation_by: int = 1

    # Activities (docs/game-design.md): own normal per activity type and per
    # feature, robust median and MAD over the person's earlier sessions.
    activity_baseline_min: int = 5  # earlier sessions of the same type before any z
    activity_baseline_max: int = 20
    activity_min_reactions: int = 5  # a focus session needs this many reaction times
    reaction_min_ms: int = 120  # faster taps are anticipations; left out of the median
    # A face summary enters a baseline only when tracking was good enough.
    # A low-quality summary is stored and shown, never used.
    face_min_quality: float = 0.6
    # Watchers on activities. Each looks at the last `activity_window`
    # sessions of its kind and needs `activity_min_hits` of them.
    activity_window: int = 3
    activity_min_hits: int = 2
    slower_reaction_z: float = 1.5  # median reaction time this far ABOVE own normal (slower)
    face_flat_z: float = -1.5  # facial activity or smiling this far below own normal
    checkins_habit_min: int = 3  # check-ins in the 14 days before, so stopping means something
    checkins_stopped_days: int = 3  # no check-in for this many days
    plans_not_done_in_a_row: int = 3  # plans answered "no" this many times in a row
    activity_not_played_in_a_row: int = 3  # offered activities left unplayed in a row
    # Rules for how activity signals combine with the daily data:
    # 1. Slower reactions and a flatter face open an item at "watch" only.
    #    On their own they never go higher, never trigger a suggestion and
    #    never produce any text for the person.
    # 2. They rise to "attention" only while a movement drop (deviation) is
    #    held: the daily data moved too.
    # 3. Either of them active lets the deviation watcher open one low day
    #    earlier (like two weak rounds did); never below two low days. They
    #    add weight; they never open a deviation alone.
    # 4. Check-ins stopped, plans repeatedly not done and activities offered
    #    but not played follow the same rule 1 and 2.
    activity_lowers_deviation_by: int = 1

    # Responder.
    suggestion_cooldown_hours: float = 6.0
    suggestion_ttl_hours: float = 20.0
    max_suggestions_per_day: int = 2

    # Learning.
    outcome_days: int = 2  # days after a suggestion that measure its outcome
    outcome_improved: float = 0.5  # change in movement z that counts as better
    outcome_worse: float = -0.5
    min_evidence: int = 3
    support_fraction: float = 0.6
    max_active_lessons: int = 15
    lesson_ttl_days: int = 30
    max_open_questions: int = 3

    # The association appraisal (mind/associations.py). Clinician-only research
    # output: none of these values touches attention, suggestions or lessons.
    assoc_window_days: int = 90  # days looked at, ending today
    assoc_min_n: int = 8  # paired days below which a row is "insufficient" (no rho)
    assoc_min_ratings: int = 8  # ratings of one scale before it is the reference (= assoc_min_n)
    assoc_occasion_days: int = 7  # a rating is paired with the measure's mean over this many days up to it
    assoc_rating_carry_days: int = 3  # a rating stands for the days this close to it
    assoc_max_lag: int = 3  # lead_days is looked for in -3..+3
    assoc_bootstrap: int = 1000  # bootstrap resamples for the 95% interval
    assoc_permutations: int = 1000  # permutations for the p-value
    assoc_seed: int = 20261113  # fixed, so results are reproducible
    assoc_p_adj_max: float = 0.10  # above this a row cannot be "consistent"
    assoc_weak_n: int = 12  # below this many paired days, at most "weak"
    assoc_high_n: int = 20  # "high" confidence needs this many paired days ...
    assoc_high_lines: int = 3  # ... this many independent lines, and a rating reference
    assoc_medium_lines: int = 2  # code's own "medium" needs this many lines
    assoc_strength_weak: float = 0.2
    assoc_strength_moderate: float = 0.4
    assoc_strength_strong: float = 0.6  # above this
    assoc_min_contrast_days: int = 2  # held and other days each, for Cliff's delta
    assoc_min_tested_rows: int = 3  # fewer tested rows: "insufficient_data"
    assoc_few_sessions: int = 10  # activity sessions in the period, below: few_sessions
    assoc_short_period_days: int = 21  # days with data, below: short_period
    assoc_poor_tracking_share: float = 0.3  # share of face sessions with low tracking
    assoc_row_quality_min: float = 0.7  # a row's usable share below this: poor_tracking
    assoc_many_tests: int = 5  # more tested rows than this: many_tests
    assoc_time_of_day_hours: int = 6  # sessions spread over this many hours: time_of_day
    assoc_max_tokens: int = 6000  # the model may think before answering


# Per-metric floor for the spread, so a very regular person does not get
# huge z-scores from tiny changes. In the metric's own unit.
MIN_SCALE = {
    "steps": 400.0,
    "walking_speed_m_s": 0.03,
    "hrv_ms": 3.0,
    "sleep_h": 0.3,
}

# Plausibility limits. Values outside are rejected by the oddity watcher.
PLAUSIBLE = {
    "steps": (0, 80_000),
    "walking_speed_m_s": (0.1, 3.0),
    "hrv_ms": (5.0, 250.0),
    "sleep_h": (0.0, 18.0),
}

# Floors for round feature spreads (same idea as MIN_SCALE).
ROUND_MIN_SCALE = {
    "caught_share": 0.05, "median_reaction_s": 0.2, "median_speed_m_s": 0.05,
    "coverage": 0.05, "still_share": 0.05, "vertical_range_m": 0.05, "fade": 0.05,
}

# Floors for activity feature spreads, in each feature's own unit.
ACTIVITY_MIN_SCALE = {
    "median_reaction_ms": 40.0, "reaction_spread_ms": 25.0, "error_rate": 0.05,
    "time_played_s": 5.0, "good_things": 0.5,
    "smile_rate_per_min": 0.5, "smile_intensity": 0.05, "facial_activity": 0.05,
    "blink_rate_per_min": 2.0, "look_down_share": 0.05, "head_tilt_deg": 2.0,
    "smile_time_share": 0.03, "eye_smile_share": 0.05, "smile_response_share": 0.1,
    "smile_response_latency_s": 0.3, "brow_down_share": 0.03, "inner_brow_up_share": 0.03,
    "blink_duration_ms": 15.0, "head_pitch_deg": 2.0, "head_movement": 0.05,
    "smile_asymmetry": 0.03,
}

METRICS = ("steps", "walking_speed_m_s", "hrv_ms", "sleep_h")
MOVEMENT_METRICS = ("steps", "walking_speed_m_s")

T = Thresholds()
