"""The clinician web page: served files, headers, no outside resources, the
page's API additions, and who may use the demo endpoints."""

import re
import pytest

from clinic_engine import seed
from clinic_engine.app import WEB_DIR

from conftest import NOW, Env

JS = (WEB_DIR / "static" / "app.js").read_text("utf-8")
CSS = (WEB_DIR / "static" / "app.css").read_text("utf-8")
HTML = (WEB_DIR / "index.html").read_text("utf-8")


# ---- serving and headers ------------------------------------------------------------------

def test_page_and_static_files_are_served(env):
    r = env.client.get("/")
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/html")
    assert "/static/app.js" in r.text and "/static/app.css" in r.text
    js = env.client.get("/static/app.js")
    assert js.status_code == 200 and "javascript" in js.headers["content-type"]
    css = env.client.get("/static/app.css")
    assert css.status_code == 200 and css.headers["content-type"].startswith("text/css")
    assert env.client.get("/static/nope.js").status_code == 404
    assert env.client.get("/static/../app.py").status_code == 404


@pytest.mark.parametrize("path", ["/", "/static/app.js", "/static/app.css"])
def test_page_has_strict_csp_and_security_headers(env, path):
    h = env.client.get(path).headers
    csp = h["content-security-policy"]
    assert "default-src 'none'" in csp
    assert "script-src 'self'" in csp and "style-src 'self'" in csp
    assert "connect-src 'self'" in csp and "frame-ancestors 'none'" in csp
    assert "font-src 'self'" in csp
    assert "unsafe-inline" not in csp and "unsafe-eval" not in csp and "http" not in csp
    assert h["x-frame-options"] == "DENY"
    assert h["x-content-type-options"] == "nosniff"
    assert h["referrer-policy"] == "no-referrer"
    assert "strict-transport-security" in h


def test_api_docs_and_health_still_work(env):
    assert env.client.get("/healthz").json()["ok"] is True
    assert env.client.get("/docs").status_code == 200
    doc = env.client.get("/openapi.json").json()
    assert "/v1/clinic/me" in doc["paths"]
    assert "/" not in doc["paths"]
    # The API keeps its own, stricter policy.
    r = env.client.get("/v1/today", headers=env.H)
    assert r.headers["content-security-policy"] == "default-src 'none'; frame-ancestors 'none'"


# ---- the files themselves -----------------------------------------------------------------

def test_js_never_writes_html():
    assert "innerHTML" not in JS
    assert not re.search(r"outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function",
                         JS)


def test_no_outside_resources():
    for name, text in (("index.html", HTML), ("app.css", CSS), ("app.js", JS)):
        urls = re.findall(r"(?:https?:)?//[A-Za-z0-9.-]+\.[A-Za-z]{2,}[^\s\"')]*", text)
        # The only URL allowed is the SVG namespace name (an identifier, never fetched).
        assert all(u == "http://www.w3.org/2000/svg" for u in urls), (name, urls)
        assert "@import" not in text
        # The only url() allowed: the self-hosted font files, by relative path.
        for u in re.findall(r"url\(([^)]*)\)", text):
            assert re.fullmatch(r'"fonts/archivo-latin(-ext)?\.woff2"', u), (name, u)


def test_font_is_self_hosted_with_its_licence(env):
    for f in ("archivo-latin.woff2", "archivo-latin-ext.woff2"):
        r = env.client.get("/static/fonts/" + f)
        assert r.status_code == 200 and r.content[:4] == b"wOF2"
        assert r.headers["content-type"] == "font/woff2"
    lic = env.client.get("/static/fonts/OFL.txt")
    assert lic.status_code == 200 and "SIL Open Font License" in lic.text


def test_html_has_no_inline_script_style_or_handlers():
    assert re.findall(r"<script[^>]*>", HTML) == ['<script src="/static/app.js" defer>']
    assert "<style" not in HTML and " style=" not in HTML
    assert not re.search(r"\son[a-z]+=", HTML)
    for tag in ("<label", "<button", "<a "):
        assert tag in HTML


