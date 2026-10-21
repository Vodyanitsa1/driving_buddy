"""Cache hasil pencarian di memori.

Dua fungsi: menghemat jatah panggilan berbayar, dan meredam aplikasi yang mengirim lokasi terlalu sering
(terutama saat kendaraan berhenti, yang justru saat pengemudi paling butuh hasilnya).

Hasil dipakai ulang kalau kategori, radius, dan provider sama, umurnya belum lewat TTL, DAN posisi baru berada
dalam `tolerance_m` dari posisi saat hasil itu diambil. Jarak dan arah ke tiap tempat tetap dihitung ulang dari
posisi terbaru, jadi yang basi hanya daftar tempatnya. Hasil kosong ikut di-cache (tidak ada rest area dalam radius
itu juga jawaban yang sah dan berbayar).

Cache basi (stale-if-error, v2): entri disimpan lebih lama dari TTL, sampai `stale_ttl_s`. Entri yang sudah lewat
TTL tidak dipakai untuk pencarian normal, HANYA lewat `get_stale()` saat semua provider gagal, dan jawabannya
diberi label "data tersimpan". Opsional (opt-in) disimpan ke file JSON supaya tahan restart server; file itu
berisi titik pusat pencarian dan waktunya, jadi jangan di-commit.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
import time
from collections import OrderedDict
from pathlib import Path
from typing import Callable, List, Optional, Tuple

from .geo import haversine_m
from .providers.base import Place

log = logging.getLogger("driving_buddy.places")

STALE_MAX_CENTER_M = 3000.0  # cache basi: pusat pencarian lama maksimal sejauh min(ini, radius/5)
STALE_FILE_VERSION = 1


class _Entry:
    __slots__ = ("provider", "category", "radius_m", "lat", "lng", "places", "stored_at")

    def __init__(self, provider: str, category: str, radius_m: int, lat: float, lng: float,
                 places: Tuple[Place, ...], stored_at: float):
        self.provider = provider
        self.category = category
        self.radius_m = radius_m
        self.lat = lat
        self.lng = lng
        self.places = places
        self.stored_at = stored_at


class NearbyCache:
    def __init__(self, ttl_s: float = 90.0, tolerance_m: float = 250.0, max_entries: int = 200,
                 clock: Callable[[], float] = time.monotonic, stale_ttl_s: float = 0.0,
                 stale_file: Optional[str] = None, wall_clock: Callable[[], float] = time.time):
        self.ttl_s = ttl_s
        self.tolerance_m = tolerance_m
        self.max_entries = max_entries
        self.stale_ttl_s = max(0.0, stale_ttl_s)
        self.stale_file = stale_file
        self._clock = clock
        self._wall = wall_clock
        self._entries: "OrderedDict[int, _Entry]" = OrderedDict()
        self._seq = 0
        if stale_file and self.stale_ttl_s > 0:
            self._load()

    @property
    def keep_s(self) -> float:
        return max(self.ttl_s, self.stale_ttl_s)

    def __len__(self) -> int:
        """Jumlah entri SEGAR (yang dipakai pencarian normal)."""
        self._purge()
        now = self._clock()
        return sum(1 for e in self._entries.values() if now - e.stored_at <= self.ttl_s)

    @property
    def stale_entries(self) -> int:
        self._purge()
        return len(self._entries)

    def get(self, provider: str, category: str, radius_m: int, lat: float, lng: float) -> Optional[List[Place]]:
        """None = tidak ada di cache. List kosong = ada, dan memang tidak ada tempat."""
        if self.ttl_s <= 0:
            return None
        self._purge()
        now = self._clock()
        best_id, best_dist = None, None
        for entry_id, e in self._entries.items():
            if e.provider != provider or e.category != category or e.radius_m != radius_m:
                continue
            if now - e.stored_at > self.ttl_s:
                continue
            dist = haversine_m(lat, lng, e.lat, e.lng)
            if dist <= self.tolerance_m and (best_dist is None or dist < best_dist):
                best_id, best_dist = entry_id, dist
        if best_id is None:
            return None
        self._entries.move_to_end(best_id)
        return list(self._entries[best_id].places)

    def get_stale(self, category: str, radius_m: int, lat: float, lng: float
                  ) -> Optional[Tuple[List[Place], float, str]]:
        """Hasil lama (provider apa pun) untuk dipakai saat semua provider gagal: (tempat, umur detik, provider).
        Dipilih yang pusatnya paling dekat, lalu yang paling baru."""
        if self.stale_ttl_s <= 0:
            return None
        self._purge()
        now = self._clock()
        limit = min(STALE_MAX_CENTER_M, radius_m / 5.0)
        limit = max(limit, self.tolerance_m)
        best: Optional[Tuple[float, float, _Entry]] = None
        for e in self._entries.values():
            if e.category != category or e.radius_m != radius_m:
                continue
            age = now - e.stored_at
            if age > self.stale_ttl_s:
                continue
            dist = haversine_m(lat, lng, e.lat, e.lng)
            if dist > limit:
                continue
            if best is None or (dist, age) < (best[0], best[1]):
                best = (dist, age, e)
        if best is None:
            return None
        return list(best[2].places), max(0.0, best[1]), best[2].provider

    def put(self, provider: str, category: str, radius_m: int, lat: float, lng: float,
            places: List[Place]) -> None:
        if self.keep_s <= 0:
            return
        self._purge()
        # Satu tempat cukup satu entri: buang entri lama dengan kunci & posisi (hampir) sama.
        for entry_id in [i for i, e in self._entries.items()
                         if e.provider == provider and e.category == category and e.radius_m == radius_m
                         and haversine_m(lat, lng, e.lat, e.lng) <= self.tolerance_m]:
            del self._entries[entry_id]
        self._seq += 1
        self._entries[self._seq] = _Entry(provider, category, radius_m, lat, lng, tuple(places), self._clock())
        while len(self._entries) > self.max_entries:
            self._entries.popitem(last=False)
        if self.stale_file and self.stale_ttl_s > 0:
            self._save()

    def _purge(self) -> None:
        now = self._clock()
        keep = self.keep_s
        expired = [i for i, e in self._entries.items() if now - e.stored_at > keep]
        for entry_id in expired:
            del self._entries[entry_id]

    # -- file (opt-in) ------------------------------------------------------
    def _save(self) -> None:
        now, wall = self._clock(), self._wall()
        rows = []
        for e in self._entries.values():
            rows.append({
                "provider": e.provider, "category": e.category, "radius_m": e.radius_m,
                "lat": round(e.lat, 5), "lng": round(e.lng, 5), "stored_wall": wall - (now - e.stored_at),
                "places": [p.__dict__ for p in e.places],
            })
        path = Path(self.stale_file)  # type: ignore[arg-type]
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=".places_cache", dir=str(path.parent))
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({"version": STALE_FILE_VERSION, "entries": rows}, fh, ensure_ascii=False)
            os.replace(tmp, str(path))
        except (OSError, TypeError, ValueError) as exc:
            log.warning("[PLACES] gagal menyimpan cache basi ke file: %s", type(exc).__name__)

    def _load(self) -> None:
        try:
            data = json.loads(Path(self.stale_file).read_text(encoding="utf-8"))  # type: ignore[arg-type]
        except FileNotFoundError:
            return
        except (OSError, ValueError) as exc:
            log.warning("[PLACES] file cache basi tidak terbaca, diabaikan: %s", type(exc).__name__)
            return
        if not isinstance(data, dict) or data.get("version") != STALE_FILE_VERSION:
            return
        now, wall = self._clock(), self._wall()
        loaded = 0
        for row in data.get("entries") or []:
            try:
                age = wall - float(row["stored_wall"])
                if age < 0 or age > self.stale_ttl_s:
                    continue
                places = tuple(Place(**p) for p in row["places"])
                self._seq += 1
                self._entries[self._seq] = _Entry(str(row["provider"]), str(row["category"]), int(row["radius_m"]),
                                                  float(row["lat"]), float(row["lng"]), places, now - age)
                loaded += 1
            except (KeyError, TypeError, ValueError):
                continue
        while len(self._entries) > self.max_entries:
            self._entries.popitem(last=False)
        if loaded:
            log.info("[PLACES] cache basi dimuat dari file: %d entri", loaded)
