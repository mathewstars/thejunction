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
    # Revontulet's own normal (shown to the clinician only). Stricter than the
    # other games because a game gives few numbers: 8 earlier games before any
    # comparison, and 2.5 either way before the page calls a game unusual. Set
    # with revontulet_check on generated games, at up to three times the
    # example's game-to-game spread: with 2.5 an unchanged person gets a label on
    # 0 to 10% of games against one reference, 0 to 13% against either (it was
    # 15 to 17% against one at 2.0 once games vary twice as much,
    # and 37% with 5 games, 1.5 and a label on time to choose as well).
    revontulet_baseline_min: int = 8
    revontulet_unusual_z: float = 2.5
    # The fixed reference: the person's start, games 3 to 12 (the first two are practice).
    revontulet_start_from: int = 2
    revontulet_start_to: int = 12
    activity_min_reactions: int = 5  # a focus session needs this many reaction times
    # Revontulet gives few: three rounds, two embers on a hard round, so at most six
    # ember taps a game, and none on an easy-only game. One hard round with both
    # embers lit is enough for a median; the spread still needs four.
    revontulet_min_reactions: int = 2
    # A touch on the sleeping fox shorter than this is a flick, not a stroke
    # (a real game sent one of 121 ms next to strokes of 763 and 4480 ms).
    revontulet_min_stroke_ms: int = 300
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

    # Raw face frames (mind/face_features.py, docs/face-raw.md). The phone sends
    # what ARKit gives per frame; the server derives the face summary with these
    # rules. Change them and run POST /v1/demo/recompute-face to re-analyse the
    # stored frames. Event rules follow the FaceMetrics research app
    # (facemetrics/FaceMetrics/Analysis): hysteresis onset/offset on a coefficient.
    face_raw_min_tracked_s: float = 5.0  # less tracked time: every measure null but tracking_quality
    face_raw_overshoot: float = 0.02  # blend shapes may overshoot 0..1 by this; clamped before use
    # Smile: mean(mouthSmileLeft, mouthSmileRight). Starts at >= onset, ends at
    # <= offset (FaceMetrics activationOnset / activationOffset), counts if it lasts.
    smile_onset: float = 0.25
    smile_offset: float = 0.15
    smile_min_s: float = 0.3  # shorter runs are flickers, not smiles
    # A smile "reaches the eyes" when mean(cheekSquintLeft, cheekSquintRight)
    # inside it is at least this.
    eye_smile_cheek_min: float = 0.2
    # A marked pleasant moment is answered when a smile starts within this many
    # seconds after it.
    smile_response_window_s: float = 2.5
    # Blink: max(eyeBlinkLeft, eyeBlinkRight), i.e. starts when either eye is at
    # >= onset, ends when both are at <= offset (FaceMetrics BlinkConfiguration).
    blink_onset: float = 0.5
    blink_offset: float = 0.3
    blink_min_s: float = 0.03  # shorter: noise
    blink_max_s: float = 0.5  # longer: an eye closure, not a blink; left out of rate and length
    # Share of tracked frames at or above these values.
    look_down_min: float = 0.3  # mean(eyeLookDownLeft, eyeLookDownRight)
    brow_down_min: float = 0.3  # mean(browDownLeft, browDownRight)
    inner_brow_up_min: float = 0.3  # browInnerUp
    lip_down_min: float = 0.3  # mean(mouthFrownLeft, mouthFrownRight): lip corners pulled down
    lip_press_min: float = 0.3  # mean(mouthPressLeft, mouthPressRight): lips pressed together
    # Movement is measured on short blocks of frames (about 0.1 s, never shorter
    # than one frame) so that the frame rate does not change the result.
    face_motion_block_s: float = 0.1
    # facial_activity = mean |change per second| over the blend shapes (blinks
    # left out), divided by this and clipped to 0..1. Chosen so that a still face
    # (ARKit jitter, about 0.05 per second) gives about 0.1 and a lively face
    # (talking, smiling, about 0.3 per second) about 0.6. Estimated, not yet
    # calibrated on recordings.
    facial_activity_full_per_s: float = 0.5
    # head_movement = mean angular speed of the head (pitch, yaw, roll together,
    # degrees per second) divided by this and clipped to 0..1: a still head
    # (about 3 deg/s of jitter and small sway) gives about 0.1, a lively one
    # (about 18 deg/s) about 0.6. Estimated, not yet calibrated.
    head_movement_full_deg_s: float = 30.0

    # The frame reading (mind/frame_reading.py, data/frames_prompt.txt): the
    # level-2 model reads a reduced stream of the raw frames; code checks every
    # item on the full-rate frames. Clinician-only: none of these values
    # touches suggestions or lessons (a confirmed finding may open a watch flag).
    frames_rate_hz: float = 5.0  # rows per second sent (blocks of frames averaged)
    frames_max_frames: int = 400  # longer recordings get a lower rate to fit
    # A reported smile is the same smile as one code found when the two spans
    # overlap by at least this share of their union (the model reads 5 rows per
    # second, so its edges are up to 0.2 s off; a sliver inside a smile and a
    # span several times wider than it both fall below).
    frames_smile_iou: float = 0.3
    # A faint smile: a reported smile that touches no smile of code's (the
    # signal stayed under smile_onset) is kept apart when, over its span, the
    # smile signal lies above the session's resting level (its median) by this
    # much on average and this much at its peak. Estimated, not calibrated;
    # ARKit jitter on a resting mouth is about 0.02.
    frames_faint_mean_rise: float = 0.05
    frames_faint_peak_rise: float = 0.10
    # The resting level a faint smile is measured against is local: the median
    # of the smile signal within this many seconds before the span and after it
    # (code's smiles left out), the higher of the two, so a step in the baseline
    # (the phone moved) is not read as a smile. Each mouth corner must carry at
    # least this share of the mean rise: jitter in one corner is not a smile.
    # A report that lies inside a smile of code's at least this many times
    # longer is not dropped as a poor match at once: the fixed rule merges a
    # whole stretch into one smile when a mouth rests near the onset. It is
    # tested against the local rest (code's smiles not left out, twice the
    # peak rise) and kept apart as "inside_long" when the rise is there.
    frames_long_smile_ratio: float = 4.0
    frames_long_smile_min_s: float = 5.0  # and code's smile lasts at least this long
    frames_faint_window_s: float = 8.0
    frames_faint_side_share: float = 0.5
    # A reported segment must last this long (the prompt asks for two seconds);
    # eyes_closed and not_tracked may be shorter.
    frames_segment_min_s: float = 2.0
    frames_segment_min_short_s: float = 0.5
    # Code's "side" of a smile: mean(mouthSmileLeft - mouthSmileRight) inside it
    # at least this (left) or at most minus this (right); else "both".
    frames_side_diff: float = 0.15
    # Blinks agree when the counts differ by at most max(n, share x code's count).
    frames_blink_tolerance_n: int = 2
    frames_blink_tolerance_share: float = 0.2
    # Segments: a frame counts for "head_down" at this headPitch or more, for
    # "still_face" when its 0.1 s block moves less than this per second (mean
    # over the blend shapes, blinks left out), for "eyes_closed" at blink_onset;
    # the other kinds use look_down_min, brow_down_min and inner_brow_up_min.
    frames_head_down_deg: float = 15.0
    frames_still_speed: float = 0.1
    # A reported segment is confirmed when code's share of its span (tracked
    # frames; all frames for not_tracked) is at least this.
    frames_share_looking_down: float = 0.6
    frames_share_brows_down: float = 0.6
    frames_share_inner_brows_raised: float = 0.6
    frames_share_head_down: float = 0.6
    frames_share_still_face: float = 0.7
    frames_share_eyes_closed: float = 0.7
    frames_share_not_tracked: float = 0.8
    # The overall words, from code's face summary:
    # expression: facial_activity >= lively_min "lively", >= still_below "moderate", else "still"
    frames_lively_min: float = 0.45
    frames_still_below: float = 0.2
    # smiling: no smile "none"; smile_rate_per_min >= often_min "often",
    # >= sometimes_min "sometimes", else "rarely"
    frames_smiling_often_min: float = 3.0
    frames_smiling_sometimes_min: float = 1.0
    # gaze: look_down_share >= this "often_down", else "mostly_up"
    frames_gaze_down_share: float = 0.3
    # tracking: tracking_quality >= good "good", >= face_min_quality "partly", else "poor"
    frames_tracking_good: float = 0.9

    # The day reading (mind/day_reading.py, data/days_prompt.txt): the level-2
    # model reads the daily numbers of the last weeks; code checks every item.
    # Clinician-only: none of these values touches attention, suggestions or
    # lessons. All are estimates, not calibrated on real series.
    dayr_max_days: int = 84  # the window sent, in calendar days
    dayr_min_days: int = 21  # days with steps needed before anything is sent
    dayr_min_channel_days: int = 14  # a channel is sent when it has this many values
    dayr_min_before: int = 7  # values needed before a day or a stretch to judge it
    # Code's own stretches: days at least this many spreads outside the trailing
    # normal, for at least dayr_min_len days with data.
    dayr_code_z: float = 1.5
    dayr_min_len: int = 3
    # A reported stretch is in the numbers when its median lies this many
    # spreads from the days before (milder than code's own rule: the model may
    # name a stretch the fixed rule does not flag, and code confirms it here).
    dayr_stretch_z: float = 1.0
    # A gradual stretch: at least this long, the values fall day by day
    # (Spearman of value against day), and its last third lies dayr_stretch_z
    # spreads from its first third.
    dayr_gradual_min_len: int = 7
    dayr_gradual_rho: float = 0.5
    # The same stretch as code's: overlap over the union of the two spans.
    dayr_iou: float = 0.3
    # A weekday is this person's low day when its median lies this many spreads
    # under the other days, with at least this many of that weekday, and it is
    # low week after week.
    dayr_weekday_z: float = 1.0
    dayr_weekday_min_n: int = 3
    dayr_weekday_share: float = 0.8  # and this share of that weekday's values lie under
    dayr_gap_min: int = 2  # days in a row without steps
    dayr_overall_z: float = 1.0  # the last seven days' median for "lower" or "higher"
    dayr_min_hours_between: float = 6.0  # a new reading at most this often per person
    # A flag from what the model found and code confirmed (watchers.model_noticed):
    # a daily reading counts while it is this fresh and its stretch reaches within
    # this many days of the window's end; the face rule looks at this many readings.
    model_notice_max_age_days: int = 3
    model_notice_recent_days: int = 3
    model_notice_face_window: int = 6

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
    # Revontulet has few embers a game (four in a real game on 14 November), so
    # its floors are wider than Sparks and snow's: one ember missed of four is a
    # quarter and stays inside the usual range, and a middle reaction time from
    # two to six taps moves more than one from sixteen.
    "revontulet.error_rate": 0.25, "revontulet.median_reaction_ms": 60.0,
    # Revontulet: with three rounds one choice is a third; the floor keeps a single
    # different choice inside the usual range (0.33 / 0.25 = 1.3) and two outside it.
    "hard_share": 0.25, "choice_ms": 150.0,
    # The two speeds: floors of about 4% of what real games showed on 14 November
    # (tracing near 14 cm/s, strokes near 20), as they were 4% of the first guess.
    "trace_speed_cm_s": 0.6, "stroke_speed_cm_s": 0.9,
    "smile_rate_per_min": 0.5, "smile_intensity": 0.05, "facial_activity": 0.05,
    "blink_rate_per_min": 2.0, "look_down_share": 0.05, "head_tilt_deg": 2.0,
    "smile_time_share": 0.03, "eye_smile_share": 0.05, "smile_response_share": 0.1,
    "smile_response_latency_s": 0.3, "brow_down_share": 0.03, "inner_brow_up_share": 0.03,
    "blink_duration_ms": 15.0, "head_pitch_deg": 2.0, "head_movement": 0.05,
    "smile_asymmetry": 0.03, "lip_down_share": 0.03, "lip_press_share": 0.03,
}

METRICS = ("steps", "walking_speed_m_s", "hrv_ms", "sleep_h")
MOVEMENT_METRICS = ("steps", "walking_speed_m_s")

T = Thresholds()
