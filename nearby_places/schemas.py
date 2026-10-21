"""Bentuk request/response endpoint tempat terdekat (juga dipakai dokumentasi /docs)."""
from __future__ import annotations

import math
from typing import Any, Dict, List, Optional

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, field_validator, model_validator

from . import categories
from .geo import is_null_island

MIN_SPEED_FOR_HEADING_MPS = 1.5  # di bawah ini (~5 km/jam) arah dari GPS tidak bisa dipercaya


def _lenient_number(value: Any, lo: float, hi: float) -> Optional[float]:
    """Sensor sering mengirim -1, NaN, atau nilai aneh saat datanya belum ada: anggap 'tidak tersedia', bukan error."""
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number) or number < lo or number > hi:
        return None
    return number


class NearbyRequest(BaseModel):
    """Posisi pengemudi + apa yang dicari. Nama field mengikuti `Position` dari paket Flutter `geolocator`
    (latitude, longitude, heading, speed, accuracy), jadi hasil `getCurrentPosition()` bisa diteruskan apa adanya."""

    model_config = ConfigDict(
        populate_by_name=True,
        extra="ignore",
        str_strip_whitespace=True,
        json_schema_extra={
            "examples": [
                {"lat": -6.9904, "lng": 110.4229, "category": "all", "limit": 3},
                {"latitude": -7.1405, "longitude": 110.4020, "category": "rest_area", "heading": 180.0, "speed": 27.0,
                 "prefer_ahead": True},
            ]
        },
    )

    lat: float = Field(
        ..., ge=-90, le=90, allow_inf_nan=False,
        validation_alias=AliasChoices("lat", "latitude"),
        description="Lintang posisi pengemudi (derajat desimal).",
    )
    lng: float = Field(
        ..., ge=-180, le=180, allow_inf_nan=False,
        validation_alias=AliasChoices("lng", "lon", "longitude"),
        description="Bujur posisi pengemudi (derajat desimal).",
    )
    category: str = Field(
        default=categories.ALL,
        description="rest_area | minimarket | lodging | spbu | all (all = rest_area + minimarket + lodging).",
    )
    radius_m: Optional[int] = Field(
        default=None, ge=100, le=50000,
        validation_alias=AliasChoices("radius_m", "radiusM", "radius"),
        description="Radius pencarian dalam meter. Kosong = bawaan per kategori (rest area 50 km, hotel/motel 25 km, SPBU 10 km, minimarket 3 km).",
    )
    limit: int = Field(default=5, ge=1, le=10, description="Jumlah maksimal hasil PER kategori.")
    heading_deg: Optional[float] = Field(
        default=None,
        validation_alias=AliasChoices("heading_deg", "headingDeg", "heading"),
        description="Arah gerak kendaraan, derajat dari utara searah jarum jam (0-360). Kosong/-1 = tidak diketahui.",
    )
    speed_mps: Optional[float] = Field(
        default=None,
        validation_alias=AliasChoices("speed_mps", "speedMps", "speed"),
        description="Kecepatan dalam meter/detik. Kalau hampir diam (< 1,5), arah gerak diabaikan karena GPS tidak akurat.",
    )
    accuracy_m: Optional[float] = Field(
        default=None,
        validation_alias=AliasChoices("accuracy_m", "accuracyM", "accuracy"),
        description="Akurasi lokasi dari GPS (meter). Dipakai untuk memberi peringatan kalau terlalu kasar.",
    )
    prefer_ahead: bool = Field(
        default=False,
        validation_alias=AliasChoices("prefer_ahead", "preferAhead"),
        description="true = tempat yang ada di depan kendaraan diurutkan lebih dulu (butuh heading_deg).",
    )

    @field_validator("category", mode="before")
    @classmethod
    def _check_category(cls, value: Any) -> str:
        key = str(value if value is not None else categories.ALL).strip().lower()
        if key not in categories.valid_keys():
            raise ValueError("category harus salah satu dari: " + ", ".join(categories.valid_keys()))
        return key

    @field_validator("heading_deg", mode="before")
    @classmethod
    def _check_heading(cls, value: Any) -> Optional[float]:
        number = _lenient_number(value, 0.0, 360.0)
        return None if number is None else number % 360.0

    @field_validator("speed_mps", mode="before")
    @classmethod
    def _check_speed(cls, value: Any) -> Optional[float]:
        return _lenient_number(value, 0.0, 200.0)

    @field_validator("accuracy_m", mode="before")
    @classmethod
    def _check_accuracy(cls, value: Any) -> Optional[float]:
        return _lenient_number(value, 0.0, 1_000_000.0)

    @model_validator(mode="after")
    def _reject_null_island(self) -> "NearbyRequest":
        if is_null_island(self.lat, self.lng):
            raise ValueError("Koordinat (0, 0) ditolak: biasanya itu tanda GPS belum dapat sinyal. "
                             "Tunggu sampai lokasi valid sebelum mencari tempat.")
        return self

    @property
    def effective_heading(self) -> Optional[float]:
        """Arah gerak yang boleh dipercaya (None kalau tidak ada atau kendaraan hampir diam)."""
        if self.heading_deg is None:
            return None
        if self.speed_mps is not None and self.speed_mps < MIN_SPEED_FOR_HEADING_MPS:
            return None
        return self.heading_deg


