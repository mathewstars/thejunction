"""Level 2: Google Gemini API request building and reply parsing.

This module does not send anything. The HTTP call is made by outreach.py,
the only module allowed to reach hosts outside the private network.
The model id comes from GEMINI_MODEL; there is no built-in default.
"""

from __future__ import annotations

import base64

from ..config import Settings
from ..mind.gates import Pack

GEMINI_HOST = "generativelanguage.googleapis.com"


def build_request(settings: Settings, pack: Pack, max_output_tokens: int = 4000,
                  response_schema: dict | None = None) -> tuple[str, dict, dict]:
    if not settings.gemini_model:
        raise RuntimeError("GEMINI_MODEL is not set")
    url = f"https://{GEMINI_HOST}/v1beta/models/{settings.gemini_model}:generateContent"
    system = "\n".join(m["content"] for m in pack.messages if m["role"] == "system")
    user = "\n".join(m["content"] for m in pack.messages if m["role"] == "user")
    parts: list[dict] = [{"text": user}]
    for png in pack.images:  # optional trail pictures (movement reading)
        parts.append({"inline_data": {"mime_type": "image/png",
                                      "data": base64.b64encode(png).decode("ascii")}})
    body = {
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {"temperature": 0, "responseMimeType": "application/json",
                             # the model thinks before it answers and that counts here
                             "maxOutputTokens": max_output_tokens},
    }
    if response_schema is not None:
        # Structured output: the model is held to the reply's shape. The output
        # gate checks the shape again, whatever the model returns.
        body["generationConfig"]["responseSchema"] = response_schema
    headers = {"x-goog-api-key": settings.gemini_api_key}
    return url, headers, body


def reply_meta(data: dict) -> dict:
    """Why the model stopped and how many tokens it used: codes and counts only."""
    out: dict = {}
    try:
        out["finish"] = str(data["candidates"][0].get("finishReason") or "")[:30] or None
    except (KeyError, IndexError, TypeError, AttributeError):
        out["finish"] = None
    usage = data.get("usageMetadata") if isinstance(data, dict) else None
    for key, name in (("promptTokenCount", "prompt_tokens"), ("thoughtsTokenCount", "thought_tokens"),
                      ("candidatesTokenCount", "output_tokens")):
        v = usage.get(key) if isinstance(usage, dict) else None
        out[name] = v if isinstance(v, int) and not isinstance(v, bool) else None
    return out


def parse_response(data: dict) -> str | None:
    try:
        parts = data["candidates"][0]["content"]["parts"]
        return "".join(p.get("text", "") for p in parts) or None
    except (KeyError, IndexError, TypeError):
        return None


# Gemini's own safety filter, set to its strictest, on top of the code checks.
_STRICT = [{"category": c, "threshold": "BLOCK_LOW_AND_ABOVE"} for c in (
    "HARM_CATEGORY_HARASSMENT", "HARM_CATEGORY_HATE_SPEECH",
    "HARM_CATEGORY_SEXUALLY_EXPLICIT", "HARM_CATEGORY_DANGEROUS_CONTENT")]


def chat_model(settings: Settings) -> str:
    return settings.chat_model or settings.gemini_model


def build_chat_request(settings: Settings, pack: Pack) -> tuple[str, dict, dict]:
    """Lanvi's reply to a note (CHAT_MODE=gemini): plain text, a few turns."""
    model = chat_model(settings)
    if not model:
        raise RuntimeError("no Gemini model id for the chat")
    url = f"https://{GEMINI_HOST}/v1beta/models/{model}:generateContent"
    system = "\n".join(m["content"] for m in pack.messages if m["role"] == "system")
    contents = [{"role": "user" if m["role"] == "user" else "model",
                 "parts": [{"text": m["content"]}]}
                for m in pack.messages if m["role"] in ("user", "assistant")]
    body = {
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": contents,
        "safetySettings": _STRICT,
        "generationConfig": {"temperature": 0.7, "responseMimeType": "text/plain",
                             # a thinking model counts its thinking here too
                             "maxOutputTokens": 1024},
    }
    if settings.chat_thinking:  # CHAT_THINKING, e.g. "low": a quicker answer
        body["generationConfig"]["thinkingConfig"] = {"thinkingLevel": settings.chat_thinking}
    headers = {"x-goog-api-key": settings.gemini_api_key}
    return url, headers, body
