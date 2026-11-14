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


def build_request(settings: Settings, pack: Pack,
                  max_output_tokens: int = 4000) -> tuple[str, dict, dict]:
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
    headers = {"x-goog-api-key": settings.gemini_api_key}
    return url, headers, body


def parse_response(data: dict) -> str | None:
    try:
        parts = data["candidates"][0]["content"]["parts"]
        return "".join(p.get("text", "") for p in parts) or None
    except (KeyError, IndexError, TypeError):
        return None
