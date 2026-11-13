"""Auth dependencies: bearer token -> Principal, with scope and rate checks."""

from typing import Optional

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from ..audit import write_audit
from ..security import Principal, resolve_token
from ..service import ApiError, Ctx

bearer = HTTPBearer(auto_error=False, scheme_name="bearer",
                    description="Opaque bearer token (device, clinician session, or admin).")


def errors(*codes: int) -> dict:
    """OpenAPI error responses, all with the same shape."""
    from ..models import ErrorResponse
    names = {400: "Bad request", 401: "Missing or invalid token", 403: "Wrong scope",
             404: "Not found (or not in your tenant)", 409: "Conflict", 413: "Body too large",
             422: "Invalid or implausible input", 429: "Rate limited"}
    return {c: {"model": ErrorResponse, "description": names.get(c, "Error")} for c in codes}


def ctx_of(request: Request) -> Ctx:
    return request.app.state.ctx


def rid_of(request: Request) -> str:
    return request.scope.get("state", {}).get("request_id", "-")


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _refuse(request: Request, p: Optional[Principal], reason: str, status: int, code: str,
            message: str):
    ctx = ctx_of(request)
    write_audit(ctx.store, ctx.clock.now(), clinic_id=p.clinic_id if p else None,
                patient_id=p.patient_id if p else None, actor=p.actor if p else "anonymous",
                action="auth", outcome="refused", reason=reason,
                detail={"path": request.url.path, "method": request.method},
                request_id=rid_of(request))
    raise ApiError(status, code, message)


def require(*scopes: str):
    async def dep(request: Request,
                  cred: Optional[HTTPAuthorizationCredentials] = Depends(bearer)) -> Principal:
        ctx = ctx_of(request)
        if cred is None or cred.scheme.lower() != "bearer":
            _refuse(request, None, "missing_token", 401, "unauthorized", "A bearer token is required.")
        p = resolve_token(ctx.store, cred.credentials, ctx.clock.now())
        if p is None:
            _refuse(request, None, "invalid_token", 401, "unauthorized", "The token is not valid.")
        if not request.app.state.limiter.allow(p.token_hash):
            _refuse(request, p, "rate_limited", 429, "rate_limited", "Too many requests.")
        if p.scope not in scopes:
            _refuse(request, p, f"wrong_scope:{p.scope}", 403, "forbidden",
                    "This token may not call this endpoint.")
        request.state.principal = p
        return p
    return dep


def open_rate_limit(request: Request, what: str) -> None:
    if not request.app.state.open_limiter.allow(f"{what}:{client_ip(request)}"):
        _refuse(request, None, f"rate_limited_{what}", 429, "rate_limited", "Too many requests.")


device_only = require("device")
clinician_only = require("clinician")
admin_only = require("admin")


_admin_or_clinician = require("admin", "clinician")


def demo_clinic_id(ctx: Ctx) -> Optional[str]:
    """The seeded demo clinic, only while demo mode is on."""
    if not ctx.settings.demo_enabled:
        return None
    st = ctx.store.get("demo/state.json") or {}
    return st.get("clinic_id")


async def demo_actor(request: Request,
                     p: Principal = Depends(_admin_or_clinician)) -> Principal:
    """Admin always. A clinician only while DEMO_ENABLED is true, and only a
    clinician of the seeded demo clinic. Everyone else: 403."""
    if p.scope == "clinician" and p.clinic_id != demo_clinic_id(ctx_of(request)):
        _refuse(request, p, "demo_not_allowed_for_clinician", 403, "forbidden",
                "This token may not call this endpoint.")
    return p
