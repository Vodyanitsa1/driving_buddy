"""Konfigurasi modul tempat terdekat.

Semua pengaturan dibaca dari environment variable. Kalau ada file `.env` (di folder kerja atau di
root repo), isinya ikut dibaca; environment variable yang sudah ada selalu menang atas isi file.

Modul ini TIDAK PERNAH melempar error karena salah konfigurasi. Masalahnya dicatat di
`Settings.problem` supaya deteksi kantuk (server.py) tetap jalan walaupun fitur ini belum siap.
"""
from __future__ import annotations

import logging
import math
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple
from urllib.parse import urlparse

from .categories import CATEGORIES

log = logging.getLogger("driving_buddy.places")

PROVIDERS = ("google", "osm", "snapshot", "mock")
FALLBACK_PROVIDERS = ("osm", "snapshot")

GOOGLE_BASE_URL = "https://places.googleapis.com/v1"
OSM_URL = "https://overpass-api.de/api/interpreter"
OSM_USER_AGENT = "driving-buddy-places/1.0 (student capstone project)"
OSM_TRANSPORTS = ("auto", "httpx", "curl")
SNAPSHOT_FILE = "places_snapshot.json"

# 4.500 = 90% dari jatah gratis Nearby Search Pro (5.000/bulan). Kalau rating & jam buka diminta, Google
# menagih tier Enterprise yang jatah gratisnya hanya 1.000/bulan, jadi bawaannya turun ke 900.
DEFAULT_MONTHLY_BUDGET_PRO = 4500
DEFAULT_MONTHLY_BUDGET_ENTERPRISE = 900
DEFAULT_DAILY_BUDGET = 300

_REPO_ROOT = Path(__file__).resolve().parent.parent
_LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1", "[::1]")
_TYPE_RE = re.compile(r"^[a-z][a-z0-9_]*$")


def _default_google_types() -> Dict[str, Tuple[str, ...]]:
    return {key: cat.google_types for key, cat in CATEGORIES.items()}


@dataclass(frozen=True)
class Settings:
    provider: str = "mock"
    fallback_provider: str = ""  # "" = tanpa cadangan
    google_api_key: str = field(default="", repr=False)  # jangan pernah tampil di log/repr
    google_base_url: str = GOOGLE_BASE_URL
    google_rating_hours: bool = False  # minta rating + buka/tutup (tier Enterprise, lebih mahal)
    google_types: Mapping[str, Tuple[str, ...]] = field(default_factory=_default_google_types)
    osm_url: str = OSM_URL  # = osm_urls[0], dipertahankan untuk kode/tes lama
    osm_urls: Tuple[str, ...] = (OSM_URL,)  # dicoba berurutan kalau server sebelumnya gagal (failover)
    osm_user_agent: str = OSM_USER_AGENT
    osm_timeout_s: float = 8.0  # batas satu percobaan ke satu server
    osm_deadline_s: float = 20.0  # batas total semua percobaan (semua server) untuk satu query
    osm_transport: str = "auto"  # auto = httpx, pindah ke curl kalau TLS Python gagal | httpx | curl
    language: str = "id"
    region: str = "ID"
    timeout_s: float = 4.0
    max_retries: int = 1
    max_radius_m: int = 50000
    cache_ttl_s: float = 90.0
    cache_tolerance_m: float = 250.0
    cache_max_entries: int = 200
    stale_ttl_s: float = 21600.0  # hasil lama boleh dipakai kalau provider gagal, sampai umur ini (0 = mati)
    stale_cache_file: Optional[str] = None  # None = cache basi hanya di memori (hilang saat server restart)
    snapshot_file: Optional[str] = None  # data OSM offline (balasan Overpass JSON) untuk provider snapshot
    rate_per_client_per_min: int = 20
    rate_global_per_min: int = 120
    google_daily_budget: int = DEFAULT_DAILY_BUDGET
    google_monthly_budget: int = DEFAULT_MONTHLY_BUDGET_PRO
    osm_daily_budget: int = 500
    usage_file: Optional[str] = None  # None = hitungan pemakaian hanya di memori
    tz_offset_hours: float = 7.0  # batas hari/bulan hitungan pemakaian (WIB)
    problem: Optional[str] = None  # None = siap dipakai
    notes: Tuple[str, ...] = ()  # peringatan non-fatal untuk ditampilkan di /places/health

    @property
    def configured(self) -> bool:
        return self.problem is None

    @property
    def google_host(self) -> str:
        return urlparse(self.google_base_url).netloc

    def budget_for(self, provider: str) -> Tuple[int, int]:
        """(batas harian, batas bulanan) panggilan ke provider itu. 0 = tanpa batas."""
        if provider == "google":
            return self.google_daily_budget, self.google_monthly_budget
        if provider == "osm":
            return self.osm_daily_budget, 0
        return 0, 0


