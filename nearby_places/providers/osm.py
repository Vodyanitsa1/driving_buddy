"""OpenStreetMap lewat Overpass API (gratis, tanpa API key, tanpa kartu kredit).

Cocok untuk demo dan pengembangan. BUKAN untuk rilis: server publik overpass-api.de membatasi pemakaian
rutin sekitar 100 query/hari dan meminta aplikasi komersial memakai server sendiri/berbayar
(https://wiki.openstreetmap.org/wiki/Overpass_API). Hal yang dijaga di sini:

* User-Agent unik (diwajibkan kebijakan mereka) dan permintaan dikirim sebagai POST.
* HTTP 429/406 -> server itu tidak dipanggil selama 30 detik (anjuran resmi), tanpa menunggu di depan pengemudi.
* Overpass membalas kegagalan query (timeout/memori) dengan HTTP 200 + field `remark`. Itu dianggap error,
  bukan "tidak ada tempat".
* `out center N` memotong hasil berdasarkan ID, BUKAN jarak. Kalau jumlah hasil menyentuh batas N, radius
  dipersempit dan query diulang, supaya tempat terdekat tidak hilang diam-diam.

Tambahan v2:

* Failover: PLACES_OSM_URL boleh berisi beberapa server. Kalau satu timeout/5xx/putus, server berikutnya dicoba
  (berurutan, tidak paralel), dalam batas total PLACES_OSM_DEADLINE_S. Server yang baru gagal ditaruh di
  belakang selama 20 detik; server yang terakhir berhasil dicoba duluan.
* Transport curl: Python bawaan macOS (LibreSSL 2.8.3) gagal handshake TLS ke overpass-api.de. Di mode `auto`,
  kalau httpx gagal karena TLS, permintaan yang sama diulang lewat program `curl` (memakai TLS milik sistem),
  dan server itu seterusnya lewat curl (juga kalau percobaan curl pertama itu gagal karena server sibuk).
"""
from __future__ import annotations

import asyncio
import json
import logging
import math
import re
import shutil
import ssl
import time
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple
from urllib.parse import urlencode, urlparse

import httpx

from ..categories import Category
from ..config import Settings
from ..geo import in_range
from .base import BaseProvider, Budget, Place, PlacesError

log = logging.getLogger("driving_buddy.places")

ELEMENT_CAP = 300  # maksimal elemen per query
MAX_SHRINKS = 3  # berapa kali radius boleh dipersempit kalau hasil menyentuh ELEMENT_CAP
MIN_SHRINK_RADIUS_M = 500
BLOCK_S = 30.0  # jeda setelah 429/406 (per server)
COOLDOWN_S = 20.0  # server yang baru gagal ditaruh di urutan belakang selama ini
MIN_ATTEMPT_S = 1.0  # sisa waktu di bawah ini: jangan mulai percobaan baru
FAILOVER_KINDS = ("timeout", "upstream", "network", "bad_response", "rate_limited")
CURL_EXIT_TIMEOUT = 28

HINT_TLS = ("Python server memakai LibreSSL lama (bawaan macOS) yang gagal TLS ke server ini; pakai Python "
            "berbasis OpenSSL (python.org/Homebrew) atau set PLACES_OSM_TRANSPORT=curl")
HINT_CAPACITY = "server Overpass penuh (at capacity); coba server lain di PLACES_OSM_URL atau tunggu beberapa menit"
HINT_NO_CURL = "program curl tidak ditemukan di PATH server; pasang curl atau pakai Python berbasis OpenSSL"

_SSL_WORDS = ("ssl", "tls", "handshake", "certificate")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]+")
_URL_QUERY_RE = re.compile(r"(https?://[^\s?#]+)[?#]\S*", re.I)
_SECRET_RE = re.compile(r"((?:api_?key|key|token)=)[^&\s]+", re.I)


def host_of(url: str) -> str:
    return urlparse(url).netloc or url


