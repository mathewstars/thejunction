"""Gemini proxy for the HealthKit + ARKit test harness.

Standard library only (no pip installs). Runs on any machine with Python 3.10+.

Why it exists
    The iOS app must never hold the Gemini API key. The app sends a prompt and a numeric payload to
    this proxy with a shared bearer token; the proxy adds the API key, calls Gemini, and returns the
    model text plus token usage and latency. Nothing is stored. Payloads are not logged unless
    LOG_PAYLOADS=1 is set for debugging.

Endpoints
    GET  /v1/health   -> {"ok": true, "model": "...", "api_key_configured": true, ...}
    POST /v1/test     -> same shape as /v1/analyze, tiny prompt, proves key + model + network
    POST /v1/analyze  -> body: {request_id, experiment, model?, thinking_level?, system_instruction,
                                user_prompt, payload, response_schema}
                         reply: {request_id, status: "success"|"api_error"|"bad_request", model, text,
                                 usage: {prompt_tokens, output_tokens, thought_tokens, total_tokens},
                                 latency_ms, upstream_status, finish_reason, error}

Configuration (environment, see .env.example)
    GEMINI_API_KEY        required
    GEMINI_MODEL          default model id (gemini-4-carbon)
    GEMINI_ALLOWED_MODELS comma list the app may choose from; anything else -> 400
    GEMINI_API_STYLE      generate_content (default) | interactions
    GEMINI_THINKING_LEVEL default thinking level: low | medium | high
    GEMINI_MAX_OUTPUT_TOKENS default 16384
    GEMINI_TIMEOUT_S      default 900 (Carbon can think for minutes)
    PROXY_TOKEN           bearer token the app must present; required unless PROXY_ALLOW_ANONYMOUS=1
    PROXY_HOST / PROXY_PORT  default 127.0.0.1:8787 (put TLS in front; see README)
    MAX_BODY_BYTES        default 4 MiB
    LOG_PAYLOADS          0 (default) | 1

Run
    set -a; . ./.env; set +a; python3 gemini_proxy.py
"""

from __future__ import annotations

import json
import logging
import os
import re
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib import error as urlerror
from urllib import request as urlrequest

VERSION = "0.1.0"
GEMINI_HOST = "generativelanguage.googleapis.com"
log = logging.getLogger("gemini_proxy")


# --------------------------------------------------------------------------------------- settings

class Settings:
    def __init__(self, env: dict[str, str] | None = None) -> None:
        e = env if env is not None else os.environ
        self.api_key = e.get("GEMINI_API_KEY", "")
        self.model = e.get("GEMINI_MODEL", "gemini-4-carbon")
        allowed = e.get("GEMINI_ALLOWED_MODELS", "gemini-4-carbon,gemini-4-argon,gemini-4-hydrogen,gemini-3.8-flash")
        self.allowed_models = {m.strip() for m in allowed.split(",") if m.strip()} | {self.model}
        self.api_style = e.get("GEMINI_API_STYLE", "generate_content")
        self.thinking_level = e.get("GEMINI_THINKING_LEVEL", "medium")
        self.max_output_tokens = int(e.get("GEMINI_MAX_OUTPUT_TOKENS", "16384"))
        self.timeout_s = float(e.get("GEMINI_TIMEOUT_S", "900"))
        self.token = e.get("PROXY_TOKEN", "")
        self.allow_anonymous = e.get("PROXY_ALLOW_ANONYMOUS", "0") == "1"
        self.host = e.get("PROXY_HOST", "127.0.0.1")
        self.port = int(e.get("PROXY_PORT", "8787"))
        self.max_body = int(e.get("MAX_BODY_BYTES", str(4 * 1024 * 1024)))
        self.log_payloads = e.get("LOG_PAYLOADS", "0") == "1"

    def check(self) -> list[str]:
        problems = []
        if not self.api_key:
            problems.append("GEMINI_API_KEY is not set")
        if not self.token and not self.allow_anonymous:
            problems.append("PROXY_TOKEN is not set (or set PROXY_ALLOW_ANONYMOUS=1 for localhost-only testing)")
        if self.api_style not in ("generate_content", "interactions"):
            problems.append("GEMINI_API_STYLE must be generate_content or interactions")
        if self.thinking_level not in ("low", "medium", "high"):
            problems.append("GEMINI_THINKING_LEVEL must be low, medium or high")
        return problems