# ---------------------------------------------------------------------------
# Membaca environment
# ---------------------------------------------------------------------------
def parse_env_file(path: Path) -> Dict[str, str]:
    """Parser .env sederhana: KEY=VALUE, komentar '#', tanda kutip opsional."""
    values: Dict[str, str] = {}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return values
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        elif " #" in val:
            val = val.split(" #", 1)[0].rstrip()
        if key:
            values[key] = val
    return values


def _collect_env(environ: Optional[Mapping[str, str]], env_file: Optional[str]) -> Dict[str, str]:
    base = dict(os.environ) if environ is None else dict(environ)
    explicit = env_file or base.get("PLACES_ENV_FILE")
    if explicit:
        candidates = [Path(explicit)]
    elif environ is None:
        candidates = [Path.cwd() / ".env", _REPO_ROOT / ".env"]
    else:
        candidates = []  # environ disuntik manual (tes) -> jangan baca file apa pun
    merged: Dict[str, str] = {}
    for candidate in candidates:
        if candidate.is_file():
            merged.update(parse_env_file(candidate))
            break
    merged.update(base)  # environment asli menang atas isi file
    return {k: str(v).strip() for k, v in merged.items() if v is not None and str(v).strip() != ""}


def _number(env: Mapping[str, str], name: str, default, lo, hi, cast: Callable, notes: List[str]):
    raw = env.get(name)
    if raw is None:
        return default
    try:
        value = cast(raw)
    except ValueError:
        notes.append(f"{name}='{raw}' bukan angka valid, dipakai default {default}")
        return default
    if isinstance(value, float) and not math.isfinite(value):
        notes.append(f"{name}='{raw}' tidak valid, dipakai default {default}")
        return default
    if not lo <= value <= hi:
        clamped = min(max(value, lo), hi)
        notes.append(f"{name}={value} di luar batas [{lo}, {hi}], dipakai {clamped}")
        return clamped
    return value


def _flag(env: Mapping[str, str], name: str, default: bool, notes: List[str]) -> bool:
    raw = env.get(name)
    if raw is None:
        return default
    low = raw.lower()
    if low in ("1", "true", "yes", "ya", "on"):
        return True
    if low in ("0", "false", "no", "tidak", "off"):
        return False
    notes.append(f"{name}='{raw}' bukan true/false, dipakai default {str(default).lower()}")
    return default


def _type_overrides(env: Mapping[str, str], notes: List[str]) -> Dict[str, Tuple[str, ...]]:
    types = _default_google_types()
    for key in CATEGORIES:
        name = "PLACES_GOOGLE_TYPES_" + key.upper()
        raw = env.get(name)
        if raw is None:
            continue
        items = tuple(dict.fromkeys(t.strip().lower() for t in raw.split(",") if t.strip()))
        if not items or len(items) > 50 or not all(_TYPE_RE.match(t) for t in items):
            notes.append(f"{name}='{raw}' tidak valid (daftar tipe Google dipisah koma, maksimal 50), "
                         f"dipakai bawaan {','.join(types[key])}")
            continue
        types[key] = items
    return types


def _osm_urls(raw: str) -> Tuple[Tuple[str, ...], List[str]]:
    """PLACES_OSM_URL boleh berisi beberapa alamat dipisah koma/spasi. Return (yang valid, yang tidak valid)."""
    items = [u.strip() for u in re.split(r"[,\s]+", raw or "") if u.strip()] or [OSM_URL]
    good: List[str] = []
    bad: List[str] = []
    for url in items:
        parsed = urlparse(url)
        if parsed.scheme in ("http", "https") and parsed.netloc:
            if url not in good:
                good.append(url)
        else:
            bad.append(url)
    return tuple(good), bad


def _off_or_path(raw: str) -> Optional[str]:
    if not raw or raw.lower() in ("off", "none", "no", "false", "-"):
        return None
    return raw