def sanitize(text: str, limit: int = 200) -> str:
    """Untuk log dan /places/health: buang karakter kontrol, query string URL, dan nilai key/token."""
    text = _CONTROL_RE.sub(" ", str(text or ""))
    text = _SECRET_RE.sub(r"\1***", _URL_QUERY_RE.sub(r"\1?***", text))
    return text.strip()[:limit]


def is_tls_error(exc: BaseException) -> bool:
    """True kalau kegagalan httpx berasal dari TLS/SSL (rantai sebab berisi ssl.SSLError, atau pesannya)."""
    seen = set()
    cur: Optional[BaseException] = exc
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        if isinstance(cur, ssl.SSLError):
            return True
        if any(word in str(cur).lower() for word in _SSL_WORDS):
            return True
        cur = cur.__cause__ or cur.__context__
    return False


class _Raw:
    """Balasan mentah dari salah satu transport (httpx atau curl)."""
    __slots__ = ("status", "body")

    def __init__(self, status: int, body: bytes):
        self.status = status
        self.body = body

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", "replace")


Runner = Callable[[Sequence[str], bytes, float], Any]  # async (argv, stdin, timeout) -> (returncode, stdout, stderr)


async def run_subprocess(argv: Sequence[str], stdin: bytes, timeout: float) -> Tuple[int, bytes, bytes]:
    """Jalankan program TANPA shell. Proses dimatikan kalau melewati batas waktu atau request dibatalkan."""
    proc = await asyncio.create_subprocess_exec(
        *argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(stdin), timeout=timeout)
    except BaseException:  # timeout ATAU dibatalkan (CancelledError): jangan tinggalkan proses yatim
        if proc.returncode is None:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(proc.wait(), timeout=2)
            except BaseException:
                pass
        raise
    return proc.returncode if proc.returncode is not None else -1, out, err


