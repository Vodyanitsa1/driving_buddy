"""Endpoint HTTP untuk chat dengan LLM.

Dipasang ke aplikasi FastAPI yang sudah ada:

    from llm_chat import build_router
    app.include_router(build_router())

Prinsip: alarm kantuk TIDAK boleh bergantung pada LLM. Kalau LLM mati/lambat,
endpoint tetap menjawab (HTTP 200, `fallback: true`) dengan balasan darurat.
"""
from __future__ import annotations

import logging
import math
import time
from typing import Any, Callable, Dict, Optional, Tuple

from fastapi import APIRouter, HTTPException, Path

from .client import BaseLLM, LLMError, make_llm
from .config import Settings, load_settings
from .prompts import build_messages, clean_reply, pick_fallback
from .schemas import SESSION_ID_PATTERN, ChatRequest, ChatResponse
from .store import RateLimiter, SessionStore

log = logging.getLogger("driving_buddy.llm")

DEEP_CHECK_CACHE_S = 30.0


def build_router(
    settings: Optional[Settings] = None,
    llm: Optional[BaseLLM] = None,
    clock: Callable[[], float] = time.monotonic,
) -> APIRouter:
    """Buat router /chat. Tanpa argumen = baca konfigurasi dari environment / file .env.

    `settings` dan `llm` boleh disuntik manual (dipakai di tes)."""
    settings = settings or load_settings()
    if llm is None and settings.configured:
        llm = make_llm(settings)

    store = SessionStore(settings.max_sessions, settings.session_ttl_s, settings.history_turns, clock=clock)
    session_limiter = RateLimiter(settings.rate_per_session_per_min, clock=clock)
    global_limiter = RateLimiter(settings.rate_global_per_min, clock=clock)
    deep_cache: Dict[str, Tuple[float, Dict[str, Any]]] = {}

    if not settings.configured:
        log.error("[LLM] chat NONAKTIF: %s", settings.problem)
    elif settings.provider == "mock":
        log.warning("[LLM] provider=mock -> balasan palsu, belum terhubung ke LLM sungguhan")
    else:
        log.info("[LLM] siap: provider=%s model=%s host=%s", settings.provider, settings.model,
                 settings.base_url_host)

    router = APIRouter(tags=["llm"])

    def check_rate_limit(session_id: str) -> None:
        for limiter, key in ((session_limiter, session_id), (global_limiter, "*")):
            allowed, wait_s = limiter.hit(key)
            if not allowed:
                retry = max(1, math.ceil(wait_s))
                raise HTTPException(
                    status_code=429,
                    detail={"error": "rate_limited", "retry_after_s": retry},
                    headers={"Retry-After": str(retry)},
                )

    @router.post(
        "/chat",
        response_model=ChatResponse,
        summary="Kirim ucapan pengemudi, terima balasan singkat dari Buddy (LLM)",
        responses={
            429: {"description": "Terlalu banyak permintaan (lihat header Retry-After)."},
            503: {"description": "LLM belum dikonfigurasi di server (cek GET /chat/health)."},
        },
    )
    async def chat(req: ChatRequest) -> ChatResponse:
        if llm is None:
            raise HTTPException(
                status_code=503,
                detail={"error": "llm_not_configured", "message": settings.problem},
            )
        check_rate_limit(req.session_id)

        started = time.perf_counter()
        session = store.get(req.session_id)
        fallback, error = False, None
        model_name = llm.model
        async with session.lock:
            if req.reset:
                session.history.clear()
            messages = build_messages(list(session.history), req.message, req.driver_state)
            try:
                result = await llm.complete(messages)
                reply = clean_reply(result.text, settings.max_reply_chars)
                if not reply:
                    raise LLMError("empty", "balasan kosong setelah dibersihkan")
                session.add_turn(req.message, reply)
                model_name = result.model or model_name
            except LLMError as err:
                fallback, error = True, err.kind
                reply = pick_fallback(req.driver_state, req.message)
                level = log.error if err.kind in ("auth", "not_found", "bad_request") else log.warning
                level("[LLM] gagal (%s), pakai balasan darurat: %s", err.kind, err.detail[:200])
            except Exception:  # bug tak terduga: jangan sampai chat menjatuhkan aplikasi
                fallback, error = True, "internal"
                reply = pick_fallback(req.driver_state, req.message)
                log.exception("[LLM] error tak terduga di /chat")

        return ChatResponse(
            reply=reply,
            session_id=req.session_id,
            provider=settings.provider,
            model=model_name,
            latency_ms=int((time.perf_counter() - started) * 1000),
            fallback=fallback,
            error=error,
        )

    @router.delete("/chat/{session_id}", summary="Hapus riwayat percakapan satu sesi")
    async def clear_chat(session_id: str = Path(..., min_length=1, max_length=64, pattern=SESSION_ID_PATTERN)):
        return {"session_id": session_id, "cleared": store.reset(session_id)}

    @router.get("/chat/health", summary="Cek konfigurasi LLM (deep=true: cek koneksi & nama model ke provider)")
    async def chat_health(deep: bool = False) -> Dict[str, Any]:
        info: Dict[str, Any] = {
            "status": "ok" if llm is not None else "not_configured",
            "provider": settings.provider,
            "model": settings.model,
            "host": settings.base_url_host or None,
            "problem": settings.problem,
            "active_sessions": len(store),
        }
        if deep and llm is not None:
            now = clock()
            cached = deep_cache.get("deep")
            if cached is None or now - cached[0] > DEEP_CHECK_CACHE_S:
                deep_cache["deep"] = (now, await _deep_check(llm, settings))
            info.update(deep_cache["deep"][1])
        return info

    return router


async def _deep_check(llm: BaseLLM, settings: Settings) -> Dict[str, Any]:
    """Tanya daftar model ke provider: membuktikan API key + koneksi benar tanpa memakai token."""
    try:
        ids = await llm.list_models()
    except LLMError as err:
        log.warning("[LLM] deep check gagal (%s): %s", err.kind, err.detail[:200])
        return {"reachable": False, "error": err.kind, "http_status": err.status}
    return {"reachable": True, "model_available": settings.model in ids, "models_listed": len(ids)}
