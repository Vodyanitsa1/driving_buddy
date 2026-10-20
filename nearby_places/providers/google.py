"""Google Places API (New) - Nearby Search.

Dokumentasi: https://developers.google.com/maps/documentation/places/web-service/nearby-search

Hal-hal yang sengaja dijaga di sini (semuanya sumber kesalahan/tagihan yang umum):

* `rankPreference: DISTANCE`. Bawaan Google adalah POPULARITY, jadi tanpa ini "terdekat" bukan yang terdekat.
* `locationRestriction.circle.radius` wajib > 0 (bawaannya 0.0 = ditolak) dan maksimal 50.000 m.
* `X-Goog-FieldMask` wajib. Isinya hanya field tier "Pro". Satu saja field tier "Enterprise"
  (rating, jam buka, telepon, website, ...) memindahkan SELURUH permintaan ke SKU yang lebih mahal dengan
  jatah gratis 1.000/bulan (bukan 5.000). Field itu hanya diminta kalau PLACES_GOOGLE_RATING_HOURS=true.
* API key dikirim lewat header (bukan URL) supaya tidak masuk log proxy/server mana pun.
* Tempat yang `businessStatus`-nya tutup (sementara/permanen) atau belum buka dibuang.
"""
from __future__ import annotations

import asyncio
import logging
import math
from typing import Any, Dict, List, Optional, Tuple

import httpx

from ..categories import Category
from ..config import Settings
from ..geo import in_range
from .base import BaseProvider, Budget, Place, PlacesError

log = logging.getLogger("driving_buddy.places")

MAX_RETRY_AFTER_S = 2.0
BACKOFF_S = 0.3
FETCH_COUNT = 20  # maksimum Google. Biaya per permintaan, bukan per hasil, jadi selalu ambil penuh (cache tidak peduli `limit`).
MAX_RADIUS_M = 50000.0

# Semua field di bawah termasuk tier "Nearby Search Pro".
FIELDS_PRO = (
    "places.id",
    "places.displayName",
    "places.formattedAddress",
    "places.location",
    "places.googleMapsUri",
    "places.businessStatus",
    "places.primaryType",
)
# Field tier "Nearby Search Enterprise" (lebih mahal, jatah gratis 1.000/bulan).
FIELDS_RATING_HOURS = ("places.rating", "places.currentOpeningHours")

_NOT_OPEN = ("CLOSED_PERMANENTLY", "CLOSED_TEMPORARILY", "FUTURE_OPENING")

_AUTH_REASONS = {
    "API_KEY_INVALID", "API_KEY_SERVICE_BLOCKED", "API_KEY_HTTP_REFERRER_BLOCKED", "API_KEY_IP_ADDRESS_BLOCKED",
    "API_KEY_ANDROID_APP_BLOCKED", "API_KEY_IOS_APP_BLOCKED", "SERVICE_DISABLED", "BILLING_DISABLED",
    "CONSUMER_INVALID", "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
}