def test_css_variables_in_one_root_block_dark_only():
    assert len(re.findall(r":root\s*{", CSS)) == 1
    root = CSS[re.search(r":root\s*{", CSS).start():]
    root_block, rest = root[:root.index("\n}") + 2], CSS.replace(root[:root.index("\n}") + 2], "")
    assert re.search(r"--[a-z-]+:", root_block)
    assert not re.search(r"--[a-z-]+:", rest)  # no variable is defined outside :root
    assert "light-dark(" not in CSS and "color-scheme: dark" in CSS
    for token in ("#0f0f13", "#17171d", "#26262e", "#f3f0ea", "#9d9daa",
                  "#f5a623", "#f08a1c", "#e8431e", "#8f1a1a", "#5e0f0f"):
        assert token in root_block, token
    assert "gradient" not in CSS
    assert ":focus-visible" in CSS


def test_token_kept_in_session_storage_only():
    assert "localStorage" not in JS and "document.cookie" not in JS
    assert "sessionStorage" in JS


# ---- API additions used by the page --------------------------------------------------------

def other_clinician(env):
    seed.create_clinician(env.store, env.demo["mock_clinic_id"], "other-clinician",
                          "other clinic password", NOW)
    r = env.client.post("/v1/clinic/login", json={"username": "other-clinician",
                                                  "password": "other clinic password"})
    assert r.status_code == 200
    return {"Authorization": "Bearer " + r.json()["session_token"]}


def test_me_says_product_and_demo_only_for_demo_clinic(env):
    me = env.client.get("/v1/clinic/me", headers=env.C()).json()
    assert me["product_name"] == env.settings.product_name
    assert me["clinic_name"] == "Demo clinic"
    assert me["demo"] == {"enabled": True, "patient_id": env.demo["patient_id"]}
    other = env.client.get("/v1/clinic/me", headers=other_clinician(env)).json()
    assert other["demo"] == {"enabled": False, "patient_id": None}
    assert env.client.get("/v1/clinic/me", headers=env.H).status_code == 403
    assert env.client.get("/v1/clinic/me", headers=env.A).status_code == 403


def test_me_demo_off():
    env = Env(demo_enabled=False)
    me = env.client.get("/v1/clinic/me", headers=env.C()).json()
    assert me["demo"] == {"enabled": False, "patient_id": None}


def test_round_detail_has_usual_round_and_progress_has_band(env):
    C = env.C()
    pid = env.demo["patient_id"]
    r = env.client.get(f"/v1/clinic/patients/{pid}/rounds/example-round-09", headers=C).json()
    u = r["usual_round"]
    assert u is not None and u["id"] != "example-round-09" and u["mode"] == r["mode"]
    assert u["path"]["points"] and u["example"] is True
    first = env.client.get(f"/v1/clinic/patients/{pid}/rounds/example-round-00", headers=C).json()
    assert first["usual_round"] is None  # nothing earlier to compare with
    d = env.client.get(f"/v1/clinic/patients/{pid}", headers=C).json()
    assert d["progress"]["band"]["low_z"] < 0 < d["progress"]["band"]["high_z"]


def test_list_puts_those_needing_a_look_first():
    env = Env(extra=3)
    lines = env.client.get("/v1/clinic/patients", headers=env.C()).json()["patients"]
    lv = {"urgent": 0, "attention": 1, "watch": 2, None: 3}
    st = {"outside": 0, "no_data": 1, "no_baseline": 2, "within": 3}
    keys = [(lv[x["level"]], st[x["status"]]) for x in lines]
    assert keys == sorted(keys)


# ---- demo endpoints: who may call them -----------------------------------------------------