class PlaceOut(BaseModel):
    id: str = Field(..., description="ID tempat dari provider (untuk Google: place id).")
    name: str
    category: str = Field(..., description="rest_area | minimarket | lodging | spbu")
    category_label: str
    address: str = Field(default="", description="Alamat, bisa kosong (data OpenStreetMap sering tidak punya alamat).")
    lat: float
    lng: float
    distance_m: int = Field(..., description="Jarak garis lurus dari posisi pengemudi, BUKAN jarak lewat jalan.")
    distance_text: str = Field(..., description="Siap tampil, misal '350 m' atau '2,3 km'.")
    bearing_deg: int = Field(..., description="Arah tempat itu dari pengemudi (0 = utara, 90 = timur).")
    ahead: Optional[bool] = Field(
        default=None,
        description="true = di depan kendaraan, false = di belakang, null = arah gerak tidak diketahui.",
    )
    open_now: Optional[bool] = Field(
        default=None,
        description="Hanya terisi kalau PLACES_GOOGLE_RATING_HOURS=true (lebih mahal). null = tidak diketahui.",
    )
    rating: Optional[float] = None
    maps_url: str = Field(..., description="Halaman tempat itu (Google Maps / OpenStreetMap).")
    navigate_url: str = Field(..., description="Buka di aplikasi Google Maps langsung ke mode navigasi mobil.")
    source: str = Field(..., description="google | osm | snapshot (data OSM offline) | mock")
    provider_type: Optional[str] = Field(
        default=None, description="Tipe asli dari provider (berguna untuk menyetel PLACES_GOOGLE_TYPES_*).",
    )


class NearbyResponse(BaseModel):
    results: List[PlaceOut]
    summary: str = Field(..., description="Ringkasan singkat siap dibacakan TTS.")
    category: str
    provider: str = Field(..., description="Provider yang dikonfigurasi sebagai utama.")
    cached: bool = Field(default=False, description="true = seluruh hasil dari cache (tidak ada panggilan ke provider).")
    degraded: bool = Field(
        default=False,
        description="true = sebagian/seluruh pencarian gagal; lihat `errors`. HTTP tetap 200 supaya aplikasi tidak crash.",
    )
    errors: Dict[str, str] = Field(
        default_factory=dict,
        description="kategori -> penyebab gagal (timeout, network, rate_limited, auth, upstream, budget_exhausted, ...).",
    )
    fallback_used: bool = Field(default=False, description="true = sebagian hasil dari provider cadangan.")
    warnings: List[str] = Field(default_factory=list)
    latency_ms: int = 0
