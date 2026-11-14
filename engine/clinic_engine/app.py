"""App factory: HTTP guard, error shape, routers, the mind and its ticker."""

import asyncio
import contextlib
import json
import logging
import secrets
import time
from pathlib import Path
from typing import Optional

from fastapi.middleware.gzip import GZipMiddleware
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from .mind.exchanges import Recorder
from .audit import write_audit
from .config import Settings
from .llm.local import LocalModel
from .mind.engine import Clock, Mind
from .notify import UrgentNotifications, make_notifier
from .outreach import Outreach
from .security import RateLimiter
from .service import ApiError, Ctx
from .store import Store, make_store

log = logging.getLogger("clinic_engine.http")

SECURITY_HEADERS = [
    (b"x-content-type-options", b"nosniff"),
    (b"x-frame-options", b"DENY"),
    (b"referrer-policy", b"no-referrer"),
    (b"cache-control", b"no-store"),
    (b"content-security-policy", b"default-src 'none'; frame-ancestors 'none'"),
    (b"strict-transport-security", b"max-age=31536000"),
]
_DOCS_CSP = (b"default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
             b"style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; img-src 'self' data: "
             b"https://fastapi.tiangolo.com")
# The clinician page: own files only. No inline script or style, no outside
# hosts, API calls only to this origin.
_PAGE_CSP = (b"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; "
             b"font-src 'self'; media-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; "
             b"frame-ancestors 'none'")
WEB_DIR = Path(__file__).resolve().parent / "web"


def _is_page(path: str) -> bool:
    return path in ("/", "/pitch", "/demo") or path.startswith("/static/")


def _json_bytes(status: int, code: str, message: str, rid: str) -> bytes:
    return json.dumps({"error": {"code": code, "message": message, "request_id": rid}}).encode()


class Guard:
    """Pure ASGI middleware: request id, body size limit, security headers,
    access log without bodies."""

    def __init__(self, app, max_body: int, route_limits: dict | None = None):
        self.app = app
        self.max_body = max_body
        # (method, path) -> a larger limit for that route only.
        self.route_limits = route_limits or {}

    async def _reject(self, send, status: int, code: str, msg: str, rid: str) -> None:
        body = _json_bytes(status, code, msg, rid)
        await send({"type": "http.response.start", "status": status,
                    "headers": [(b"content-type", b"application/json"),
                                (b"x-request-id", rid.encode())] + SECURITY_HEADERS})
        await send({"type": "http.response.body", "body": body})

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        rid = secrets.token_hex(6)
        scope.setdefault("state", {})["request_id"] = rid
        t0 = time.monotonic()
        headers = dict(scope.get("headers") or [])
        limit = self.route_limits.get((scope.get("method"), scope["path"]), self.max_body)
        cl = headers.get(b"content-length")
        if cl is not None and (not cl.isdigit() or int(cl) > limit):
            log.info("%s %s 413 rid=%s", scope["method"], scope["path"], rid)
            return await self._reject(send, 413, "body_too_large", "Request body is too large.", rid)
        body = b""
        while True:
            msg = await receive()
            if msg["type"] == "http.request":
                body += msg.get("body", b"")
                if len(body) > limit:
                    return await self._reject(send, 413, "body_too_large",
                                              "Request body is too large.", rid)
                if not msg.get("more_body"):
                    break
            else:
                break
        sent = False

        async def replay():
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()

        status_holder = {"status": 0}
        is_docs = scope["path"] in ("/docs", "/redoc", "/openapi.json")
        is_page = _is_page(scope["path"])

        async def send_wrapped(message):
            if message["type"] == "http.response.start":
                status_holder["status"] = message["status"]
                hdrs = [h for h in message.get("headers", [])]
                for k, v in SECURITY_HEADERS:
                    if k == b"content-security-policy" and is_docs:
                        v = _DOCS_CSP
                    elif k == b"content-security-policy" and is_page:
                        v = _PAGE_CSP
                    hdrs.append((k, v))
                hdrs.append((b"x-request-id", rid.encode()))
                message = {**message, "headers": hdrs}
            await send(message)

        try:
            await self.app(scope, replay, send_wrapped)
        finally:
            log.info("%s %s %s %.0fms rid=%s", scope["method"], scope["path"],
                     status_holder["status"], (time.monotonic() - t0) * 1000, rid)


def _rid(request: Request) -> str:
    return request.scope.get("state", {}).get("request_id", "-")


_STATUS_CODES = {400: "bad_request", 401: "unauthorized", 403: "forbidden", 404: "not_found",
                 405: "method_not_allowed", 409: "conflict", 413: "body_too_large",
                 422: "invalid_request", 429: "rate_limited"}


def _audit_refusal(request: Request, action: str, reason: str) -> None:
    ctx: Ctx = request.app.state.ctx
    p = getattr(request.state, "principal", None)
    write_audit(ctx.store, ctx.clock.now(), clinic_id=p.clinic_id if p else None,
                patient_id=p.patient_id if p else None, actor=p.actor if p else "anonymous",
                action=action, outcome="refused", reason=reason,
                detail={"path": request.url.path, "method": request.method},
                request_id=_rid(request))