class GooglePlacesProvider(BaseProvider):
    name = "google"
    max_concurrency = 3

    def __init__(self, settings: Settings, http: Optional[httpx.AsyncClient] = None):
        self.settings = settings
        self._http = http
        self._owns_http = http is None
        fields = FIELDS_PRO + (FIELDS_RATING_HOURS if settings.google_rating_hours else ())
        self._field_mask = ",".join(fields)

    # -- API publik ---------------------------------------------------------
    async def search(self, category: Category, lat: float, lng: float, radius_m: int,
                     budget: Budget) -> List[Place]:
        body = self._build_body(category, lat, lng, radius_m)
        data = await self._post(body, budget)
        return self._parse(data)

    async def aclose(self) -> None:
        if self._http is not None and self._owns_http:
            await self._http.aclose()
            self._http = None

    # -- internal -----------------------------------------------------------
    def _client(self) -> httpx.AsyncClient:
        if self._http is None:
            self._http = httpx.AsyncClient(
                timeout=httpx.Timeout(self.settings.timeout_s, connect=min(3.0, self.settings.timeout_s)),
                limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
            )
        return self._http

    def _headers(self) -> Dict[str, str]:
        return {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "driving-buddy-places/1.0",
            "X-Goog-Api-Key": self.settings.google_api_key,
            "X-Goog-FieldMask": self._field_mask,
        }

    def _build_body(self, category: Category, lat: float, lng: float, radius_m: int) -> Dict[str, Any]:
        types = self.settings.google_types.get(category.key) or category.google_types
        return {
            "includedTypes": list(types),
            "maxResultCount": FETCH_COUNT,
            "rankPreference": "DISTANCE",
            "languageCode": self.settings.language,
            "regionCode": self.settings.region,
            "locationRestriction": {
                "circle": {
                    "center": {"latitude": round(lat, 6), "longitude": round(lng, 6)},
                    "radius": float(min(max(radius_m, 1), MAX_RADIUS_M)),
                }
            },
        }

    async def _post(self, body: Dict[str, Any], budget: Budget) -> Dict[str, Any]:
        retries = 0
        while True:
            budget.take()  # setiap percobaan HTTP dihitung, retry juga
            try:
                return await self._once(body)
            except PlacesError as err:
                if retries < self.settings.max_retries and self._retryable(err):
                    retries += 1
                    await asyncio.sleep(self._delay(err))
                    continue
                raise

    async def _once(self, body: Dict[str, Any]) -> Dict[str, Any]:
        url = f"{self.settings.google_base_url}/places:searchNearby"
        timeout = self.settings.timeout_s
        try:
            resp = await asyncio.wait_for(
                self._client().post(url, json=body, headers=self._headers()), timeout=timeout
            )
        except (asyncio.TimeoutError, httpx.TimeoutException):
            raise PlacesError("timeout", f"tidak ada balasan dalam {timeout:g} detik") from None
        except httpx.HTTPError as exc:
            raise PlacesError("network", self._redact(f"{type(exc).__name__}: {exc}")[:200]) from None
        if resp.status_code != 200:
            raise self._http_error(resp)
        try:
            data = resp.json()
        except ValueError:
            raise PlacesError("bad_response", "balasan bukan JSON", status=resp.status_code) from None
        if not isinstance(data, dict):
            raise PlacesError("bad_response", "format balasan tidak dikenal", status=resp.status_code)
        return data

    def _redact(self, text: str) -> str:
        key = self.settings.google_api_key
        return text.replace(key, "***") if key else text

    def _http_error(self, resp: httpx.Response) -> PlacesError:
        message, g_status, reason = _error_info(resp)
        message = self._redact(message)
        status = resp.status_code
        if status == 429 or g_status == "RESOURCE_EXHAUSTED":
            kind = "rate_limited"
        elif status in (401, 403) or reason in _AUTH_REASONS or (status == 400 and "api key" in message.lower()):
            # Google membalas key yang salah dengan HTTP 400 (reason API_KEY_INVALID), bukan 401.
            kind = "auth"
        elif status >= 500:
            kind = "upstream"
        else:
            kind = "bad_request"
        return PlacesError(kind, message or f"HTTP {status}", status=status, retry_after=_retry_after(resp),
                           hint=_hint(kind, reason, message))

    @staticmethod
    def _retryable(err: PlacesError) -> bool:
        # Timeout sengaja tidak diulang: pengemudi tidak boleh menunggu 2x batas waktu.
        if err.kind in ("network", "upstream", "bad_response"):
            return True
        if err.kind == "rate_limited":
            return err.retry_after is not None and err.retry_after <= MAX_RETRY_AFTER_S
        return False

    @staticmethod
    def _delay(err: PlacesError) -> float:
        if err.retry_after is not None:
            return min(max(err.retry_after, 0.0), MAX_RETRY_AFTER_S)
        return BACKOFF_S

    def _parse(self, data: Dict[str, Any]) -> List[Place]:
        items = data.get("places")
        if items is None:  # tidak ada hasil: Google menghilangkan field `places`
            return []
        if not isinstance(items, list):
            raise PlacesError("bad_response", "'places' bukan daftar")
        places: List[Place] = []
        for item in items:
            place = _parse_place(item)
            if place is not None:
                places.append(place)
        return places


