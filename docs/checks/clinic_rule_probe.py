"""Throwaway check: does level 1 apply a clinic rule to the movement flag? Uses a memory store
(nothing live is touched, no alert is sent) and the real local model.
usage: python rule_probe.py <runs> [file with a replacement SYSTEM_TRIAGE] [rule text]"""
import asyncio, json, os, sys
os.environ.update(STORE="memory", NOTIFY_MODE="off", OUTREACH_MODE="off", TRIAGE_MODE="rules", DEMO_ENABLED="true")
from datetime import datetime, timezone, timedelta
from clinic_engine.app import create_app
from clinic_engine.config import Settings
from clinic_engine.store import MemoryStore
from clinic_engine.seed import create_demo, settle
from clinic_engine.mind.gates import INPUT_GATE, OUTPUT_GATE

runs = int(sys.argv[1]); prompt_file = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] != "-" else None
RULE = sys.argv[3] if len(sys.argv) > 3 else "Planned two-week rest after knee surgery. Less movement is expected and only needs watching."

async def main():
    settings = Settings.from_env(); store = MemoryStore()
    app = create_app(settings=settings, store=store, start_ticker=False); mind = app.state.ctx.mind
    now = datetime.now(timezone.utc)
    out = create_demo(store, settings, now, extra=3)
    c, pid = out["clinic_id"], out["extra_patient_ids"][1]
    await settle(mind, c, pid, review=False)
    repo = mind.repo(c, pid)
    if RULE != "none":
        repo.put("mind/clinic_rules.json", {"rules": [{"id": "crl_probe", "text": RULE, "at": now.isoformat(), "by": "probe", "active": True,
                                                        "expires_at": (now + timedelta(days=14)).isoformat()}]})
    _v, items, rules, payload, refs = mind._triage_inputs(repo, now)
    kinds = {it["ref"]: it["kind"] for it in payload["items"]}
    print("items:", [(it["ref"], it["kind"], it["rules_level"]) for it in payload["items"]], "| rules in payload:", payload.get("clinic_rules"))
    if prompt_file:
        type(INPUT_GATE).SYSTEM_TRIAGE = open(prompt_file).read().strip()
    ok = other = unread = 0
    for i in range(runs):
        pack = INPUT_GATE.triage_pack(payload, refs, 1)
        raw = await mind.local.complete(pack, json_mode=True, max_tokens=900)
        res = OUTPUT_GATE.triage(raw, pack)
        if not res.ok:
            unread += 1; print(i, "NOT READ:", getattr(res, "reason", None), getattr(res, "refusal", None), str(raw)[:420]); continue
        row = {kinds[r]: (v["level"], v["reason"], v.get("rule")) for r, v in res.value.items()}
        dev = row.get("deviation")
        ok += bool(dev and dev[2] and dev[0] == "watch")
        other += sum(1 for k, v in row.items() if k != "deviation" and v[2])
        print(i, row)
    print(f"RESULT rule applied to the movement flag as watch: {ok}/{runs}; named on other flags: {other}; not read: {unread}")
asyncio.run(main())