def create_app(settings: Optional[Settings] = None, store: Optional[Store] = None,
               clock: Optional[Clock] = None, local_model=None, outreach=None,
               notifier=None, start_ticker: bool = True) -> FastAPI:
    settings = settings or Settings.from_env()
    store = store if store is not None else make_store(settings)
    clock = clock or Clock()
    outreach = outreach or Outreach(settings)
    local_model = local_model or LocalModel(settings)
    notifier = notifier or make_notifier(settings, outreach)
    notifications = UrgentNotifications(store, settings, notifier)
    recorder = Recorder(store, clock)
    for client in (local_model, outreach):
        try:
            client.recorder = recorder
        except Exception:  # noqa: BLE001 - a test double may not take attributes
            pass
    mind = Mind(store, settings, clock, local_model, outreach, notifications)
    ctx = Ctx(store=store, settings=settings, clock=clock, mind=mind)

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI):
        task = None
        if start_ticker and settings.tick_seconds > 0:
            task = asyncio.create_task(mind.run_ticker())
        yield
        if task:
            task.cancel()
        await mind.idle()

    app = FastAPI(
        title=f"{settings.product_name} clinic engine",
        version="0.1.0",
        description=(
            "The server behind the app: senses each day against the person's own normal, "
            "holds attention when something changes, responds with one small action, and "
            "learns which action helped. It never diagnoses.\n\n"
            "Auth: `Authorization: Bearer <token>`. Device tokens come from "
            "`POST /v1/devices/pair`; clinician session tokens from `POST /v1/clinic/login`; "
            "admin tokens from the seed script.\n\n"
            "Errors always look like `{\"error\": {\"code\", \"message\", \"request_id\"}}`."),
        lifespan=lifespan,
        openapi_tags=[
            {"name": "device", "description": "Calls the iPhone app makes (device token)."},
            {"name": "mind", "description": "The patient's view of the mind: rules, lessons, questions."},
            {"name": "clinician", "description": "Clinician page (clinician session token)."},
            {"name": "admin", "description": "Demo and maintenance (admin token)."},
            {"name": "health", "description": "Liveness."},
        ],
    )
    app.state.ctx = ctx
    app.state.limiter = RateLimiter(settings.rate_per_minute, settings.rate_burst)
    app.state.open_limiter = RateLimiter(10, 10)  # pairing and login, per client address

    @app.exception_handler(ApiError)
    async def _api_error(request: Request, exc: ApiError):
        return JSONResponse(status_code=exc.status, content={"error": {
            "code": exc.code, "message": exc.message, "request_id": _rid(request)}})

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(request: Request, exc: StarletteHTTPException):
        code = _STATUS_CODES.get(exc.status_code, "error")
        if exc.status_code in (404, 405):
            _audit_refusal(request, "http", code)
        return JSONResponse(status_code=exc.status_code, content={"error": {
            "code": code, "message": str(exc.detail) if exc.status_code < 500 else "Server error.",
            "request_id": _rid(request)}})

    @app.exception_handler(RequestValidationError)
    async def _validation(request: Request, exc: RequestValidationError):
        # Never echo the input back: location and message only.
        errs = exc.errors()
        parts = []
        for e in errs[:5]:
            loc = ".".join(str(x) for x in e.get("loc", []) if x != "body")
            parts.append(f"{loc}: {e.get('msg', 'invalid')}"[:120])
        _audit_refusal(request, "validation", "invalid_request")
        return JSONResponse(status_code=422, content={"error": {
            "code": "invalid_request", "message": "; ".join(parts) or "Invalid request.",
            "request_id": _rid(request)}})

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception):
        log.error("unhandled %s rid=%s", type(exc).__name__, _rid(request))
        return JSONResponse(status_code=500, content={"error": {
            "code": "server_error", "message": "Server error.", "request_id": _rid(request)}})

    from .api import admin, clinic, device, health
    app.include_router(health.router)
    app.include_router(device.router)
    app.include_router(clinic.router)
    app.include_router(admin.router)

    # The clinician web page: static files, no build step. The API stays under /v1.
    @app.get("/", include_in_schema=False)
    async def clinician_page():
        return FileResponse(WEB_DIR / "index.html", media_type="text/html; charset=utf-8")

    # The open demo: the same page, which then asks for a read-only visitor token
    # (POST /v1/clinic/visit) in place of showing the sign-in form.
    @app.get("/demo", include_in_schema=False)
    async def open_demo_page():
        return FileResponse(WEB_DIR / "index.html", media_type="text/html; charset=utf-8")

    # The stage pitch: a page of its own, edited in web/static/pitch/index.html. It uses
    # relative paths so the same file also opens straight from disk; hence the redirect.
    @app.get("/pitch", include_in_schema=False)
    async def pitch_page():
        return RedirectResponse("/static/pitch/index.html", status_code=307)

    app.mount("/static", StaticFiles(directory=WEB_DIR / "static"), name="static")

    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins,
                           allow_methods=["GET", "POST", "DELETE"],
                           allow_headers=["Authorization", "Content-Type"])
    app.add_middleware(Guard, max_body=settings.max_body_bytes, route_limits={
        ("POST", "/v1/activities"): max(settings.max_body_bytes, settings.max_face_raw_body_bytes),
        ("POST", "/v1/health/summary"): max(settings.max_body_bytes,
                                            settings.max_face_raw_body_bytes)})
    app.add_middleware(GZipMiddleware, minimum_size=1024)  # the patient page is ~170 KB of JSON
    return app


def app_from_env() -> FastAPI:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    # The HTTP client logs full request URLs at INFO. Some outside APIs carry a secret in the URL
    # (Telegram puts the bot token in the path), so keep that logger quiet.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    return create_app()
