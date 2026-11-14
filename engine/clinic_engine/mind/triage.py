"""How the answers of the two model levels become the level of each open
attention item (TRIAGE_MODE=models). Pure code; used by the engine and by the
check on generated pictures (clinic_engine/triage_check.py).

The rules, in order:

1. A request for help is urgent, whatever anyone answered.
2. A level that follows the clinic's own rule for this person is taken from
   level 1 as it is: level 2's verdict is recorded and not applied.
3. Otherwise level 1's level (or the fixed rules' level when level 1 did not
   answer) moves by level 2's verdict, one step at most.
4. Two floors for what the models decide by themselves:
   - a flag the fixed rules hold at "urgent" stays urgent;
   - no level ends more than one step below the fixed rules' level.
   Only the clinic's own rule can go under these floors, and the flag then
   shows the rule.
"""

from __future__ import annotations

LEVELS = ("watch", "attention", "urgent")
STEP = {"agree": 0, "raise": 1, "lower": -1}


def combine(refs: dict[str, str], rules: dict[str, str], kinds: dict[str, str],
            first: dict[str, dict], second: dict[str, dict],
            rule_ids: dict[str, str]) -> dict[str, dict]:
    """refs: {ref: item id}; rules: {item id: the fixed rules' level}; kinds:
    {item id: kind}; first / second: the checked answers by ref; rule_ids:
    {rule ref: clinic rule id}. Returns {item id: decision}; an item neither
    level answered for is left out (the fixed rules' level stands)."""
    out: dict[str, dict] = {}
    for ref, iid in refs.items():
        one, two = first.get(ref), second.get(ref)
        if one is None and two is None:
            continue
        rules_i = LEVELS.index(rules[iid])
        rule_id = rule_ids.get(one.get("rule")) if one else None
        idx = LEVELS.index(one["level"]) if one else rules_i
        if two and rule_id is None:
            idx += STEP[two["verdict"]]
        idx = max(0, min(len(LEVELS) - 1, idx))
        asked = idx
        fixed = kinds[iid] == "asked_for_help"
        if fixed:
            idx = LEVELS.index("urgent")
        elif rule_id is None:
            if rules[iid] == "urgent":
                idx = LEVELS.index("urgent")
            idx = max(idx, rules_i - 1)
        out[iid] = {
            "level": LEVELS[idx], "rules_level": rules[iid], "fixed_by_rule": fixed,
            "clinic_rule_id": rule_id,
            # The models asked for a lower level than a floor allows.
            "held_by_floor": (not fixed) and idx != asked,
            "level1": one["level"] if one else None, "reason1": one["reason"] if one else None,
            "verdict2": two["verdict"] if two else None,
            "reason2": two["reason"] if two else None}
    return out
