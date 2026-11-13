"""Baseline, each watcher, escalation and status, as pure functions."""

from datetime import timedelta

from clinic_engine.mind.baseline import baseline_for, daily_series, has_baseline, robust_stats
from clinic_engine.mind.thresholds import T
from clinic_engine.mind.watchers import (View, check_day, compute_status, escalate, watch_deviation,
                                         watch_help, watch_ignored, watch_low_notes,
                                         watch_novelty, watch_oddity, watch_silence)

from conftest import NOW, TODAY, make_days


def view(days, items=None, suggestions=None, oddities=None, notes=None, contacts=None,
         rounds=None, now=NOW, today=TODAY):
    series = daily_series(days, T)
    return View(today=today, now=now, days=days, series=series,
                has_baseline=has_baseline(baseline_for(days, today)), items=items or [],
                suggestions=suggestions or [], oddities=oddities or [], notes=notes or [],
                contacts=contacts or [], rounds=rounds or [])


def item(kind, state="open", **kw):
    base = {"id": f"att_{kind}", "kind": kind, "state": state, "since": "2026-11-09",
            "opened_at": "2026-11-09T00:00:00+00:00", "level": "attention", "detail": {},
            "history": []}
    base.update(kw)
    return base


# ---- baseline -----------------------------------------------------------------------------

def test_robust_stats_ignore_one_outlier():
    med, scale = robust_stats([100, 101, 99, 100, 102, 98, 5000], "steps")
    assert med == 100
    assert scale == 400.0  # floor wins over the tiny MAD; the outlier does not inflate it


def test_baseline_needs_min_days_and_excludes_recent():
    days = make_days(n=10)
    assert baseline_for(days, TODAY) == {}
    days = make_days(n=28, shape={0: 0.1, -1: 0.1, -2: 0.1, -3: 0.1, -4: 0.1})
    base = baseline_for(days, TODAY)
    assert has_baseline(base)
    assert 6000 < base["steps"]["median"] < 8000  # the recent drop is not part of "normal"


def test_z_scores_are_against_own_normal():
    low = make_days(steps=3000, seed_=2)
    high = make_days(steps=12000, seed_=2)
    # Two very different people both look "within" against their own normal.
    assert compute_status(view(low)) == "within"
    assert compute_status(view(high)) == "within"


# ---- deviation -------------------------------------------------------------------------

def dip_days(n_low=4):
    return make_days(shape={-k: 0.4 for k in range(n_low)})


def test_deviation_opens_on_sustained_drop():
    ops = watch_deviation(view(dip_days(3)))
    assert [o.op for o in ops] == ["open"]
    assert ops[0].level == "attention"
    assert ops[0].detail["low_days"] >= 3


def test_single_low_day_does_not_open_deviation():
    assert watch_deviation(view(make_days(shape={0: 0.4}))) == []


def test_deviation_is_held_until_recovery():
    days = dip_days(4)
    it = item("deviation")
    ops = watch_deviation(view(days, items=[it]))
    assert all(o.op != "close" for o in ops)
    # Three recovered days after the drop close it.
    days = make_days(shape={-3: 0.4, -4: 0.4, -5: 0.4, 0: 1.1, -1: 1.1, -2: 1.1})
    ops = watch_deviation(view(days, items=[it]))
    assert [o.op for o in ops] == ["close"] and ops[0].reason == "recovered"


def test_acknowledged_deviation_needs_fresh_evidence():
    days = dip_days(5)
    acked = item("deviation", state="closed", close_reason="acknowledged",
                 closed_at="2026-11-13T08:00:00+00:00", acked_through=TODAY.isoformat())
    assert watch_deviation(view(days, items=[acked])) == []
    # The status still follows the data.
    assert compute_status(view(days, items=[acked])) == "outside"


# ---- novelty --------------------------------------------------------------------------

def test_novelty_in_either_direction():
    up = watch_novelty(view(make_days(shape={0: 3.0})))
    down = watch_novelty(view(make_days(shape={0: 0.05})))
    assert up and up[0].detail["direction"] == "up"
    assert down and down[0].detail["direction"] == "down"


# ---- silence ---------------------------------------------------------------------------