# ---------------------------------------------------------------------------
def load_settings(environ: Optional[Mapping[str, str]] = None, env_file: Optional[str] = None) -> Settings:
    """Bangun Settings dari environment. `environ` hanya dipakai untuk tes."""
    env = _collect_env(environ, env_file)
    notes: List[str] = []
    problems: List[str] = []

    api_key = env.get("GOOGLE_PLACES_API_KEY", "")
    provider = env.get("PLACES_PROVIDER", "").lower()
    if not provider:
        if api_key and not api_key.startswith("YOUR_"):
            provider = "google"
            notes.append("PLACES_PROVIDER kosong, dipakai 'google' karena GOOGLE_PLACES_API_KEY terisi")
        else:
            provider = "mock"
            notes.append("PLACES_PROVIDER dan API key belum diisi, jalan di mode MOCK (tempat palsu)")
    elif provider not in PROVIDERS:
        problems.append(f"PLACES_PROVIDER='{provider}' tidak dikenal (pilih: {', '.join(PROVIDERS)})")
    elif provider == "mock":
        notes.append("PLACES_PROVIDER=mock: mode MOCK, tempat palsu untuk pengembangan (bukan data peta sungguhan)")

    fallback = env.get("PLACES_FALLBACK_PROVIDER", "").lower()
    if fallback in ("none", "off", "no", "-"):
        fallback = ""
    if fallback and fallback not in FALLBACK_PROVIDERS:
        notes.append(f"PLACES_FALLBACK_PROVIDER='{fallback}' tidak dikenal (pilih: {', '.join(FALLBACK_PROVIDERS)}), "
                     "tanpa cadangan")
        fallback = ""
    if fallback and fallback == provider:
        notes.append("PLACES_FALLBACK_PROVIDER sama dengan provider utama, diabaikan")
        fallback = ""

    base_url = (env.get("GOOGLE_PLACES_BASE_URL", "") or GOOGLE_BASE_URL).rstrip("/")
    if provider == "google":
        if not api_key:
            problems.append("GOOGLE_PLACES_API_KEY belum diisi (taruh di file .env, jangan di aplikasi Flutter)")
        elif api_key.startswith("YOUR_"):
            problems.append("GOOGLE_PLACES_API_KEY masih berisi contoh dari env.example, ganti dengan API key asli")
        elif re.search(r"\s|[\"']", api_key):
            problems.append("GOOGLE_PLACES_API_KEY mengandung spasi atau tanda kutip, kemungkinan salah salin")
        parsed = urlparse(base_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            problems.append(f"GOOGLE_PLACES_BASE_URL='{base_url}' tidak valid (harus diawali http:// atau https://)")
        elif parsed.scheme == "http" and (parsed.hostname or "") not in _LOCAL_HOSTS:
            problems.append("GOOGLE_PLACES_BASE_URL memakai http:// ke server non-lokal; API key tidak boleh "
                            "dikirim tanpa enkripsi (pakai https://)")

    osm_urls, bad_urls = _osm_urls(env.get("PLACES_OSM_URL", ""))
    osm_transport = env.get("PLACES_OSM_TRANSPORT", "auto").lower()
    if osm_transport not in OSM_TRANSPORTS:
        notes.append(f"PLACES_OSM_TRANSPORT='{osm_transport}' tidak dikenal (pilih: {', '.join(OSM_TRANSPORTS)}), "
                     "dipakai 'auto'")
        osm_transport = "auto"
    if provider == "osm" or fallback == "osm":
        if not osm_urls:
            problems.append(f"PLACES_OSM_URL='{', '.join(bad_urls)}' tidak valid (harus diawali http:// atau https://)")
        elif bad_urls:
            notes.append(f"PLACES_OSM_URL: {len(bad_urls)} alamat tidak valid diabaikan (harus diawali http:// atau "
                         "https://)")
        notes.append("OpenStreetMap lewat server Overpass publik: fair use ketat (sekitar 100 query/hari untuk "
                     "pemakaian rutin) dan bukan untuk rilis. Cocok untuk demo/pengembangan.")

    snapshot_file = env.get("PLACES_SNAPSHOT_FILE", "") or str(_REPO_ROOT / SNAPSHOT_FILE)
    if provider == "snapshot" or fallback == "snapshot":
        if Path(snapshot_file).is_file():
            notes.append("Data tempat dari file offline (snapshot): tidak live, tempat yang baru buka/tutup setelah "
                         "tanggal data tidak ikut. Aplikasi diberi keterangan tanggal datanya.")
        else:
            notes.append(f"File data offline belum ada ({Path(snapshot_file).name}), provider snapshot belum bisa "
                         "menjawab. Cara mengambilnya: README_MAPS.md bagian Data offline.")

    rating_hours = _flag(env, "PLACES_GOOGLE_RATING_HOURS", False, notes)
    if rating_hours and provider == "google":
        notes.append("PLACES_GOOGLE_RATING_HOURS=true: Google menagih tier Enterprise (jatah gratis 1.000/bulan, "
                     "lalu $35 per 1.000 permintaan)")

    language = env.get("PLACES_LANGUAGE", "id")
    if not re.fullmatch(r"[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?", language):
        notes.append(f"PLACES_LANGUAGE='{language}' tidak valid, dipakai 'id'")
        language = "id"
    region = env.get("PLACES_REGION", "ID").upper()
    if not re.fullmatch(r"[A-Z]{2}", region):
        notes.append(f"PLACES_REGION='{region}' harus 2 huruf (kode negara), dipakai 'ID'")
        region = "ID"

    monthly_default = DEFAULT_MONTHLY_BUDGET_ENTERPRISE if rating_hours else DEFAULT_MONTHLY_BUDGET_PRO
    google_daily = _number(env, "PLACES_GOOGLE_DAILY_BUDGET", DEFAULT_DAILY_BUDGET, 0, 10_000_000, int, notes)
    google_monthly = _number(env, "PLACES_GOOGLE_MONTHLY_BUDGET", monthly_default, 0, 100_000_000, int, notes)
    if provider == "google" and (google_daily == 0 or google_monthly == 0):
        notes.append("Batas panggilan Google dimatikan (0). Pastikan quota cap sudah dipasang di Google Cloud "
                     "Console, kalau tidak bug di aplikasi bisa menghabiskan kuota gratis.")

    usage_raw = env.get("PLACES_USAGE_FILE", "")
    if usage_raw.lower() in ("off", "none", "no", "false", "-"):
        usage_file: Optional[str] = None
    else:
        usage_file = usage_raw or str(_REPO_ROOT / ".places_usage.json")

    settings = Settings(
        provider=provider,
        fallback_provider=fallback,
        google_api_key=api_key,
        google_base_url=base_url,
        google_rating_hours=rating_hours,
        google_types=_type_overrides(env, notes),
        osm_url=osm_urls[0] if osm_urls else OSM_URL,
        osm_urls=osm_urls or (OSM_URL,),
        osm_user_agent=env.get("PLACES_OSM_USER_AGENT", "") or OSM_USER_AGENT,
        osm_timeout_s=_number(env, "PLACES_OSM_TIMEOUT_S", 8.0, 1.0, 60.0, float, notes),
        osm_deadline_s=_number(env, "PLACES_OSM_DEADLINE_S", 20.0, 2.0, 120.0, float, notes),
        osm_transport=osm_transport,
        language=language,
        region=region,
        timeout_s=_number(env, "PLACES_TIMEOUT_S", 4.0, 0.2, 30.0, float, notes),
        max_retries=_number(env, "PLACES_MAX_RETRIES", 1, 0, 3, int, notes),
        max_radius_m=_number(env, "PLACES_MAX_RADIUS_M", 50000, 100, 50000, int, notes),
        cache_ttl_s=_number(env, "PLACES_CACHE_TTL_S", 90.0, 0.0, 86400.0, float, notes),
        cache_tolerance_m=_number(env, "PLACES_CACHE_TOLERANCE_M", 250.0, 0.0, 5000.0, float, notes),
        cache_max_entries=_number(env, "PLACES_CACHE_MAX_ENTRIES", 200, 1, 100000, int, notes),
        stale_ttl_s=_number(env, "PLACES_STALE_TTL_S", 21600.0, 0.0, 7 * 86400.0, float, notes),
        stale_cache_file=_off_or_path(env.get("PLACES_STALE_CACHE_FILE", "")),
        snapshot_file=snapshot_file,
        rate_per_client_per_min=_number(env, "PLACES_RATE_PER_CLIENT_PER_MIN", 20, 0, 10000, int, notes),
        rate_global_per_min=_number(env, "PLACES_RATE_GLOBAL_PER_MIN", 120, 0, 100000, int, notes),
        google_daily_budget=google_daily,
        google_monthly_budget=google_monthly,
        osm_daily_budget=_number(env, "PLACES_OSM_DAILY_BUDGET", 500, 0, 10_000_000, int, notes),
        usage_file=usage_file,
        tz_offset_hours=_number(env, "PLACES_TZ_OFFSET_HOURS", 7.0, -12.0, 14.0, float, notes),
        problem="; ".join(problems) if problems else None,
        notes=tuple(notes),
    )

    for note in notes:
        log.warning("[PLACES] %s", note)
    return settings
