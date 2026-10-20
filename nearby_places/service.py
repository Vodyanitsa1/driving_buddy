"""Alur utama pencarian: cache -> jatah panggilan -> provider -> urut jarak -> ringkasan suara.

Prinsip: pencarian tempat TIDAK boleh menjatuhkan aplikasi atau alarm kantuk. Kegagalan provider/jatah
dilaporkan sebagai `degraded` + `errors` (HTTP 200), tidak pernah sebagai exception ke aplikasi.
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlencode

from . import categories
from .cache import NearbyCache
from .categories import Category
from .config import Settings
from .geo import angle_diff_deg, bearing_deg, format_distance, haversine_m, speak_distance
from .limits import LedgerBudget, UsageLedger
from .providers.base import NO_BUDGET, BaseProvider, Budget, Place, PlacesError
from .providers.osm import sanitize
from .schemas import NearbyRequest, NearbyResponse, PlaceOut

log = logging.getLogger("driving_buddy.places")

AHEAD_LIMIT_DEG = 90.0  # selisih arah < 90 derajat dari arah gerak = "di depan"
LOW_ACCURACY_M = 1000.0
MAX_NAME_CHARS = 80
SUMMARY_NAME_CHARS = 50
FALLBACK_SUMMARY = "Pencarian tempat terdekat lagi bermasalah. Kalau kamu ngantuk, menepi di tempat yang aman dulu."

_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]+")
_SPACE_RE = re.compile(r"\s+")


@dataclass
class _Outcome:
    category: Category
    radius_m: int
    items: List[PlaceOut] = field(default_factory=list)
    provider_used: Optional[str] = None
    cached: bool = False
    error: Optional[str] = None
    stale_age_s: Optional[float] = None  # diisi kalau hasil diambil dari cache basi karena provider gagal


def clean_name(text: str, limit: int = MAX_NAME_CHARS) -> str:
    """Nama tempat berasal dari data pihak ketiga: buang karakter kontrol, rapikan spasi, batasi panjang."""
    text = _SPACE_RE.sub(" ", _CONTROL_RE.sub(" ", text or "")).strip()
    return text[:limit].rstrip()


def navigate_url(place: Place, provider: str) -> str:
    """Link yang membuka aplikasi Google Maps langsung ke navigasi mobil. Tidak memakai API key, tidak ada biaya."""
    params = [("api", "1"), ("destination", f"{place.lat:.6f},{place.lng:.6f}"), ("travelmode", "driving")]
    if provider == "google" and place.id:
        params.append(("destination_place_id", place.id))
    return "https://www.google.com/maps/dir/?" + urlencode(params, safe=",")


def search_url(place: Place) -> str:
    return "https://www.google.com/maps/search/?" + urlencode(
        [("api", "1"), ("query", f"{place.lat:.6f},{place.lng:.6f}")], safe=",")


def format_age(seconds: float) -> str:
    minutes = int(seconds // 60)
    if minutes < 1:
        return "kurang dari 1 menit lalu"
    if minutes < 60:
        return f"{minutes} menit lalu"
    hours, rest = divmod(minutes, 60)
    return f"{hours} jam {rest} menit lalu" if rest else f"{hours} jam lalu"


class PlacesService:
    def __init__(self, settings: Settings, providers: Dict[str, BaseProvider], ledger: UsageLedger,
                 cache: NearbyCache):
        self.settings = settings
        self.providers = providers
        self.ledger = ledger
        self.cache = cache
        self.order: List[str] = [settings.provider] + ([settings.fallback_provider] if settings.fallback_provider else [])
        missing = [name for name in self.order if name not in providers]
        if missing:
            raise ValueError(f"provider belum disediakan: {', '.join(missing)}")
        # Semaphore dibuat saat pertama dipakai di dalam event loop (Python 3.9 mengikat ke loop saat dibuat).
        self._semaphores: Dict[str, Tuple[Any, asyncio.Semaphore]] = {}

    # -- API publik ---------------------------------------------------------
    async def nearby(self, req: NearbyRequest) -> NearbyResponse:
        started = time.perf_counter()
        cats = categories.expand(req.category)
        outcomes: List[_Outcome] = list(await asyncio.gather(*(self._search_one(c, req) for c in cats)))

        results: List[PlaceOut] = [item for o in outcomes for item in o.items]
        errors = {o.category.key: o.error for o in outcomes if o.error}
        succeeded = [o for o in outcomes if not o.error]
        warnings: List[str] = []
        if req.accuracy_m is not None and req.accuracy_m > LOW_ACCURACY_M:
            warnings.append(f"Akurasi lokasi rendah (sekitar {format_distance(req.accuracy_m)}), "
                            "hasil bisa kurang tepat.")
        for o in outcomes:
            if o.stale_age_s is not None:
                warnings.append(f"Data {o.category.label} tersimpan dari {format_age(o.stale_age_s)}, "
                                "penyedia peta sedang tidak bisa dihubungi.")
        for o in succeeded:
            note = getattr(self.providers.get(o.provider_used or ""), "source_note", None)
            if note and note not in warnings:
                warnings.append(note)

        response = NearbyResponse(
            results=results,
            summary=self._summary(outcomes),
            category=req.category,
            provider=self.settings.provider,
            cached=bool(succeeded) and all(o.cached for o in succeeded),
            degraded=bool(errors),
            errors=errors,
            fallback_used=any(o.provider_used not in (None, self.settings.provider) for o in succeeded),
            warnings=warnings,
            latency_ms=int((time.perf_counter() - started) * 1000),
        )
        # Sengaja TIDAK mencatat koordinat: lokasi pengemudi adalah data pribadi.
        log.info("[PLACES] cat=%s provider=%s hasil=%d cached=%s degraded=%s errors=%s %dms",
                 req.category, self.settings.provider, len(results), response.cached, response.degraded,
                 errors or "-", response.latency_ms)
        return response

    async def probe(self) -> Dict[str, Any]:
        """Satu pencarian kecil ke provider utama (memakai 1 jatah) untuk memastikan key & koneksi benar."""
        name = self.settings.provider
        started = time.perf_counter()
        try:
            async with self._semaphore(name):
                count = await self.providers[name].probe(self._budget(name))
        except PlacesError as err:
            log.warning("[PLACES] deep check gagal (%s): %s", err.kind, sanitize(err.detail, 300))
            return {"reachable": False, "error": err.kind, "http_status": err.status, "hint": err.hint,
                    "detail": sanitize(err.detail, 200) or None,
                    "latency_ms": int((time.perf_counter() - started) * 1000)}
        return {"reachable": True, "sample_count": count, "latency_ms": int((time.perf_counter() - started) * 1000)}

    def usage(self) -> Dict[str, Any]:
        info: Dict[str, Any] = {}
        for name in self.order:
            daily, monthly = self.settings.budget_for(name)
            used = self.ledger.snapshot(name)
            info[name] = {"today": used["today"], "daily_limit": daily or None,
                          "month": used["month"], "monthly_limit": monthly or None}
        return info

    # -- internal -----------------------------------------------------------
    def _semaphore(self, name: str) -> asyncio.Semaphore:
        loop = asyncio.get_running_loop()
        entry = self._semaphores.get(name)
        if entry is None or entry[0] is not loop:
            entry = (loop, asyncio.Semaphore(max(1, self.providers[name].max_concurrency)))
            self._semaphores[name] = entry
        return entry[1]

    def _budget(self, name: str) -> Budget:
        daily, monthly = self.settings.budget_for(name)
        if daily <= 0 and monthly <= 0:
            return NO_BUDGET
        return LedgerBudget(self.ledger, name, daily, monthly)

    async def _search_one(self, cat: Category, req: NearbyRequest) -> _Outcome:
        radius = min(req.radius_m or cat.default_radius_m, self.settings.max_radius_m)

        for name in self.order:
            hit = self.cache.get(name, cat.key, radius, req.lat, req.lng)
            if hit is not None:
                return self._finish(cat, radius, hit, name, True, req)

        first_error: Optional[str] = None  # yang dilaporkan: kegagalan provider UTAMA (paling berguna untuk diperbaiki)
        for name in self.order:
            try:
                async with self._semaphore(name):
                    places = await self.providers[name].search(cat, req.lat, req.lng, radius, self._budget(name))
            except PlacesError as err:
                first_error = first_error or err.kind
                level = log.error if err.kind in ("auth", "bad_request") else log.warning
                level("[PLACES] %s/%s gagal (%s): %s", name, cat.key, err.kind, sanitize(err.detail, 300))
                continue
            except Exception:  # bug tak terduga: jangan sampai pencarian menjatuhkan aplikasi
                first_error = first_error or "internal"
                log.exception("[PLACES] %s/%s error tak terduga", name, cat.key)
                continue
            self.cache.put(name, cat.key, radius, req.lat, req.lng, places)
            return self._finish(cat, radius, places, name, False, req)
        stale = self.cache.get_stale(cat.key, radius, req.lat, req.lng)
        if stale is not None:
            places, age, provider = stale
            log.warning("[PLACES] %s: semua provider gagal (%s), dipakai data tersimpan umur %ds",
                        cat.key, first_error or "internal", int(age))
            outcome = self._finish(cat, radius, places, provider, True, req)
            outcome.stale_age_s = age
            return outcome
        return _Outcome(category=cat, radius_m=radius, error=first_error or "internal")

    def _finish(self, cat: Category, radius: int, places: List[Place], provider: str, cached: bool,
                req: NearbyRequest) -> _Outcome:
        """Jarak dan arah SELALU dihitung ulang dari posisi terbaru (urutan dari provider tidak dipercaya)."""
        heading = req.effective_heading
        rows: List[Tuple[float, float, Optional[bool], Place]] = []
        seen = set()
        for place in places:
            if place.id in seen:
                continue
            seen.add(place.id)
            dist = haversine_m(req.lat, req.lng, place.lat, place.lng)
            if dist > radius:
                continue
            brg = bearing_deg(req.lat, req.lng, place.lat, place.lng)
            ahead = None if heading is None else angle_diff_deg(brg, heading) < AHEAD_LIMIT_DEG
            rows.append((dist, brg, ahead, place))

        if req.prefer_ahead and heading is not None:
            rows.sort(key=lambda r: (0 if r[2] else 1, r[0]))
        else:
            rows.sort(key=lambda r: r[0])

        items = [
            PlaceOut(
                id=place.id,
                name=clean_name(place.name) or f"{cat.label} (tanpa nama)",
                category=cat.key,
                category_label=cat.label,
                address=clean_name(place.address, 160),
                lat=round(place.lat, 6),
                lng=round(place.lng, 6),
                distance_m=int(round(dist)),
                distance_text=format_distance(dist),
                bearing_deg=int(round(brg)) % 360,
                ahead=ahead,
                open_now=place.open_now,
                rating=place.rating,
                maps_url=place.maps_url or search_url(place),
                navigate_url=navigate_url(place, provider),
                source=provider,
                provider_type=place.provider_type or None,
            )
            for dist, brg, ahead, place in rows[:req.limit]
        ]
        return _Outcome(category=cat, radius_m=radius, items=items, provider_used=provider, cached=cached)

    @staticmethod
    def _summary(outcomes: List[_Outcome]) -> str:
        if outcomes and all(o.error for o in outcomes):
            return FALLBACK_SUMMARY
        sentences: List[str] = []
        for o in outcomes:
            speech = o.category.speech
            label = speech[0].upper() + speech[1:]
            if o.error:
                sentences.append(f"Pencarian {speech} lagi bermasalah.")
            elif o.items:
                first = o.items[0]
                where = " di depan" if first.ahead is True else " di belakang" if first.ahead is False else ""
                sentences.append(f"{label} terdekat: {clean_name(first.name, SUMMARY_NAME_CHARS)}, sekitar "
                                 f"{speak_distance(first.distance_m)}{where}.")
            else:
                sentences.append(f"Tidak ada {speech} dalam {speak_distance(o.radius_m)}.")
        return " ".join(sentences)
