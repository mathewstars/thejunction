from fastapi import APIRouter, Request

router = APIRouter(tags=["health"])


@router.get("/healthz", summary="Liveness (no auth)")
async def healthz(request: Request):
    return {"ok": True, "product": request.app.state.ctx.settings.product_name}
