"""Endpoint HTTP pencarian tempat terdekat.

Dipasang ke aplikasi FastAPI yang sudah ada:

    from nearby_places import build_router
    app.include_router(build_router())

Prinsip: alarm kantuk TIDAK boleh bergantung pada fitur ini. Kalau Google/OSM gagal, jatah habis, atau
konfigurasi salah, endpoint tetap menjawab dengan jelas (HTTP 200 + `degraded: true`, atau 503 kalau memang
belum dikonfigurasi) dan tidak pernah membuat server.py berhenti.
"""
from __future__ import annotations

import logging
import math
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

from fastapi import APIRouter, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from starlette.responses import Response

from . import categories
from .cache import NearbyCache
from .config import Settings, load_settings
from .limits import RateLimiter, UsageLedger
from .providers import GooglePlacesProvider, MockProvider, OverpassProvider, SnapshotProvider
from .providers.base import BaseProvider
from .providers.osm import host_of
from .schemas import NearbyRequest, NearbyResponse
from .service import PlacesService

log = logging.getLogger("driving_buddy.places")

DEEP_CHECK_CACHE_S = 60.0


class _SafeRoute(APIRoute):
    """Jawaban 422 yang aman dikirim: hanya type/loc/msg. Tanpa ini, body berisi NaN/Infinity membuat FastAPI gagal
    menyusun jawaban 422 (nilai itu ikut di detail kesalahan dan tidak bisa jadi JSON), sehingga klien menerima HTTP 500."""

    def get_route_handler(self):
        original = super().get_route_handler()

        async def handler(request: Request) -> Response:
            try:
                return await original(request)
            except RequestValidationError as exc:
                detail = [{"type": str(e.get("type", "value_error")),
                           "loc": [str(part) if not isinstance(part, int) else part for part in e.get("loc", ())],
                           "msg": str(e.get("msg", ""))} for e in exc.errors()]
                return JSONResponse(status_code=422, content={"detail": detail})

        return handler


def make_providers(settings: Settings) -> Dict[str, BaseProvider]:
    providers: Dict[str, BaseProvider] = {}
    wanted = [settings.provider] + ([settings.fallback_provider] if settings.fallback_provider else [])
    for name in wanted:
        if name == "google":
            providers[name] = GooglePlacesProvider(settings)
        elif name == "osm":
            providers[name] = OverpassProvider(settings)
        elif name == "snapshot":
            providers[name] = SnapshotProvider(settings)
        elif name == "mock":
            providers[name] = MockProvider()
    return providers


def build_router(
    settings: Optional[Settings] = None,
    providers: Optional[Dict[str, BaseProvider]] = None,
    ledger: Optional[UsageLedger] = None,
    clock: Callable[[], float] = time.monotonic,
    wall_clock: Callable[[], float] = time.time,
) -> APIRouter:
    """Buat router /places. Tanpa argumen = baca konfigurasi dari environment / file .env.

    `settings`, `providers`, `ledger` boleh disuntik manual (dipakai di tes)."""
    settings = settings or load_settings()
    service: Optional[PlacesService] = None
    if settings.configured:
        service = PlacesService(
            settings,
            providers if providers is not None else make_providers(settings),
            ledger if ledger is not None else UsageLedger(settings.usage_file, settings.tz_offset_hours, wall_clock),
            NearbyCache(settings.cache_ttl_s, settings.cache_tolerance_m, settings.cache_max_entries, clock,
                        stale_ttl_s=settings.stale_ttl_s, stale_file=settings.stale_cache_file),
        )

    client_limiter = RateLimiter(settings.rate_per_client_per_min, clock=clock)
    global_limiter = RateLimiter(settings.rate_global_per_min, clock=clock)
    deep_cache: Dict[str, Tuple[float, Dict[str, Any]]] = {}

    if not settings.configured:
        log.error("[PLACES] tempat terdekat NONAKTIF: %s", settings.problem)
    elif settings.provider == "mock":
        log.warning("[PLACES] provider=mock -> tempat palsu, belum terhubung ke peta sungguhan")
    else:
        extra = f" cadangan={settings.fallback_provider}" if settings.fallback_provider else ""
        log.info("[PLACES] siap: provider=%s%s", settings.provider, extra)

    router = APIRouter(prefix="/places", tags=["places"], route_class=_SafeRoute)

    def check_rate_limit(client: str) -> None:
        for limiter, key in ((client_limiter, client), (global_limiter, "*")):
            allowed, wait_s = limiter.hit(key)
            if not allowed:
                retry = max(1, math.ceil(wait_s))
                raise HTTPException(
                    status_code=429,
                    detail={"error": "rate_limited", "retry_after_s": retry},
                    headers={"Retry-After": str(retry)},
                )

    @router.post(
        "/nearby",
        response_model=NearbyResponse,
        summary="Cari rest area / minimarket / hotel-motel (/ SPBU) terdekat dari posisi pengemudi",
        responses={
            422: {"description": "Koordinat/parameter tidak valid (termasuk koordinat 0,0 = GPS belum siap)."},
            429: {"description": "Terlalu banyak permintaan (lihat header Retry-After)."},
            503: {"description": "Fitur belum dikonfigurasi di server (cek GET /places/health)."},
        },
    )
    async def nearby(req: NearbyRequest, request: Request) -> NearbyResponse:
        if service is None:
            raise HTTPException(
                status_code=503,
                detail={"error": "places_not_configured", "message": settings.problem},
            )
        check_rate_limit(request.client.host if request.client else "unknown")
        try:
            return await service.nearby(req)
        except Exception:  # bug tak terduga: jangan sampai fitur ini menjatuhkan aplikasi
            log.exception("[PLACES] error tak terduga di /places/nearby")
            raise HTTPException(status_code=500, detail={"error": "internal"}) from None

    @router.get("/categories", summary="Daftar kategori yang bisa dicari (buat tombol di aplikasi)")
    async def list_categories() -> List[Dict[str, Any]]:
        listing = [
            {"key": cat.key, "label": cat.label, "default_radius_m": cat.default_radius_m, "in_all": cat.in_all}
            for cat in categories.CATEGORIES.values()
        ]
        return [{"key": categories.ALL, "label": "Semua terdekat", "default_radius_m": None, "in_all": False}] + listing

    @router.get("/health", summary="Cek konfigurasi (deep=true: tes koneksi + API key ke provider, memakai 1 jatah)")
    async def health(deep: bool = False) -> Dict[str, Any]:
        info: Dict[str, Any] = {
            "status": "ok" if service is not None else "not_configured",
            "provider": settings.provider,
            "fallback_provider": settings.fallback_provider or None,
            "problem": settings.problem,
            "api_key_configured": bool(settings.google_api_key),
            "google_host": settings.google_host if settings.provider == "google" else None,
            "rating_hours": settings.google_rating_hours,
            "notes": list(settings.notes),
        }
        if service is not None:
            info["usage"] = service.usage()
            info["cache_entries"] = len(service.cache)
            info["stale_cache_entries"] = service.cache.stale_entries
            if settings.provider == "osm" or settings.fallback_provider == "osm":
                info["osm"] = {"servers": [host_of(u) for u in settings.osm_urls],
                               "transport": settings.osm_transport}
            snapshot = service.providers.get("snapshot")
            if isinstance(snapshot, SnapshotProvider):
                info["snapshot"] = snapshot.describe()
            if deep:
                now = clock()
                cached = deep_cache.get("deep")
                if cached is None or now - cached[0] > DEEP_CHECK_CACHE_S:
                    deep_cache["deep"] = (now, await service.probe())
                info.update(deep_cache["deep"][1])
        return info

    return router