# ------------------------------------------------------------------------------- request checks

class BadRequest(Exception):
    pass


_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_PHONE = re.compile(r"(?<![\w-])(?:\+\d{1,3}[\s-]?)?(?:\(?\d{2,4}\)?[\s-]){2,}\d{2,4}(?![\w-])")  # +358 40 123 4567, (09) 123 4567; not 20261114-060000-x
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?Z?)?")  # ISO dates are not phone numbers
_IDENTIFYING_KEYS = {"participantlabel", "participant_label", "name", "email", "phone", "address", "notes",
                     "sourcebundleidentifier", "source_bundle_identifier", "devicename", "device_name", "uuid"}


def scan_identifiers(payload: Any) -> list[str]:
    """Best-effort guard against personal identifiers in the numeric payload. Returns findings."""
    findings: list[str] = []

    def walk(node: Any, path: str) -> None:
        if len(findings) > 20:
            return
        if isinstance(node, dict):
            for k, v in node.items():
                if str(k).lower() in _IDENTIFYING_KEYS and v not in (None, "", [], {}):
                    findings.append(f"{path}.{k}: identifying key")
                walk(v, f"{path}.{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node[:5000]):
                walk(v, f"{path}[{i}]")
        elif isinstance(node, str):
            if _EMAIL.search(node):
                findings.append(f"{path}: looks like an email address")
            elif len(node) >= 9 and _PHONE.search(_DATE.sub(" ", node)):
                findings.append(f"{path}: looks like a phone number")

    walk(payload, "$")
    return findings


def validate_request(body: dict, settings: Settings, require_payload: bool) -> dict:
    if not isinstance(body, dict):
        raise BadRequest("body must be a JSON object")
    out = {
        "request_id": str(body.get("request_id") or uuid.uuid4()),
        "experiment": str(body.get("experiment") or "unspecified"),
        "model": str(body.get("model") or settings.model),
        "thinking_level": str(body.get("thinking_level") or settings.thinking_level).lower(),
        "system_instruction": body.get("system_instruction") or "",
        "user_prompt": body.get("user_prompt") or "",
        "payload": body.get("payload"),
        "response_schema": body.get("response_schema"),
    }
    if out["model"] not in settings.allowed_models:
        raise BadRequest(f"model '{out['model']}' is not in GEMINI_ALLOWED_MODELS")
    if out["thinking_level"] not in ("low", "medium", "high"):
        raise BadRequest("thinking_level must be low, medium or high")
    if not isinstance(out["system_instruction"], str) or not isinstance(out["user_prompt"], str):
        raise BadRequest("system_instruction and user_prompt must be strings")
    if require_payload and out["payload"] is None:
        raise BadRequest("payload is required")
    if out["response_schema"] is not None and not isinstance(out["response_schema"], dict):
        raise BadRequest("response_schema must be a JSON object")
    found = scan_identifiers(out["payload"]) if out["payload"] is not None else []
    if found:
        raise BadRequest("payload contains possible personal identifiers: " + "; ".join(found[:5]))
    return out


# ---------------------------------------------------------------------------- Gemini request

def build_generate_content(req: dict, settings: Settings) -> tuple[str, dict]:
    url = f"https://{GEMINI_HOST}/v1beta/models/{req['model']}:generateContent"
    text = req["user_prompt"]
    if req["payload"] is not None:
        text += "\n\nINPUT DATA (JSON):\n" + json.dumps(req["payload"], separators=(",", ":"), ensure_ascii=False)
    gen: dict[str, Any] = {
        "responseMimeType": "application/json",
        "maxOutputTokens": settings.max_output_tokens,
        "thinkingConfig": {"thinkingLevel": req["thinking_level"]},
    }
    if req["response_schema"]:
        gen["responseJsonSchema"] = req["response_schema"]
    body: dict[str, Any] = {
        "contents": [{"role": "user", "parts": [{"text": text}]}],
        "generationConfig": gen,
    }
    if req["system_instruction"]:
        body["systemInstruction"] = {"parts": [{"text": req["system_instruction"]}]}
    return url, body


def build_interactions(req: dict, settings: Settings) -> tuple[str, dict]:
    """Interactions API shape (Gemini 4 developer guide). Field names follow the public guide; treat as
    the alternative path and verify against a live call before relying on it."""
    url = f"https://{GEMINI_HOST}/v1beta/interactions"
    text = req["user_prompt"]
    if req["payload"] is not None:
        text += "\n\nINPUT DATA (JSON):\n" + json.dumps(req["payload"], separators=(",", ":"), ensure_ascii=False)
    body: dict[str, Any] = {
        "model": req["model"],
        "input": [{"role": "user", "content": [{"type": "text", "text": text}]}],
        "generation_config": {"thinking_level": req["thinking_level"], "max_output_tokens": settings.max_output_tokens},
    }
    if req["system_instruction"]:
        body["system_instruction"] = req["system_instruction"]
    if req["response_schema"]:
        body["response_format"] = {"type": "json_schema", "mime_type": "application/json", "schema": req["response_schema"]}
    return url, body


def parse_generate_content(data: dict) -> tuple[str | None, dict, str | None]:
    text_parts: list[str] = []
    finish = None
    try:
        cand = data["candidates"][0]
        finish = cand.get("finishReason")
        for p in cand.get("content", {}).get("parts", []):
            if p.get("thought"):
                continue  # thought summaries are not the answer
            if "text" in p:
                text_parts.append(p["text"])
    except (KeyError, IndexError, TypeError):
        pass
    u = data.get("usageMetadata", {}) or {}
    usage = {
        "prompt_tokens": u.get("promptTokenCount"),
        "output_tokens": u.get("candidatesTokenCount"),
        "thought_tokens": u.get("thoughtsTokenCount"),
        "total_tokens": u.get("totalTokenCount"),
    }
    return ("".join(text_parts) or None), usage, finish


def parse_interactions(data: dict) -> tuple[str | None, dict, str | None]:
    text_parts: list[str] = []
    for step in data.get("output", []) or []:
        if isinstance(step, dict) and step.get("type") in ("text", "message", "model_output"):
            if "text" in step:
                text_parts.append(step["text"])
            for c in step.get("content", []) or []:
                if isinstance(c, dict) and c.get("type") == "text" and "text" in c:
                    text_parts.append(c["text"])
    if not text_parts and isinstance(data.get("output_text"), str):
        text_parts.append(data["output_text"])
    u = data.get("usage", {}) or {}
    usage = {
        "prompt_tokens": u.get("total_input_tokens"),
        "output_tokens": u.get("total_output_tokens"),
        "thought_tokens": u.get("total_thought_tokens"),
        "total_tokens": u.get("total_tokens"),
    }
    return ("".join(text_parts) or None), usage, data.get("status")


def send_upstream(url: str, body: dict, settings: Settings) -> tuple[int, dict]:
    """POST to Gemini. Separated so tests can replace it. Returns (http status, parsed JSON)."""
    if not url.startswith(f"https://{GEMINI_HOST}/"):
        raise RuntimeError("refusing to call a host other than " + GEMINI_HOST)
    data = json.dumps(body).encode("utf-8")
    r = urlrequest.Request(url, data=data, method="POST", headers={
        "Content-Type": "application/json",
        "x-goog-api-key": settings.api_key,
        "User-Agent": f"hkgemini-proxy/{VERSION}",
    })
    try:
        with urlrequest.urlopen(r, timeout=settings.timeout_s) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "{}")
    except urlerror.HTTPError as e:
        try:
            payload = json.loads(e.read().decode("utf-8") or "{}")
        except Exception:  # noqa: BLE001
            payload = {}
        return e.code, payload


