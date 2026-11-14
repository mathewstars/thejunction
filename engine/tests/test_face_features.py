"""The face summary computed on the server from raw frames: synthetic frame
sequences with known answers."""

import math

import pytest

from clinic_engine.mind.face_features import SUMMARY_FIELDS, check_raw, describe, summarize

from face_synth import REQUIRED, make_raw

SMILE = 0.6


def test_no_smile():
    s = summarize(make_raw())
    assert s["tracking_quality"] == 1.0
    assert s["smile_rate_per_min"] == 0 and s["smile_time_share"] == 0
    assert s["smile_intensity"] is None and s["smile_asymmetry"] is None
    assert s["eye_smile_share"] is None


def test_three_clear_smiles_of_known_length():
    s = summarize(make_raw(seconds=60, smiles=[(5, 1.0, SMILE, SMILE), (20, 1.0, SMILE, SMILE),
                                               (40, 1.0, SMILE, SMILE)]))
    assert s["smile_rate_per_min"] == 3.0
    assert s["smile_time_share"] == pytest.approx(3 / 60, abs=1e-3)
    assert s["smile_intensity"] == pytest.approx(SMILE)
    assert s["smile_asymmetry"] == 0


def test_a_flicker_shorter_than_the_minimum_is_not_a_smile():
    s = summarize(make_raw(smiles=[(10, 0.2, SMILE, SMILE), (30, 1.0, SMILE, SMILE)]))
    assert s["smile_rate_per_min"] == 1.0
    assert s["smile_time_share"] == pytest.approx(1 / 60, abs=1e-3)


def test_one_sided_smile_counts_and_shows_as_asymmetry():
    s = summarize(make_raw(smiles=[(10, 1.0, 0.6, 0.1)]))
    assert s["smile_rate_per_min"] == 1.0
    assert s["smile_intensity"] == pytest.approx(0.35)
    assert s["smile_asymmetry"] == pytest.approx(0.5)


def test_hysteresis_keeps_one_smile_through_a_dip_above_the_offset():
    # 0.6 for 1 s, 0.2 (between offset and onset) for 0.5 s, 0.6 for 1 s: one smile.
    s = summarize(make_raw(smiles=[(10, 1.0, 0.6, 0.6), (11, 0.5, 0.2, 0.2), (11.5, 1.0, 0.6, 0.6)]))
    assert s["smile_rate_per_min"] == 1.0
    assert s["smile_time_share"] == pytest.approx(2.5 / 60, abs=1e-3)


def test_smiles_that_reach_the_eyes():
    s = summarize(make_raw(smiles=[(5, 1, SMILE, SMILE, 0.4), (15, 1, SMILE, SMILE, 0.4),
                                   (25, 1, SMILE, SMILE, 0.05), (35, 1, SMILE, SMILE, 0.05)]))
    assert s["eye_smile_share"] == 0.5


def test_answers_to_marked_moments():
    s = summarize(make_raw(smiles=[(11.0, 1, SMILE, SMILE), (31.5, 1, SMILE, SMILE),
                                   (55, 1, SMILE, SMILE)],
                           moments_ms=[10_000, 30_000, 50_000, 90_000]))
    # 90 s is after the last frame: not counted. 50 s: the smile at 55 s is too late.
    assert s["smile_response_share"] == pytest.approx(2 / 3, abs=1e-3)
    assert s["smile_response_latency_s"] == pytest.approx(1.25)
    assert summarize(make_raw())["smile_response_share"] is None


def test_blinks_of_known_length_and_a_long_closure_left_out():
    blinks = [(s, 0.1) for s in range(3, 60, 6)]  # 10 blinks of 3 frames at 30 Hz
    s = summarize(make_raw(blinks=blinks + [(1.0, 1.2)]))
    assert s["blink_rate_per_min"] == 10.0
    assert s["blink_duration_ms"] == pytest.approx(100.0)
    s = summarize(make_raw(rate=60, blinks=[(s, 0.2) for s in range(3, 60, 6)]))
    assert s["blink_rate_per_min"] == 10.0 and s["blink_duration_ms"] == pytest.approx(200.0)


def test_still_face_and_lively_face():
    still = summarize(make_raw())
    lively = summarize(make_raw(lively=True, head_lively=True))
    assert 0.05 <= still["facial_activity"] <= 0.15
    assert 0.45 <= lively["facial_activity"] <= 0.75
    assert still["head_movement"] <= 0.2 and 0.45 <= lively["head_movement"] <= 0.8
    # The frame rate does not change the answer much: same face at 60 Hz.
    still60 = summarize(make_raw(rate=60))
    assert abs(still60["facial_activity"] - still["facial_activity"]) < 0.1


def test_head_angles_and_shares():
    s = summarize(make_raw(look_down=[(0, 15)]))
    assert s["head_pitch_deg"] == pytest.approx(6.0, abs=0.1)
    assert s["head_tilt_deg"] == pytest.approx(3.0, abs=0.1)
    assert s["look_down_share"] == pytest.approx(0.25, abs=1e-3)
    assert s["brow_down_share"] == 0 and s["inner_brow_up_share"] == 0
    assert s["lip_down_share"] == 0 and s["lip_press_share"] == 0