def test_silence_is_no_data_never_within():
    days = make_days(today=TODAY - timedelta(days=4))
    v = view(days)
    assert compute_status(v) == "no_data"
    ops = watch_silence(v)
    assert ops[0].op == "open" and ops[0].level == "attention"


def test_silence_with_other_contact_is_only_watch():
    days = make_days(today=TODAY - timedelta(days=4))
    ops = watch_silence(view(days, contacts=[TODAY.isoformat()]))
    assert ops[0].level == "watch"


def test_no_data_at_all_is_no_data():
    assert compute_status(view({})) == "no_data"


def test_silence_closes_when_data_arrives():
    ops = watch_silence(view(make_days(), items=[item("silence")]))
    assert ops[0].op == "close"


# ---- oddity ----------------------------------------------------------------------------

def test_check_day_rejects_impossible_values():
    ok = {"date": TODAY.isoformat(), "steps": 5000, "walking_speed_m_s": 1.2}
    assert check_day(ok, TODAY) is None
    assert check_day({**ok, "steps": -5}, TODAY) == "negative_steps"
    assert check_day({**ok, "steps": 900000}, TODAY) == "implausible_steps"
    assert check_day({**ok, "walking_speed_m_s": 40.0}, TODAY) == "implausible_walking_speed_m_s"
    assert check_day({**ok, "date": (TODAY + timedelta(days=5)).isoformat()}, TODAY) == "future_date"
    assert check_day({**ok, "hrv_ms": float("nan")}, TODAY) is not None


def test_oddity_watcher_holds_watch_item():
    odd = [{"at": NOW.isoformat(), "date": TODAY.isoformat(), "reason": "negative_steps"}]
    ops = watch_oddity(view(make_days(), oddities=odd))
    assert ops[0].op == "open" and ops[0].level == "watch"


# ---- ignored ---------------------------------------------------------------------------

def sug(i, status, action="ar_round", answer=None):
    return {"id": f"sug_{i}", "status": status, "date": f"2026-11-0{i}", "action": action,
            "created_at": f"2026-11-0{i}T09:00:00+00:00", "answer": answer}


def test_ignored_after_three_unanswered():
    s = [sug(1, "expired"), sug(2, "expired"), sug(3, "expired")]
    ops = watch_ignored(view(make_days(), suggestions=s))
    assert ops[0].op == "open"
    s2 = s + [sug(4, "answered", answer="not_today")]
    ops = watch_ignored(view(make_days(), suggestions=s2, items=[item("ignored")]))
    assert ops[0].op == "close"


# ---- notes ------------------------------------------------------------------------------

def test_help_note_opens_urgent_item():
    notes = [{"at": NOW.isoformat(), "crisis": True, "mood": "low"}]
    ops = watch_help(view(make_days(), notes=notes))
    assert ops[0].op == "open" and ops[0].level == "urgent"


def test_two_low_notes_open_watch():
    notes = [{"at": NOW.isoformat(), "crisis": False, "mood": "low"},
             {"at": (NOW - timedelta(days=1)).isoformat(), "crisis": False, "mood": "low"}]
    assert watch_low_notes(view(make_days(), notes=notes))[0].op == "open"


# ---- escalation ------------------------------------------------------------------------

def test_deviation_followed_by_silence_is_urgent():
    days = make_days(today=TODAY - timedelta(days=4), shape={-k: 0.4 for k in range(4)})
    items = [item("deviation"), item("silence")]
    levels = escalate(items, view(days, items=items))
    assert levels["att_deviation"] == "urgent"


def test_deep_drop_with_ignored_suggestions_is_urgent():
    days = make_days(shape={-k: 0.1 for k in range(5)})
    items = [item("deviation"), item("ignored", level="watch")]
    levels = escalate(items, view(days, items=items))
    assert levels["att_deviation"] == "urgent"
    assert levels["att_ignored"] == "attention"


def test_mild_deviation_alone_stays_attention():
    days = dip_days(3)
    items = [item("deviation", since=TODAY.isoformat())]
    assert escalate(items, view(days, items=items))["att_deviation"] == "attention"


def test_long_held_deviation_needs_review():
    items = [item("deviation", since=(TODAY - timedelta(days=11)).isoformat())]
    assert escalate(items, view(dip_days(3), items=items))["att_deviation"] == "urgent"
