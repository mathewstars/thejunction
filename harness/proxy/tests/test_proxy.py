"""Tests for gemini_proxy.py. Standard library only: python3 -m unittest discover -s harness/proxy/tests

The upstream call is replaced with a fake, so no network and no API key are needed.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import gemini_proxy as gp  # noqa: E402

ENV = {
    "GEMINI_API_KEY": "test-key-not-real",
    "GEMINI_MODEL": "gemini-4-carbon",
    "PROXY_TOKEN": "secret-token",
    "PROXY_HOST": "127.0.0.1",
    "PROXY_PORT": "0",
    "MAX_BODY_BYTES": "20000",
}

FAKE_OK = {
    "candidates": [{"content": {"parts": [{"thought": True, "text": "thinking..."}, {"text": "{\"experiment_type\":\"healthkit\"}"}]},
                    "finishReason": "STOP"}],
    "usageMetadata": {"promptTokenCount": 1200, "candidatesTokenCount": 300, "thoughtsTokenCount": 2500, "totalTokenCount": 4000},
}


class ProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.settings = gp.Settings(ENV)
        cls.server = gp.make_server(cls.settings)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.calls: list[tuple[str, dict]] = []
        cls.fake_status = 200
        cls.fake_data = FAKE_OK

        def fake_send(url: str, body: dict, settings: gp.Settings) -> tuple[int, dict]:
            cls.calls.append((url, body))
            return cls.fake_status, cls.fake_data

        cls._orig_send = staticmethod(gp.send_upstream)
        gp.send_upstream = fake_send

    @classmethod
    def tearDownClass(cls) -> None:
        gp.send_upstream = cls._orig_send.__func__ if hasattr(cls._orig_send, "__func__") else cls._orig_send
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self) -> None:
        type(self).calls.clear()
        type(self).fake_status = 200
        type(self).fake_data = FAKE_OK

    def call(self, method: str, path: str, body: dict | None = None, token: str | None = "secret-token", raw: bytes | None = None):
        url = f"http://127.0.0.1:{self.port}{path}"
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def analyze_body(self, **over):
        b = {"request_id": "r-1", "experiment": "healthkit", "model": "gemini-4-carbon", "thinking_level": "medium",
             "system_instruction": "rules", "user_prompt": "do it",
             "payload": {"metrics": [{"metric": "HRV", "median": 42.3}]},
             "response_schema": {"type": "object", "properties": {"experiment_type": {"type": "string"}}}}
        b.update(over)
        return b

    # ---- health and auth

    def test_health_reports_configuration_without_secrets(self):
        status, j = self.call("GET", "/v1/health", token=None)
        self.assertEqual(status, 200)
        self.assertTrue(j["ok"])
        self.assertEqual(j["model"], "gemini-4-carbon")
        self.assertTrue(j["api_key_configured"])
        self.assertNotIn("test-key-not-real", json.dumps(j))

    def test_missing_token_is_401(self):
        status, j = self.call("POST", "/v1/analyze", self.analyze_body(), token=None)
        self.assertEqual(status, 401)
        status, j = self.call("POST", "/v1/analyze", self.analyze_body(), token="wrong")
        self.assertEqual(status, 401)
        self.assertEqual(self.calls, [])

    # ---- analyze happy path

    def test_analyze_builds_generate_content_and_parses_usage(self):
        status, j = self.call("POST", "/v1/analyze", self.analyze_body())
        self.assertEqual(status, 200, j)
        self.assertEqual(j["status"], "success")
        self.assertEqual(j["text"], "{\"experiment_type\":\"healthkit\"}")
        self.assertEqual(j["usage"], {"prompt_tokens": 1200, "output_tokens": 300, "thought_tokens": 2500, "total_tokens": 4000})
        self.assertEqual(j["finish_reason"], "STOP")
        self.assertEqual(j["upstream_status"], 200)
        self.assertIsInstance(j["latency_ms"], (int, float))
        url, body = self.calls[0]
        self.assertEqual(url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-carbon:generateContent")
        self.assertEqual(body["systemInstruction"]["parts"][0]["text"], "rules")
        self.assertIn("INPUT DATA (JSON)", body["contents"][0]["parts"][0]["text"])
        self.assertIn("42.3", body["contents"][0]["parts"][0]["text"])
        gen = body["generationConfig"]
        self.assertEqual(gen["responseMimeType"], "application/json")
        self.assertEqual(gen["thinkingConfig"]["thinkingLevel"], "medium")
        self.assertEqual(gen["responseJsonSchema"]["type"], "object")
        self.assertNotIn("temperature", gen)

    def test_test_endpoint_needs_no_payload(self):
        status, j = self.call("POST", "/v1/test", {"request_id": "t-1", "experiment": "connection_test"})
        self.assertEqual(status, 200, j)
        self.assertEqual(j["status"], "success")
        self.assertIn("Connection test", self.calls[0][1]["contents"][0]["parts"][0]["text"])

    # ---- guards

    def test_rejects_model_outside_allowlist(self):
        status, j = self.call("POST", "/v1/analyze", self.analyze_body(model="gemini-1.0-ultra"))
        self.assertEqual(status, 400)
        self.assertIn("not in GEMINI_ALLOWED_MODELS", j["error"])

    def test_rejects_bad_thinking_level(self):
        status, j = self.call("POST", "/v1/analyze", self.analyze_body(thinking_level="max"))
        self.assertEqual(status, 400)

    def test_rejects_identifiers_in_payload(self):
        status, j = self.call("POST", "/v1/analyze", self.analyze_body(payload={"notes": "call me at +358 40 123 4567"}))
        self.assertEqual(status, 400)
        self.assertIn("identif", j["error"])
        status, j = self.call("POST", "/v1/analyze", self.analyze_body(payload={"x": "mail someone@example.com"}))
        self.assertEqual(status, 400)
        self.assertEqual(self.calls, [])

    def test_dates_are_not_mistaken_for_phone_numbers(self):
        status, j = self.call("POST", "/v1/analyze", self.analyze_body(payload={"range": {"start": "2026-11-14T10:16:40.000Z"}, "days": ["2026-11-01", "2026-11-02"]}))
        self.assertEqual(status, 200, j)

    def test_oversize_body_is_413(self):
        big = self.analyze_body(payload={"blob": "x" * 30000})
        status, j = self.call("POST", "/v1/analyze", big)
        self.assertEqual(status, 413)

    def test_invalid_json_is_400(self):
        status, j = self.call("POST", "/v1/analyze", raw=b"{not json")
        self.assertEqual(status, 400)

    def test_upstream_error_is_passed_through_as_502(self):
        type(self).fake_status = 429
        type(self).fake_data = {"error": {"message": "Resource exhausted", "status": "RESOURCE_EXHAUSTED"}}
        status, j = self.call("POST", "/v1/analyze", self.analyze_body())
        self.assertEqual(status, 502)
        self.assertEqual(j["status"], "api_error")
        self.assertEqual(j["upstream_status"], 429)
        self.assertEqual(j["error"], "Resource exhausted")

    def test_empty_candidates_is_an_error(self):
        type(self).fake_data = {"candidates": [{"finishReason": "SAFETY", "content": {"parts": []}}], "usageMetadata": {"promptTokenCount": 10}}
        status, j = self.call("POST", "/v1/analyze", self.analyze_body())
        self.assertEqual(status, 502)
        self.assertEqual(j["finish_reason"], "SAFETY")
        self.assertEqual(j["usage"]["prompt_tokens"], 10)

    def test_unknown_path_is_404(self):
        status, _ = self.call("GET", "/v1/nothing", token=None)
        self.assertEqual(status, 404)

    # ---- unit-level

    def test_interactions_builder_and_parser(self):
        s = gp.Settings({**ENV, "GEMINI_API_STYLE": "interactions"})
        req = gp.validate_request(self.analyze_body(), s, require_payload=True)
        url, body = gp.build_interactions(req, s)
        self.assertTrue(url.endswith("/v1beta/interactions"))
        self.assertEqual(body["model"], "gemini-4-carbon")
        self.assertEqual(body["generation_config"]["thinking_level"], "medium")
        self.assertEqual(body["response_format"]["mime_type"], "application/json")
        text, usage, status = gp.parse_interactions({"status": "completed", "output": [{"type": "message", "content": [{"type": "text", "text": "{}"}]}],
                                                     "usage": {"total_input_tokens": 1, "total_output_tokens": 2, "total_thought_tokens": 3, "total_tokens": 6}})
        self.assertEqual(text, "{}")
        self.assertEqual(usage["thought_tokens"], 3)
        self.assertEqual(status, "completed")

    def test_send_upstream_refuses_other_hosts(self):
        with self.assertRaises(RuntimeError):
            self._orig_send("https://evil.example/v1", {}, self.settings)

    def test_settings_check(self):
        s = gp.Settings({})
        problems = s.check()
        self.assertTrue(any("GEMINI_API_KEY" in p for p in problems))
        self.assertTrue(any("PROXY_TOKEN" in p for p in problems))


if __name__ == "__main__":
    unittest.main()