class OverpassProvider(BaseProvider):
    name = "osm"
    max_concurrency = 1

    def __init__(self, settings: Settings, http: Optional[httpx.AsyncClient] = None,
                 clock: Callable[[], float] = time.monotonic, runner: Optional[Runner] = None,
                 which: Callable[[str], Optional[str]] = shutil.which):
        self.settings = settings
        self._http = http
        self._owns_http = http is None
        self._clock = clock
        self._runner: Runner = runner or run_subprocess
        self._which = which
        urls = tuple(settings.osm_urls) or (settings.osm_url,)
        if settings.osm_url and settings.osm_url not in urls:  # Settings dibuat manual dengan osm_url saja
            urls = (settings.osm_url,)
        self.urls: Tuple[str, ...] = urls
        self._blocked_until: Dict[str, float] = {}  # url -> waktu boleh dipanggil lagi (429/406)
        self._failed_at: Dict[str, float] = {}  # url -> waktu gagal terakhir
        self._last_ok: Optional[str] = None
        self._use_curl: Dict[str, bool] = {}  # url -> lengket pakai curl (mode auto setelah gagal TLS)

    # -- API publik ---------------------------------------------------------
    async def search(self, category: Category, lat: float, lng: float, radius_m: int,
                     budget: Budget) -> List[Place]:
        self._raise_if_all_blocked()
        radius = radius_m
        elements: List[Dict[str, Any]] = []
        for attempt in range(MAX_SHRINKS + 1):
            elements = await self._query(category, lat, lng, radius, budget)
            if len(elements) < ELEMENT_CAP:
                break
            if radius <= MIN_SHRINK_RADIUS_M or attempt == MAX_SHRINKS:
                log.warning("[PLACES] osm: area sangat padat, hasil terpotong (bisa jadi bukan yang terdekat)")
                break
            radius = max(MIN_SHRINK_RADIUS_M, radius // 2)
        places = [p for p in (_to_place(e, category) for e in elements) if p is not None]
        return places

    async def aclose(self) -> None:
        if self._http is not None and self._owns_http:
            await self._http.aclose()
            self._http = None

    # -- urutan server ------------------------------------------------------
    def _raise_if_all_blocked(self) -> None:
        now = self._clock()
        waits = [self._blocked_until.get(u, 0.0) - now for u in self.urls]
        if all(w > 0 for w in waits):
            wait = min(waits)
            raise PlacesError("rate_limited", f"Overpass minta jeda, coba lagi dalam {math.ceil(wait)} detik",
                              retry_after=wait)

    def _ordered_urls(self) -> List[str]:
        """Lewati yang sedang dijeda (429/406). Yang sehat dulu, yang terakhir berhasil paling depan."""
        now = self._clock()
        usable = [u for u in self.urls if self._blocked_until.get(u, 0.0) <= now]

        def key(item: Tuple[int, str]) -> Tuple[int, int, int]:
            index, url = item
            failed = self._failed_at.get(url)
            recently_failed = failed is not None and now - failed < COOLDOWN_S
            return (1 if recently_failed else 0, 0 if url == self._last_ok else 1, index)

        return [u for _, u in sorted(enumerate(usable), key=key)]

    # -- internal -----------------------------------------------------------
    def _client(self) -> httpx.AsyncClient:
        if self._http is None:
            self._http = httpx.AsyncClient(
                timeout=httpx.Timeout(self.settings.osm_timeout_s, connect=min(5.0, self.settings.osm_timeout_s)),
                limits=httpx.Limits(max_connections=2, max_keepalive_connections=1),
            )
        return self._http

    def _headers(self) -> Dict[str, str]:
        return {"User-Agent": self.settings.osm_user_agent, "Accept": "application/json"}

    async def _query(self, category: Category, lat: float, lng: float, radius: int,
                     budget: Budget) -> List[Dict[str, Any]]:
        self._raise_if_all_blocked()
        urls = self._ordered_urls()
        started = self._clock()
        deadline = max(self.settings.osm_deadline_s, MIN_ATTEMPT_S)
        failures: List[Tuple[str, PlacesError]] = []
        for url in urls:
            remaining = deadline - (self._clock() - started)
            if failures and remaining < MIN_ATTEMPT_S:
                break
            timeout = max(MIN_ATTEMPT_S, min(self.settings.osm_timeout_s, remaining))
            query = build_query(category, lat, lng, radius, max(2, int(timeout) - 2), ELEMENT_CAP)
            budget.take()  # sekali per percobaan HTTP; budget_exhausted langsung naik, tanpa failover
            try:
                elements = await self._attempt(url, query, timeout)
            except PlacesError as err:
                if err.kind == "rate_limited":
                    self._blocked_until[url] = self._clock() + BLOCK_S
                else:
                    self._failed_at[url] = self._clock()
                if err.kind not in FAILOVER_KINDS:
                    raise
                failures.append((url, err))
                if len(self.urls) > 1:
                    log.warning("[PLACES] osm %s gagal (%s): %s", host_of(url), err.kind, sanitize(err.detail, 160))
                continue
            self._last_ok = url
            self._failed_at.pop(url, None)
            return elements

        if not failures:  # tidak ada server yang sempat dicoba (seharusnya sudah ditangani di atas)
            raise PlacesError("rate_limited", "semua server Overpass sedang dijeda", retry_after=BLOCK_S)
        first = failures[0][1]
        if len(failures) > 1:
            extra = ", ".join(f"{host_of(u)}: {e.kind}" for u, e in failures[1:])
            first.detail = sanitize(f"{first.detail} | cadangan: {extra}", 300)
            first.hint = first.hint or next((e.hint for _, e in failures if e.hint), None)
        if first.kind == "rate_limited":
            first.retry_after = min((e.retry_after or BLOCK_S) for _, e in failures if e.kind == "rate_limited")
        raise first

    async def _attempt(self, url: str, query: str, timeout: float) -> List[Dict[str, Any]]:
        mode = self.settings.osm_transport
        if mode == "curl" or self._use_curl.get(url):
            raw = await self._post_curl(url, query, timeout)
        else:
            try:
                raw = await self._post_httpx(url, query, timeout)
            except _TlsFailure as tls:
                if mode != "auto":
                    raise PlacesError("network", tls.detail, hint=HINT_TLS) from None
                # Permintaan tadi tidak sampai ke Overpass (gagal saat handshake), jadi jatah tidak dipotong lagi.
                # TLS Python yang gagal sekali akan gagal terus (versi OpenSSL/LibreSSL-nya), jadi server ini langsung
                # lengket ke curl, walaupun percobaan curl di bawah gagal karena server sedang sibuk.
                log.warning("[PLACES] osm %s: TLS Python gagal (%s), dicoba ulang lewat curl; seterusnya server ini "
                            "lewat curl", host_of(url), sanitize(tls.detail, 120))
                if self._which("curl"):
                    self._use_curl[url] = True
                raw = await self._post_curl(url, query, timeout)
        return self._parse(raw)

    async def _post_httpx(self, url: str, query: str, timeout: float) -> _Raw:
        try:
            resp = await asyncio.wait_for(
                self._client().post(url, data={"data": query}, headers=self._headers(),
                                    timeout=httpx.Timeout(timeout, connect=min(5.0, timeout))),
                timeout=timeout,
            )
        except (asyncio.TimeoutError, httpx.TimeoutException):
            raise PlacesError("timeout", f"tidak ada balasan dalam {timeout:g} detik") from None
        except httpx.HTTPError as exc:
            detail = sanitize(f"{type(exc).__name__}: {exc}")
            if is_tls_error(exc):
                raise _TlsFailure(detail) from None
            raise PlacesError("network", detail) from None
        return _Raw(resp.status_code, resp.content)

    def _curl_argv(self, curl: str, url: str, timeout: float) -> List[str]:
        agent = _CONTROL_RE.sub(" ", self.settings.osm_user_agent).strip()
        return [
            curl, "-q", "-sS",
            "--max-time", f"{timeout:g}",
            "--connect-timeout", f"{min(5.0, timeout):g}",
            "--proto", "=http,https",
            "-A", agent,
            "-H", "Accept: application/json",
            "-H", "Content-Type: application/x-www-form-urlencoded",
            "--data-binary", "@-",
            "-w", "\n%{http_code}",
            url,
        ]

    async def _post_curl(self, url: str, query: str, timeout: float) -> _Raw:
        curl = self._which("curl")
        if not curl:
            raise PlacesError("network", "curl tidak ditemukan", hint=HINT_NO_CURL)
        body = urlencode({"data": query}).encode()
        try:
            code, out, err = await self._runner(self._curl_argv(curl, url, timeout), body, timeout + 2)
        except asyncio.TimeoutError:
            raise PlacesError("timeout", f"tidak ada balasan dalam {timeout:g} detik (curl)") from None
        except OSError as exc:
            raise PlacesError("network", sanitize(f"curl tidak bisa dijalankan: {exc}"), hint=HINT_NO_CURL) from None
        if code == CURL_EXIT_TIMEOUT:
            raise PlacesError("timeout", f"tidak ada balasan dalam {timeout:g} detik (curl)")
        if code != 0:
            msg = sanitize(err.decode("utf-8", "replace"), 150) or f"exit {code}"
            raise PlacesError("network", f"curl exit {code}: {msg}")
        payload, _, status_line = out.rpartition(b"\n")
        try:
            status = int(status_line.strip())
        except ValueError:
            raise PlacesError("bad_response", "curl tidak mengembalikan kode HTTP") from None
        return _Raw(status, payload)

    def _parse(self, raw: _Raw) -> List[Dict[str, Any]]:
        status = raw.status
        if status in (429, 406):
            raise PlacesError("rate_limited", f"Overpass menolak (HTTP {status}); jeda {BLOCK_S:g} detik",
                              status=status, retry_after=BLOCK_S)
        if status >= 500:
            capacity = "at capacity" in raw.text[:2000].lower()
            raise PlacesError("upstream", f"HTTP {status} (server Overpass {'penuh' if capacity else 'sibuk'})",
                              status=status, hint=HINT_CAPACITY if capacity else None)
        if status != 200:
            raise PlacesError("bad_request", sanitize(f"HTTP {status}: {raw.text[:160]}"), status=status)
        try:
            data = json.loads(raw.body)
        except ValueError:
            raise PlacesError("bad_response", "balasan bukan JSON", status=status) from None
        if not isinstance(data, dict):
            raise PlacesError("bad_response", "format balasan tidak dikenal", status=status)

        remark = str(data.get("remark") or "")
        if "runtime error" in remark.lower():  # HTTP 200 tapi query gagal
            low = remark.lower()
            kind = "timeout" if "timed out" in low else "upstream"
            raise PlacesError(kind, remark[:200], status=status)
        elements = data.get("elements")
        if not isinstance(elements, list):
            raise PlacesError("bad_response", "balasan tidak punya 'elements'", status=status)
        return [e for e in elements if isinstance(e, dict)]


class _TlsFailure(Exception):
    def __init__(self, detail: str):
        super().__init__(detail)
        self.detail = detail


# ---------------------------------------------------------------------------
def _tag_filter(key: str, values: Tuple[str, ...]) -> str:
    if len(values) == 1:
        return f'["{key}"="{values[0]}"]'
    return f'["{key}"~"^({"|".join(values)})$"]'


def build_query(category: Category, lat: float, lng: float, radius_m: int, server_timeout_s: int, cap: int) -> str:
    """Query Overpass QL: node + way (way mengembalikan titik tengah lewat `out center`)."""
    around = f"(around:{int(radius_m)},{lat:.6f},{lng:.6f})"
    lines = []
    for key, values in category.osm_filters:
        flt = _tag_filter(key, values)
        lines.append(f"  node{flt}{around};")
        lines.append(f"  way{flt}{around};")
    body = "\n".join(lines)
    return f"[out:json][timeout:{server_timeout_s}];\n(\n{body}\n);\nout center {cap};"


def _to_place(element: Dict[str, Any], category: Category) -> Optional[Place]:
    kind, oid = element.get("type"), element.get("id")
    if kind not in ("node", "way", "relation") or oid is None:
        return None
    if kind == "node":
        lat, lng = element.get("lat"), element.get("lon")
    else:
        center = element.get("center")
        lat, lng = (center.get("lat"), center.get("lon")) if isinstance(center, dict) else (None, None)
    if isinstance(lat, bool) or isinstance(lng, bool) or not isinstance(lat, (int, float)) \
            or not isinstance(lng, (int, float)) or not in_range(float(lat), float(lng)):
        return None
    tags = element.get("tags")
    tags = tags if isinstance(tags, dict) else {}
    name = ""
    for key in ("name", "name:id", "brand", "operator"):
        if tags.get(key):
            name = str(tags[key]).strip()
            break
    if _excluded(category, tags):
        return None
    provider_type = ""
    for key, values in category.osm_filters:
        if tags.get(key) in values:
            provider_type = f"{key}={tags[key]}"
            break
    return Place(
        id=f"osm:{kind}/{oid}",
        name=name,
        lat=float(lat),
        lng=float(lng),
        address=_address(tags),
        provider_type=provider_type,
        maps_url=f"https://www.openstreetmap.org/{kind}/{oid}",
    )


def _excluded(category: Category, tags: Dict[str, Any]) -> bool:
    """Cocok tag kategori tapi jelas bukan kategori itu (salah tag di OSM), mis. bengkel bertanda highway=services."""
    for key, values in category.osm_exclude_tags:
        if tags.get(key) in values:
            return True
    if not category.osm_exclude_names:
        return False
    text = " ".join(str(tags.get(key) or "") for key in ("name", "name:id", "brand", "operator"))
    return re.search(category.osm_exclude_names, text, re.I) is not None


def _address(tags: Dict[str, Any]) -> str:
    full = str(tags.get("addr:full") or "").strip()
    if full:
        return full
    street = str(tags.get("addr:street") or "").strip()
    number = str(tags.get("addr:housenumber") or "").strip()
    parts = [" ".join(p for p in (street, number) if p)]
    for keys in (("addr:suburb", "addr:village", "addr:subdistrict", "addr:district"), ("addr:city", "addr:town")):
        for key in keys:
            if tags.get(key):
                parts.append(str(tags[key]).strip())
                break
    return ", ".join(p for p in parts if p)
