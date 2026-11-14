"""Sends the example Experiment C request through a running proxy to the real Gemini model and checks the reply
the way the iOS validator does (schema keys, observation fields, numbers present in the payload).

    set -a; . ../proxy/.env; set +a
    python3 run_live_example.py --proxy http://127.0.0.1:8787 --experiment combined

Writes gemini-responses/<experiment>_live_<timestamp>.json with the proxy reply (no key, no token).
The system instruction and user prompts are read from the Swift source so the two never drift apart.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT_PROMPTS = os.path.join(HERE, "..", "HKGeminiHarness", "Gemini", "GeminiPrompts.swift")

NUMBER_RE = re.compile(r"(?<![A-Za-z_])[-+]?\d+(?:[.,]\d+)?(?![A-Za-z_\d])")
FORBIDDEN = ["depress", "anxi", "happy", "happiness", "sad ", "sadness", "emotion", "diagnos", "disorder", "mood", "fatigue", "stress", "pain"]


def swift_multiline_string(source: str, name: str) -> str:
    m = re.search(rf"{name} = \"\"\"\n(.*?)\n\s*\"\"\"", source, re.S)
    if not m:
        raise SystemExit(f"could not find {name} in GeminiPrompts.swift")
    body = m.group(1)
    body = re.sub(r"\\\n\s*", "", body)          # Swift line continuations
    lines = body.split("\n")
    indent = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
    return "\n".join(l[indent:] for l in lines).strip()


def user_prompt_for(source: str, experiment: str) -> str:
    case = {"healthkit": "healthKitOnly", "arkit": "arKitOnly", "combined": "combined", "baseline": "baseline",
            "connection_test": "connectionTest", "geometry_features": "geometryFeatures"}[experiment]
    m = re.search(rf"case \.{case}:\n\s*return (\"\"\"\n(.*?)\n\s*\"\"\"|\"((?:[^\"\\]|\\.)*)\")", source, re.S)
    if not m:
        raise SystemExit(f"could not find the prompt for {experiment}")
    if m.group(2) is not None:
        lines = m.group(2).split("\n")
        indent = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
        return "\n".join(l[indent:] for l in lines).strip()
    return m.group(3).replace('\\"', '"').replace("\\\\", "\\")


def observation_schema() -> dict:
    return {
        "type": "object",
        "properties": {
            "observation": {"type": "string"},
            "supporting_measurements": {"type": "array", "items": {"type": "string"}},
            "time_range": {"type": "object", "properties": {"start": {"type": "string"}, "end": {"type": "string"}}},
            "kind": {"type": "string", "enum": ["direct_observation", "hypothesis"]},
            "data_quality": {"type": "string"},
            "limitations": {"type": "string"},
        },
        "required": ["observation", "supporting_measurements", "kind", "data_quality", "limitations"],
    }


def response_schema(experiment: str) -> dict:
    obs = {"type": "array", "items": observation_schema()}
    strings = {"type": "array", "items": {"type": "string"}}
    return {
        "type": "object",
        "properties": {
            "experiment_type": {"type": "string", "enum": [experiment]},
            "baseline_summary": {"type": "object", "additionalProperties": {"type": "string"}},
            "health_observations": obs, "facial_behavior_observations": obs, "cross_modal_patterns": obs,
            "longitudinal_changes": obs, "potential_confounders": obs,
            "data_quality": {"type": "object", "additionalProperties": {"type": "string"}},
            "uncertainties": strings, "recommended_tracking": strings,
            "plain_language_explanation": {"type": "string"},
        },
        "required": ["experiment_type", "baseline_summary", "health_observations", "facial_behavior_observations", "cross_modal_patterns",
                     "longitudinal_changes", "potential_confounders", "data_quality", "uncertainties", "recommended_tracking", "plain_language_explanation"],
    }


def all_numbers(node, out: list[float]) -> None:
    if isinstance(node, bool):
        return
    if isinstance(node, (int, float)):
        out.append(float(node))
    elif isinstance(node, str):
        out += [float(x.replace(",", ".")) for x in NUMBER_RE.findall(node)]
    elif isinstance(node, list):
        for v in node:
            all_numbers(v, out)
    elif isinstance(node, dict):
        for v in node.values():
            all_numbers(v, out)


def supported(n: float, allowed: list[float]) -> bool:
    x = abs(n)
    text = f"{x:.6f}".rstrip("0").rstrip(".")
    decimals = len(text.split(".")[1]) if "." in text else 0
    for cand in (x, x / 100, x * 100):
        for a in allowed:
            if abs(a - cand) <= max(abs(cand) * 0.005, 1e-9):
                return True
            if round(a, decimals) == round(cand, decimals):
                return True
    return False


def validate(text: str, experiment: str, payload) -> dict:
    report = {"schema_errors": [], "unsupported_numbers": [], "forbidden_terms": [], "observations": 0, "numbers_checked": 0}
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1].rsplit("```", 1)[0]
    try:
        a = json.loads(t)
    except json.JSONDecodeError as e:
        report["schema_errors"].append(f"not JSON: {e}")
        return report
    required = response_schema(experiment)["required"]
    for k in required:
        if k not in a:
            report["schema_errors"].append(f"missing key {k}")
    if a.get("experiment_type") != experiment:
        report["schema_errors"].append(f"experiment_type {a.get('experiment_type')!r} != {experiment!r}")
    allowed: list[float] = []
    all_numbers(payload, allowed)
    allowed = sorted(set(abs(v) for v in allowed))

    def check_text(s: str, loc: str) -> None:
        for m in NUMBER_RE.findall(s or ""):
            n = float(m.replace(",", "."))
            report["numbers_checked"] += 1
            if not supported(n, allowed):
                small = n == int(n) and abs(n) <= 31
                report["unsupported_numbers"].append({"severity": "warning" if small else "error", "location": loc, "number": n})

    for group in ("health_observations", "facial_behavior_observations", "cross_modal_patterns", "longitudinal_changes", "potential_confounders"):
        for i, o in enumerate(a.get(group, []) or []):
            report["observations"] += 1
            loc = f"{group}[{i}]"
            if o.get("kind") not in ("direct_observation", "hypothesis"):
                report["schema_errors"].append(f"{loc}.kind = {o.get('kind')!r}")
            if o.get("kind") == "direct_observation" and not o.get("supporting_measurements"):
                report["schema_errors"].append(f"{loc}: direct observation without supporting measurements")
            for key in ("observation", "limitations", "data_quality"):
                check_text(o.get(key, ""), f"{loc}.{key}")
            for j, s in enumerate(o.get("supporting_measurements", []) or []):
                check_text(s, f"{loc}.supporting_measurements[{j}]")
            low = (o.get("observation", "") + " " + o.get("limitations", "")).lower()
            for term in FORBIDDEN:
                if term in low and not any(p in low for p in (f"not a {term}", f"no {term}", f"not {term}", "cannot")):
                    report["forbidden_terms"].append({"location": loc, "term": term.strip()})
    check_text(a.get("plain_language_explanation", ""), "plain_language_explanation")
    check_text(json.dumps(a.get("baseline_summary", {})), "baseline_summary")
    check_text(json.dumps(a.get("data_quality", {})), "data_quality")
    for i, u in enumerate(a.get("uncertainties", []) or []):
        check_text(u, f"uncertainties[{i}]")
    hard = len(report["schema_errors"]) + sum(1 for u in report["unsupported_numbers"] if u["severity"] == "error")
    report["is_valid"] = hard == 0
    return report


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default="http://127.0.0.1:8787")
    ap.add_argument("--experiment", default="combined", choices=["combined", "connection_test"])
    ap.add_argument("--request", default=os.path.join(HERE, "gemini-requests", "experiment_c_combined_request.json"))
    ap.add_argument("--thinking", default=None)
    a = ap.parse_args()
    token = os.environ.get("PROXY_TOKEN", "")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    source = open(SWIFT_PROMPTS, encoding="utf-8").read()
    system = swift_multiline_string(source, "public static let systemInstruction")
    prompt = user_prompt_for(source, a.experiment)

    if a.experiment == "connection_test":
        body = {"request_id": "live-test", "experiment": "connection_test", "user_prompt": prompt}
        path = "/v1/test"
        payload = {"ping": "ok"}
    else:
        example = json.load(open(a.request, encoding="utf-8"))
        payload = example["payload"]
        body = {"request_id": f"live-{int(time.time())}", "experiment": a.experiment, "model": example.get("model", "gemini-4-carbon"),
                "thinking_level": a.thinking or example.get("thinking_level", "medium"), "system_instruction": system, "user_prompt": prompt,
                "payload": payload, "response_schema": response_schema(a.experiment)}
        path = "/v1/analyze"

    print(f"POST {a.proxy}{path}  model={body.get('model', '(proxy default)')}  payload_bytes={len(json.dumps(payload))}")
    t0 = time.monotonic()
    req = urllib.request.Request(a.proxy + path, data=json.dumps(body).encode(), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=1200) as r:
            status, reply = r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        status, reply = e.code, json.loads(e.read() or b"{}")
    wall = (time.monotonic() - t0) * 1000
    print(f"HTTP {status}  status={reply.get('status')}  model={reply.get('model')}  upstream={reply.get('upstream_status')}  "
          f"latency_ms={reply.get('latency_ms')} (wall {wall:.0f})  usage={reply.get('usage')}  finish={reply.get('finish_reason')}")
    if reply.get("error"):
        print("error:", reply["error"])
    out = {"sent_at": datetime.now(timezone.utc).isoformat(), "experiment": a.experiment, "request_id": body["request_id"],
           "thinking_level": body.get("thinking_level"), "proxy_reply": reply}
    if reply.get("text") and a.experiment == "connection_test":
        try:
            parsed = json.loads(reply["text"])
        except json.JSONDecodeError:
            parsed = None
        out["parsed"] = parsed
        ok = isinstance(parsed, dict) and parsed.get("experiment_type") == "connection_test" and parsed.get("plain_language_explanation") == "ok"
        out["validation"] = {"is_valid": ok, "note": "connection test: only experiment_type and plain_language_explanation are checked"}
        print(f"validation: valid={ok} parsed={parsed}")
    elif reply.get("text"):
        report = validate(reply["text"], a.experiment, payload)
        out["validation"] = report
        try:
            out["parsed"] = json.loads(reply["text"])
        except json.JSONDecodeError:
            out["parsed"] = None
        print(f"validation: valid={report['is_valid']} observations={report['observations']} numbers_checked={report['numbers_checked']} "
              f"schema_errors={len(report['schema_errors'])} unsupported={len(report['unsupported_numbers'])} forbidden={len(report['forbidden_terms'])}")
        for e in report["schema_errors"][:10]:
            print("  schema:", e)
        for u in report["unsupported_numbers"][:15]:
            print("  number:", u)
        for f in report["forbidden_terms"][:10]:
            print("  term:", f)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    dest = os.path.join(HERE, "gemini-responses", f"{a.experiment}_live_{stamp}.json")
    with open(dest, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(out, fh, indent=2, ensure_ascii=False)
    print("saved", os.path.relpath(dest, HERE))
    return 0 if reply.get("status") == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