# ---------------------------------------------------------------------------
def _parse_place(item: Any) -> Optional[Place]:
    if not isinstance(item, dict):
        return None
    if str(item.get("businessStatus") or "") in _NOT_OPEN:
        return None
    loc = item.get("location")
    if not isinstance(loc, dict):
        return None
    lat, lng = loc.get("latitude"), loc.get("longitude")
    if isinstance(lat, bool) or isinstance(lng, bool) or not isinstance(lat, (int, float)) \
            or not isinstance(lng, (int, float)) or not in_range(float(lat), float(lng)):
        return None
    place_id = str(item.get("id") or "")
    if not place_id:
        return None
    display = item.get("displayName")
    name = str(display.get("text") or "") if isinstance(display, dict) else ""

    open_now: Optional[bool] = None
    hours = item.get("currentOpeningHours")
    if isinstance(hours, dict) and isinstance(hours.get("openNow"), bool):
        open_now = hours["openNow"]
    rating = item.get("rating")
    rating = float(rating) if isinstance(rating, (int, float)) and not isinstance(rating, bool) \
        and math.isfinite(rating) else None

    return Place(
        id=place_id,
        name=name.strip(),
        lat=float(lat),
        lng=float(lng),
        address=str(item.get("formattedAddress") or "").strip(),
        provider_type=str(item.get("primaryType") or ""),
        open_now=open_now,
        rating=rating,
        maps_url=str(item.get("googleMapsUri") or ""),
    )


def _error_info(resp: httpx.Response) -> Tuple[str, str, str]:
    """(pesan, status Google, reason) dari body error Google."""
    try:
        body: Any = resp.json()
    except ValueError:
        return resp.text[:200], "", ""
    if isinstance(body, list) and body:
        body = body[0]
    err = body.get("error") if isinstance(body, dict) else None
    if not isinstance(err, dict):
        return str(body)[:200], "", ""
    reason = ""
    for detail in err.get("details") or []:
        if isinstance(detail, dict) and detail.get("reason"):
            reason = str(detail["reason"])
            break
    return str(err.get("message") or "")[:300], str(err.get("status") or ""), reason


def _retry_after(resp: httpx.Response) -> Optional[float]:
    raw = resp.headers.get("retry-after")
    if raw:
        try:
            return max(0.0, float(raw))
        except ValueError:
            return None
    return None


def _hint(kind: str, reason: str, message: str) -> Optional[str]:
    """Saran perbaikan untuk error Google yang paling sering dialami saat pertama kali setup."""
    low = message.lower()
    if reason == "API_KEY_INVALID" or "api key not valid" in low:
        return "Google tidak mengenali API key ini: salah salin, atau key sudah dihapus."
    if reason == "SERVICE_DISABLED" or "has not been used" in low or "is disabled" in low:
        return "Places API (New) belum di-enable di project Google Cloud ini (bukan 'Places API' yang lama)."
    if reason == "BILLING_DISABLED" or "billing" in low:
        return "Billing belum aktif di project Google Cloud ini (wajib walau pakai jatah gratis)."
    if reason == "API_KEY_SERVICE_BLOCKED" or ("blocked" in low and "api" in low):
        return "Key ini dibatasi (API restrictions) dan Places API (New) tidak ada di daftar yang diizinkan."
    if reason == "API_KEY_IP_ADDRESS_BLOCKED" or "ip address" in low:
        return "IP server ini tidak ada di daftar IP yang diizinkan untuk key. Key server dibatasi dengan IP address."
    if reason in ("API_KEY_HTTP_REFERRER_BLOCKED", "API_KEY_ANDROID_APP_BLOCKED", "API_KEY_IOS_APP_BLOCKED"):
        return ("Key ini dibatasi untuk website/aplikasi HP. Key untuk server tidak boleh dibatasi Android/iOS/HTTP "
                "referrer; pakai batasan IP address atau tanpa batasan aplikasi selama development.")
    if kind == "rate_limited":
        return "Kuota Google (quota cap) untuk project ini habis atau terlalu banyak permintaan sekaligus."
    return None
