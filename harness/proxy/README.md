# Gemini proxy

A small HTTP service that holds the Gemini API key so the iOS app never does. Python 3.10+, standard library only, one file: `gemini_proxy.py`.

## Run locally

```sh
cd harness/proxy
cp .env.example .env            # fill in GEMINI_API_KEY and PROXY_TOKEN
set -a; . ./.env; set +a
python3 gemini_proxy.py         # listens on 127.0.0.1:8787
```

Check it:

```sh
curl -s http://127.0.0.1:8787/v1/health
curl -s -X POST http://127.0.0.1:8787/v1/test -H "Authorization: Bearer $PROXY_TOKEN" \
     -H 'Content-Type: application/json' -d '{"experiment":"connection_test"}'
```

For the phone to reach it during development, set `PROXY_HOST=0.0.0.0` and enter `http://<your-mac-ip>:8787` in the app's Settings. The app allows plain `http` only for local addresses (localhost, 10.x, 192.168.x). Anything else must be `https`.

## Deploy next to the engine

The engine already runs behind an HTTPS proxy on the demo server (`deploy/apache-vhost.conf`). Run this service on another local port and add a `ProxyPass /gemini-proxy/ http://127.0.0.1:8787/` block, or mount it as a `systemd` unit copied from `deploy/clinic-engine.service`. Then the app's proxy URL is `https://lanvi.app/gemini-proxy`.

## API

| Call | Body | Reply |
|---|---|---|
| `GET /v1/health` | none | `{ok, version, model, api_style, api_key_configured, auth_required, allowed_models, problems}` |
| `POST /v1/test` | `{request_id?, experiment?, model?}` | same shape as analyze; a tiny prompt proves key, model and network |
| `POST /v1/analyze` | `{request_id, experiment, model?, thinking_level?, system_instruction, user_prompt, payload, response_schema?}` | `{request_id, status, model, text, usage{prompt_tokens, output_tokens, thought_tokens, total_tokens}, latency_ms, upstream_status, finish_reason, error}` |

`status` is `success`, `api_error` (Gemini said no; `upstream_status` and `error` carry the reason), `bad_request`, `unauthorized`, `proxy_misconfigured` or `not_found`. HTTP codes follow: 200, 502, 400, 401, 503, 404.

Both POST calls need `Authorization: Bearer <PROXY_TOKEN>`.

## What it refuses

- Models not in `GEMINI_ALLOWED_MODELS` (default `gemini-4-carbon,gemini-4-argon,gemini-4-hydrogen,gemini-3.8-flash`).
- `thinking_level` outside low/medium/high.
- Bodies over `MAX_BODY_BYTES` (4 MiB).
- Payloads that look like they carry identifiers: email addresses, phone numbers, or keys named `participantLabel`, `name`, `notes`, `deviceName`, `uuid`, … The app's payload builder never emits these; the proxy is the second line.
- Any upstream host other than `generativelanguage.googleapis.com`.

## How Gemini is called

Default `GEMINI_API_STYLE=generate_content`:

```
POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
x-goog-api-key: …
{
  "systemInstruction": {"parts": [{"text": "<system_instruction>"}]},
  "contents": [{"role": "user", "parts": [{"text": "<user_prompt>\n\nINPUT DATA (JSON):\n<payload>"}]}],
  "generationConfig": {
    "responseMimeType": "application/json",
    "responseJsonSchema": <response_schema>,
    "maxOutputTokens": 16384,
    "thinkingConfig": {"thinkingLevel": "medium"}
  }
}
```

No `temperature`/`topP`: Gemini 4 Carbon ignores sampling parameters. Thought parts (`"thought": true`) are dropped from the returned text; thought tokens are reported in `usage.thought_tokens` and are billed at the output rate.

`GEMINI_API_STYLE=interactions` switches to `POST /v1beta/interactions` with `generation_config.thinking_level` and `response_format`. This path follows the public Gemini 4 developer guide but has not been exercised against a live key here; try `/v1/test` first.

## Model check (14 Nov 2026)

`gemini-4-carbon` is listed on https://aistudio.google.com/docs/models together with `gemini-4-argon` and `gemini-4-hydrogen`. It is paid-tier only; the free tier does not serve it. Introductory pricing (to 30 Nov 2026) is $2 / $10 per million input / output tokens, doubling from 1 Dec. Google's Vertex documentation still lists `generateContent` for it. Long replies (over 32k tokens, non-streaming) need `v1beta`, which is what the proxy uses.

## Tests

```sh
python3 -m unittest discover -s harness/proxy/tests -v
```

16 tests, no network: the upstream call is replaced with a fake.

## Logging

One line per request: id, experiment, model, status, upstream status, latency, token counts. The payload is never logged unless `LOG_PAYLOADS=1`.