def run_analysis(req: dict, settings: Settings) -> tuple[int, dict]:
    """Returns (http status for the app, reply dict)."""
    t0 = time.monotonic()
    if settings.api_style == "interactions":
        url, body = build_interactions(req, settings)
    else:
        url, body = build_generate_content(req, settings)
    reply: dict[str, Any] = {"request_id": req["request_id"], "model": req["model"], "status": "api_error",
                             "text": None, "usage": None, "latency_ms": None, "upstream_status": None,
                             "finish_reason": None, "error": None}
    try:
        status, data = send_upstream(url, body, settings)
    except Exception as exc:  # noqa: BLE001  (timeouts, DNS, TLS)
        reply["error"] = f"upstream unreachable: {type(exc).__name__}"
        reply["latency_ms"] = round((time.monotonic() - t0) * 1000, 1)
        return 502, reply
    reply["upstream_status"] = status
    reply["latency_ms"] = round((time.monotonic() - t0) * 1000, 1)
    if status >= 400:
        msg = None
        if isinstance(data, dict):
            msg = (data.get("error") or {}).get("message") if isinstance(data.get("error"), dict) else None
        reply["error"] = msg or f"Gemini returned HTTP {status}"
        return 502, reply
    text, usage, finish = parse_interactions(data) if settings.api_style == "interactions" else parse_generate_content(data)
    reply["usage"] = usage
    reply["finish_reason"] = finish
    if text is None:
        reply["error"] = "Gemini returned no text (blocked, empty, or unexpected shape)"
        return 502, reply
    reply["status"] = "success"
    reply["text"] = text
    return 200, reply