def demo_calls(env):
    pid = env.demo["patient_id"]
    return [
        ("/v1/demo/scenario", {"name": "dip"}),
        ("/v1/review/run", {"patient_id": pid}),
        ("/v1/demo/analyze", {"patient_id": pid, "round_id": "example-round-09"}),
        ("/v1/demo/tick", None),
        ("/v1/demo/reset", None),
    ]


def post(env, path, body, headers):
    return env.client.post(path, headers=headers, json=body) if body is not None \
        else env.client.post(path, headers=headers)


def test_demo_on_admin_and_demo_clinician_allowed(env):
    C = env.C()
    for path, body in demo_calls(env):
        assert post(env, path, body, env.A).status_code == 200, path
        assert post(env, path, body, C).status_code == 200, path


def test_demo_on_other_clinic_clinician_and_device_refused(env):
    O = other_clinician(env)
    for path, body in demo_calls(env):
        assert post(env, path, body, O).status_code == 403, path
        assert post(env, path, body, env.H).status_code == 403, path
    from clinic_engine.audit import list_audit
    reasons = [e["reason"] for e in list_audit(env.store, env.demo["mock_clinic_id"], None,
                                               outcome="refused")]
    assert "demo_not_allowed_for_clinician" in reasons


def test_demo_clinician_cannot_touch_another_clinics_patient(env):
    C = env.C()
    other = env.demo["mock_patient_id"]
    for path, body in [("/v1/demo/scenario", {"name": "dip", "patient_id": other}),
                       ("/v1/review/run", {"patient_id": other}),
                       ("/v1/demo/analyze", {"patient_id": other, "round_id": "example-round-09"})]:
        assert post(env, path, body, C).status_code == 404, path
    other_repo = env.repo(pid=other, clinic=env.demo["mock_clinic_id"])
    assert not any(i["kind"] == "deviation" for i in other_repo.items())
    from clinic_engine.audit import list_audit
    reasons = [e["reason"] for e in list_audit(env.store, env.demo["clinic_id"], None,
                                               outcome="refused")]
    assert "patient_not_in_clinic" in reasons
    # The admin still may.
    assert post(env, "/v1/demo/scenario", {"name": "dip", "patient_id": other},
                env.A).status_code == 200


def test_demo_off_admin_only():
    env = Env(demo_enabled=False)
    C = env.C()
    for path, body in demo_calls(env):
        assert post(env, path, body, C).status_code == 403, path
    # The admin keeps working as before: review, tick and analyze run; the
    # endpoints that need the seeded demo (reset, scenario) answer "off".
    assert post(env, "/v1/review/run", {"patient_id": env.demo["patient_id"]},
                env.A).status_code == 200
    assert post(env, "/v1/demo/tick", None, env.A).status_code == 200
    assert post(env, "/v1/demo/reset", None, env.A).status_code == 404


def test_detail_has_what_the_tabs_need(env):
    C = env.C()
    pid = env.demo["patient_id"]
    d = env.client.get(f"/v1/clinic/patients/{pid}", headers=C).json()
    pr = d["progress"]
    assert pr["today"] == "2026-11-13"
    assert pr["usual"]["steps"] > 0  # the current own-normal median, for the readout
    day = pr["series"][-1]
    assert day["values"]["steps"] > 0 and "walking_speed_m_s" in day["values"]
    r = pr["rounds"]["energy_series"][-1]
    assert r["completed"] is True and r["after_suggestion"] is False
    assert d["rules"] == [] and isinstance(d["notify_log"], list)


def test_notify_log_lists_sends_and_suppressions():
    env = Env()  # notify mode is off: an urgent item is recorded as not sent
    env.client.post("/v1/notes", headers=env.H, json={"id": "note-0001-abcd",
                                                      "text": "I need help tonight"})
    pid = env.demo["patient_id"]
    d = env.client.get(f"/v1/clinic/patients/{pid}", headers=env.C()).json()
    assert d["notify_log"] and all(e["action"] == "notify_urgent" for e in d["notify_log"])
    assert d["notify_log"][0]["reason"] == "notify_off"
