"""Data OpenStreetMap tersimpan (offline): cadangan saat server Overpass publik penuh.

File `places_snapshot.json` adalah balasan Overpass (format JSON, `out center tags`) untuk satu area, diambil
sekali (cara mengambilnya ada di README_MAPS.md bagian "Data offline"). Pencarian dilakukan di memori: tanpa
internet, tanpa jatah panggilan, instan. Datanya bisa ketinggalan (tempat baru/tutup tidak ikut), jadi aplikasi
diberi keterangan tanggal datanya lewat `warnings`.

Di luar area file, provider ini menolak (error), bukan menjawab "tidak ada tempat", supaya pengemudi tidak
mengira memang tidak ada rest area di dekatnya.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from ..categories import CATEGORIES
from ..config import Settings
from ..geo import haversine_m
from .base import BaseProvider, Budget, Place, PlacesError
from .osm import _to_place

log = logging.getLogger("driving_buddy.places")

HINT_SNAPSHOT = "ambil data offline dulu (README_MAPS.md bagian Data offline), lalu restart server"
COVER_MARGIN_M = 2000.0  # titik pencarian boleh sedikit di luar sebaran data
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des")


class SnapshotProvider(BaseProvider):
    name = "snapshot"
    max_concurrency = 4

    def __init__(self, settings: Settings, path: Optional[str] = None):
        self.path = path or settings.snapshot_file
        self.tz_offset_hours = settings.tz_offset_hours
        self.places: Dict[str, List[Place]] = {key: [] for key in CATEGORIES}
        self.bbox: Optional[Tuple[float, float, float, float]] = None  # (lat min, lng min, lat max, lng max)
        self.data_date = ""
        self.problem: Optional[str] = None
        self._load()
        if self.problem:
            log.warning("[PLACES] data offline belum bisa dipakai: %s", self.problem)

    # -- API publik ---------------------------------------------------------
    @property
    def count(self) -> int:
        return sum(len(items) for items in self.places.values())

    @property
    def source_note(self) -> Optional[str]:
        when = f" tanggal {self.data_date}" if self.data_date else ""
        return f"Data tempat dari salinan OpenStreetMap{when} (offline), bisa ada yang sudah berubah."

    def describe(self) -> Dict[str, Any]:
        return {
            "file": Path(self.path).name if self.path else None,
            "problem": self.problem,
            "date": self.data_date or None,
            "places": {key: len(items) for key, items in self.places.items()},
            "area": [round(v, 3) for v in self.bbox] if self.bbox else None,
        }

    async def search(self, category, lat: float, lng: float, radius_m: int, budget: Budget) -> List[Place]:
        if self.problem:
            raise PlacesError("upstream", self.problem, hint=HINT_SNAPSHOT)
        if not self.covers(lat, lng):
            raise PlacesError("upstream", "lokasi di luar area data offline",
                              hint="ambil data offline untuk area ini, atau pakai provider osm")
        return [p for p in self.places.get(category.key, []) if haversine_m(lat, lng, p.lat, p.lng) <= radius_m]

    async def probe(self, budget: Budget) -> int:
        if self.problem:
            raise PlacesError("upstream", self.problem, hint=HINT_SNAPSHOT)
        return self.count

    def covers(self, lat: float, lng: float) -> bool:
        if self.bbox is None:
            return False
        lat_min, lng_min, lat_max, lng_max = self.bbox
        near_lat = min(max(lat, lat_min), lat_max)
        near_lng = min(max(lng, lng_min), lng_max)
        return haversine_m(lat, lng, near_lat, near_lng) <= COVER_MARGIN_M

    # -- internal -----------------------------------------------------------
    def _load(self) -> None:
        if not self.path:
            self.problem = "PLACES_SNAPSHOT_FILE belum diisi"
            return
        try:
            raw = Path(self.path).read_bytes()
        except FileNotFoundError:
            self.problem = f"file data offline belum ada ({Path(self.path).name})"
            return
        except OSError as exc:
            self.problem = f"file data offline tidak terbaca ({type(exc).__name__})"
            return
        try:
            data = json.loads(raw)
        except ValueError:
            self.problem = "file data offline bukan JSON yang valid (ambil ulang)"
            return
        elements = data.get("elements") if isinstance(data, dict) else None
        if not isinstance(elements, list):
            self.problem = "file data offline bukan balasan Overpass (tidak ada 'elements')"
            return
        if "runtime error" in str(data.get("remark") or "").lower():
            self.problem = "file data offline berisi error dari Overpass (ambil ulang)"
            return

        lats: List[float] = []
        lngs: List[float] = []
        for element in elements:
            if not isinstance(element, dict):
                continue
            for cat in CATEGORIES.values():
                place = _to_place(element, cat)
                if place is None or not place.provider_type:  # provider_type kosong = tag kategori ini tidak cocok
                    continue
                self.places[cat.key].append(place)
                lats.append(place.lat)
                lngs.append(place.lng)
        if not lats:
            self.problem = "file data offline tidak berisi tempat yang dikenal"
            return
        self.bbox = (min(lats), min(lngs), max(lats), max(lngs))
        self.data_date = _date_label(data, self.path, self.tz_offset_hours)
        log.info("[PLACES] data offline dimuat: %s (%s)", ", ".join(
            f"{key}={len(items)}" for key, items in self.places.items()), self.data_date or "tanggal tidak diketahui")


def _date_label(data: Dict[str, Any], path: str, tz_offset_hours: float) -> str:
    """Tanggal data OSM (dari `osm3s.timestamp_osm_base` balasan Overpass, atau waktu file), dalam WIB."""
    stamp: Optional[datetime] = None
    osm3s = data.get("osm3s")
    if isinstance(osm3s, dict):
        try:
            stamp = datetime.strptime(str(osm3s.get("timestamp_osm_base") or ""), "%Y-%m-%dT%H:%M:%SZ")
            stamp = stamp.replace(tzinfo=timezone.utc)
        except ValueError:
            stamp = None
    if stamp is None:
        try:
            stamp = datetime.fromtimestamp(os.path.getmtime(path), tz=timezone.utc)
        except OSError:
            return ""
    local = stamp + timedelta(hours=tz_offset_hours)
    return f"{local.day} {_MONTHS[local.month - 1]} {local.year}"