# ------------------------------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = f"hkgemini-proxy/{VERSION}"
    settings: Settings  # set on the server class

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter default access log
        log.debug(fmt, *args)

    def _send(self, status: int, obj: dict) -> None:
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def _authorised(self) -> bool:
        s = self.settings
        if s.allow_anonymous and not s.token:
            return True
        auth = self.headers.get("Authorization", "")
        return auth.startswith("Bearer ") and _consteq(auth[7:].strip(), s.token)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.rstrip("/") == "/v1/health":
            s = self.settings
            self._send(200, {"ok": not s.check(), "version": VERSION, "model": s.model, "api_style": s.api_style,
                             "api_key_configured": bool(s.api_key), "auth_required": bool(s.token),
                             "allowed_models": sorted(s.allowed_models), "problems": s.check()})
            return
        self._send(404, {"status": "not_found", "error": "unknown path"})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.rstrip("/")
        if path not in ("/v1/analyze", "/v1/test"):
            self._send(404, {"status": "not_found", "error": "unknown path"})
            return
        if not self._authorised():
            self._send(401, {"status": "unauthorized", "error": "missing or wrong bearer token"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > self.settings.max_body:
            self._send(413 if length > self.settings.max_body else 400, {"status": "bad_request", "error": f"body must be 1..{self.settings.max_body} bytes"})
            return
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send(400, {"status": "bad_request", "error": "body is not valid JSON"})
            return
        problems = self.settings.check()
        if problems:
            self._send(503, {"status": "proxy_misconfigured", "error": "; ".join(problems)})
            return
        try:
            req = validate_request(body, self.settings, require_payload=(path == "/v1/analyze"))
        except BadRequest as exc:
            self._send(400, {"status": "bad_request", "error": str(exc)})
            return
        if path == "/v1/test":
            req["payload"] = {"ping": "ok"}
            if not req["user_prompt"]:
                req["user_prompt"] = ("Connection test. Reply with a JSON object {\"experiment_type\":\"connection_test\","
                                      "\"plain_language_explanation\":\"ok\"} and nothing else.")
        if self.settings.log_payloads:
            log.info("payload %s: %s", req["request_id"], json.dumps(req["payload"])[:4000])
        status, reply = run_analysis(req, self.settings)
        u = reply.get("usage") or {}
        log.info("%s %s model=%s status=%s upstream=%s latency_ms=%s in=%s think=%s out=%s",
                 req["request_id"], req["experiment"], reply.get("model"), reply.get("status"), reply.get("upstream_status"),
                 reply.get("latency_ms"), u.get("prompt_tokens"), u.get("thought_tokens"), u.get("output_tokens"))
        self._send(status, reply)


def _consteq(a: str, b: str) -> bool:
    import hmac
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def make_server(settings: Settings) -> ThreadingHTTPServer:
    handler = type("BoundHandler", (Handler,), {"settings": settings})
    srv = ThreadingHTTPServer((settings.host, settings.port), handler)
    srv.daemon_threads = True
    return srv


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    settings = Settings()
    for p in settings.check():
        log.warning("config: %s", p)
    srv = make_server(settings)
    log.info("gemini proxy %s listening on http://%s:%d (model %s, style %s, auth %s)", VERSION, settings.host, srv.server_address[1],
             settings.model, settings.api_style, "on" if settings.token else "OFF")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