def test_lip_corners_down_and_lips_pressed_shares():
    # Corners down for 15 of 60 s, lips pressed for the last 30 s; a resting mouth
    # (ARKit jitter around 0.05) never reaches the threshold.
    s = summarize(make_raw(lip_down=[(0, 15)], lip_press=[(30, 30)]))
    assert s["lip_down_share"] == pytest.approx(0.25, abs=1e-3)
    assert s["lip_press_share"] == pytest.approx(0.5, abs=1e-3)
    # One side alone at 0.5 gives a mean of about 0.27: under the 0.3 threshold.
    raw = make_raw()
    i = raw["channels"].index("mouthFrownLeft")
    for row in raw["samples"]:
        row[i] = 0.5
    assert summarize(raw)["lip_down_share"] == 0


def test_missing_optional_channels_give_null_for_what_needs_them():
    s = summarize(make_raw(channels=REQUIRED, smiles=[(10, 1, SMILE, SMILE)]))
    for k in ("look_down_share", "brow_down_share", "inner_brow_up_share", "eye_smile_share",
              "head_pitch_deg", "head_tilt_deg", "head_movement", "lip_down_share",
              "lip_press_share"):
        assert s[k] is None, k
    assert s["smile_rate_per_min"] == 1.0 and s["blink_rate_per_min"] == 0
    assert s["facial_activity"] is not None  # from the two smile channels


def test_untracked_stretches_are_left_out():
    # Second half untracked; a smile inside it does not count, one before does.
    s = summarize(make_raw(untracked=[(30, 30)], smiles=[(10, 1, SMILE, SMILE),
                                                         (40, 1, SMILE, SMILE)],
                           look_down=[(0, 15)], lip_press=[(45, 15)]))
    assert s["tracking_quality"] == 0.5
    assert s["smile_rate_per_min"] == 2.0  # one smile in 30 tracked seconds
    assert s["look_down_share"] == pytest.approx(0.5, abs=1e-3)  # 15 of 30 tracked seconds
    assert s["lip_press_share"] == 0  # pressed only while untracked


def test_a_blink_cut_by_lost_tracking_is_dropped_a_smile_is_kept():
    s = summarize(make_raw(untracked=[(20.5, 1)], blinks=[(20.45, 0.1), (5, 0.1)],
                           smiles=[(19.5, 1.0, SMILE, SMILE)]))
    assert s["blink_rate_per_min"] == pytest.approx(60 / 59, abs=0.01)  # one blink
    assert s["smile_rate_per_min"] == pytest.approx(60 / 59, abs=0.01)


def test_too_little_tracked_time_gives_only_tracking_quality():
    s = summarize(make_raw(seconds=60, untracked=[(4, 56)], smiles=[(1, 1, SMILE, SMILE)]))
    assert s["tracking_quality"] == pytest.approx(4 / 60, abs=1e-3)
    assert all(s[k] is None for k in SUMMARY_FIELDS)


def test_summary_fits_the_face_summary_model():
    from clinic_engine.models import FaceSummary
    for raw in (make_raw(), make_raw(lively=True, head_lively=True, smiles=[(3, 2, 1, 0)])):
        FaceSummary(**summarize(raw))


def test_describe_counts_only():
    raw = make_raw(seconds=10, untracked=[(0, 2)])
    assert describe(raw) == {"rate_hz": 30, "frames": 300, "tracked_share": 0.8, "channels": 55}


@pytest.mark.parametrize("change,needle", [
    (lambda r: r["channels"].__setitem__(5, "notAChannel"), "channels[5] is not"),
    (lambda r: r["channels"].__setitem__(5, r["channels"][4]), "repeats"),
    (lambda r: r["samples"][7].pop(), "samples[7] has"),
    (lambda r: r["samples"][3].__setitem__(0, math.nan), "not a finite number"),
    (lambda r: r["samples"][3].__setitem__(0, 1.2), "outside 0..1"),
    (lambda r: r["samples"][3].__setitem__(53, 200.0), "outside -180..180"),
    (lambda r: r.__setitem__("tracked", [1, 0]), "tracked has 2"),
])
def test_check_raw_refuses_with_a_clear_message(change, needle):
    raw = make_raw(seconds=2)
    change(raw)
    assert needle in check_raw(raw)


def test_check_raw_required_channels_and_small_overshoot():
    raw = make_raw(seconds=2, channels=["mouthSmileLeft", "eyeBlinkLeft", "eyeBlinkRight",
                                        "jawOpen"])
    assert "must include mouthSmileRight" in check_raw(raw)
    raw = make_raw(seconds=10)
    raw["samples"][0][0] = 1.01
    raw["samples"][1][0] = -0.01
    assert check_raw(raw) is None
    summarize(raw)  # clamped, no error
