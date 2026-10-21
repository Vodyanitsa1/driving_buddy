"""Pembatas laju permintaan dan penghitung jatah panggilan ke provider.

Kenapa ada penghitung jatah: Google memberi 5.000 panggilan gratis per bulan (tier Pro), dan budget alert
di Google Cloud hanya mengirim notifikasi, TIDAK menghentikan tagihan. Penghitung ini berhenti memanggil
Google sebelum jatah gratis habis. Ini lapisan kedua; lapisan pertama (quota cap di Google Cloud Console)
tetap harus dipasang.
"""
from __future__ import annotations

import json
import logging
import os
import threading
import time
from collections import deque
from datetime import datetime, timedelta, timezone
from typing import Callable, Deque, Dict, Optional, Tuple

from .providers.base import Budget, PlacesError

log = logging.getLogger("driving_buddy.places")


class RateLimiter:
    """Sliding window: maksimal `limit` permintaan per `window_s` detik untuk tiap key. limit <= 0 = nonaktif."""

    def __init__(self, limit: int, window_s: float = 60.0, clock: Callable[[], float] = time.monotonic):
        self.limit = limit
        self.window_s = window_s
        self._clock = clock
        self._hits: Dict[str, Deque[float]] = {}
        self._calls = 0

    def hit(self, key: str) -> Tuple[bool, float]:
        """Catat 1 permintaan. Return (diizinkan, detik_yang_harus_ditunggu_kalau_ditolak)."""
        if self.limit <= 0:
            return True, 0.0
        now = self._clock()
        queue = self._hits.setdefault(key, deque())
        cutoff = now - self.window_s
        while queue and queue[0] <= cutoff:
            queue.popleft()
        if len(queue) >= self.limit:
            return False, max(0.0, queue[0] + self.window_s - now)
        queue.append(now)
        self._calls += 1
        if self._calls % 256 == 0:
            self._sweep(now)
        return True, 0.0

    def _sweep(self, now: float) -> None:
        cutoff = now - self.window_s
        for key in [k for k, q in self._hits.items() if not q or q[-1] <= cutoff]:
            del self._hits[key]


class UsageLedger:
    """Menghitung panggilan ke tiap provider per hari dan per bulan (zona waktu tetap, bawaan WIB).

    Disimpan ke file JSON kecil supaya restart server tidak mengosongkan hitungan. Kalau file tidak bisa
    dibaca/ditulis, hitungan tetap jalan di memori (hanya dicatat peringatan). Cukup untuk SATU proses server
    (server.py memang satu proses); kalau suatu saat pakai banyak worker, hitungannya tidak dibagi.
    """

    VERSION = 1

    def __init__(self, path: Optional[str] = None, tz_offset_hours: float = 7.0,
                 wall_clock: Callable[[], float] = time.time):
        self.path = path
        self._tz = timezone(timedelta(hours=tz_offset_hours))
        self._wall = wall_clock
        self._lock = threading.Lock()
        self._day = ""
        self._month = ""
        self._counts: Dict[str, Dict[str, int]] = {}  # provider -> {"day": n, "month": n}
        self._warned = False
        self._load()

    # -- API publik ---------------------------------------------------------
    def snapshot(self, provider: str) -> Dict[str, int]:
        with self._lock:
            self._roll()
            entry = self._counts.get(provider, {})
            return {"today": entry.get("day", 0), "month": entry.get("month", 0)}

    def reserve(self, provider: str, daily_limit: int, monthly_limit: int) -> Optional[str]:
        """Pesan 1 panggilan. Return None kalau boleh (sudah dihitung), atau 'daily' / 'monthly' kalau jatah habis
        (tidak dihitung). Batas <= 0 berarti tanpa batas."""
        with self._lock:
            self._roll()
            entry = self._counts.setdefault(provider, {"day": 0, "month": 0})
            if monthly_limit > 0 and entry["month"] >= monthly_limit:
                return "monthly"
            if daily_limit > 0 and entry["day"] >= daily_limit:
                return "daily"
            entry["day"] += 1
            entry["month"] += 1
            self._save()
            return None

    # -- internal -----------------------------------------------------------
    def _now_keys(self) -> Tuple[str, str]:
        local = datetime.fromtimestamp(self._wall(), tz=self._tz)
        return local.strftime("%Y-%m-%d"), local.strftime("%Y-%m")

    def _roll(self) -> None:
        day, month = self._now_keys()
        if month != self._month:
            self._month = month
            for entry in self._counts.values():
                entry["month"] = 0
        if day != self._day:
            self._day = day
            for entry in self._counts.values():
                entry["day"] = 0

    def _load(self) -> None:
        day, month = self._now_keys()
        self._day, self._month = day, month
        if not self.path:
            return
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except FileNotFoundError:
            return
        except (OSError, ValueError) as exc:
            self._warn(f"file hitungan pemakaian tidak terbaca ({exc}); mulai dari nol")
            return
        try:
            if not isinstance(data, dict) or data.get("version") != self.VERSION:
                raise ValueError("format tidak dikenal")
            counts: Dict[str, Dict[str, int]] = {}
            for provider, entry in dict(data.get("counts") or {}).items():
                day_n, month_n = int(entry["day"]), int(entry["month"])
                if day_n < 0 or month_n < 0:
                    raise ValueError("angka negatif")
                counts[str(provider)] = {"day": day_n, "month": month_n}
        except (ValueError, TypeError, KeyError) as exc:
            self._warn(f"isi file hitungan pemakaian tidak valid ({exc}); mulai dari nol")
            return
        # Hitungan hanya berlaku kalau hari/bulannya masih sama dengan sekarang.
        stored_day, stored_month = str(data.get("day") or ""), str(data.get("month") or "")
        for entry in counts.values():
            if stored_month != month:
                entry["month"] = 0
            if stored_day != day:
                entry["day"] = 0
        self._counts = counts

    def _save(self) -> None:
        if not self.path:
            return
        payload = {"version": self.VERSION, "day": self._day, "month": self._month, "counts": self._counts}
        tmp = f"{self.path}.tmp"
        try:
            folder = os.path.dirname(os.path.abspath(self.path))
            os.makedirs(folder, exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(payload, fh)
            os.replace(tmp, self.path)
        except OSError as exc:
            self._warn(f"gagal menyimpan hitungan pemakaian ({exc}); hitungan hanya di memori")

    def _warn(self, message: str) -> None:
        if not self._warned:  # sekali saja, jangan membanjiri log
            self._warned = True
            log.warning("[PLACES] %s", message)


class LedgerBudget(Budget):
    """Menghubungkan UsageLedger ke provider: tiap `take()` memakai 1 jatah atau melempar budget_exhausted."""

    def __init__(self, ledger: UsageLedger, provider: str, daily_limit: int, monthly_limit: int):
        self.ledger = ledger
        self.provider = provider
        self.daily_limit = daily_limit
        self.monthly_limit = monthly_limit

    def take(self) -> None:
        reason = self.ledger.reserve(self.provider, self.daily_limit, self.monthly_limit)
        if reason is not None:
            label = "harian" if reason == "daily" else "bulanan"
            raise PlacesError(
                "budget_exhausted",
                f"jatah panggilan {label} ke {self.provider} habis (PLACES_{self.provider.upper()}_"
                f"{'DAILY' if reason == 'daily' else 'MONTHLY'}_BUDGET)",
            )
