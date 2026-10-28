"""Penyimpanan riwayat percakapan (di memori) dan pembatas laju permintaan.

Riwayat sengaja hanya di memori server: hilang kalau server restart.
Rencana lanjutan (kartu "Percakapan LLM AI"): pindah ke Firestore kalau riwayat
perlu bertahan antar perjalanan.
"""
from __future__ import annotations

import asyncio
import time
from collections import OrderedDict, deque
from typing import Callable, Deque, Dict, Optional, Tuple


class Session:
    __slots__ = ("history", "last_used", "_lock")

    def __init__(self, max_messages: int, now: float):
        self.history: Deque[Dict[str, str]] = deque(maxlen=max(0, max_messages))
        self.last_used = now
        self._lock: Optional[asyncio.Lock] = None

    @property
    def lock(self) -> asyncio.Lock:
        """Satu permintaan per sesi pada satu waktu, supaya urutan tanya-jawab terjaga.
        Dibuat saat pertama dipakai (di dalam event loop); Python 3.9 mengikat Lock ke loop saat dibuat."""
        if self._lock is None:
            self._lock = asyncio.Lock()
        return self._lock

    def add_turn(self, user_text: str, assistant_text: str) -> None:
        self.history.append({"role": "user", "content": user_text})
        self.history.append({"role": "assistant", "content": assistant_text})


class SessionStore:
    """Sesi dengan masa kedaluwarsa (TTL) dan batas jumlah (yang paling lama tak dipakai dibuang)."""

    def __init__(self, max_sessions: int = 500, ttl_s: float = 1800, history_turns: int = 6,
                 clock: Callable[[], float] = time.monotonic):
        self.max_sessions = max_sessions
        self.ttl_s = ttl_s
        self.max_messages = history_turns * 2
        self._clock = clock
        self._sessions: "OrderedDict[str, Session]" = OrderedDict()

    def __len__(self) -> int:
        self._purge(self._clock())
        return len(self._sessions)

    def get(self, session_id: str) -> Session:
        now = self._clock()
        self._purge(now)
        session = self._sessions.get(session_id)
        if session is None:
            session = Session(self.max_messages, now)
            self._sessions[session_id] = session
            while len(self._sessions) > self.max_sessions:
                self._sessions.popitem(last=False)
        session.last_used = now
        self._sessions.move_to_end(session_id)
        return session

    def reset(self, session_id: str) -> bool:
        return self._sessions.pop(session_id, None) is not None

    def _purge(self, now: float) -> None:
        # OrderedDict terurut dari yang paling lama dipakai, jadi cukup cek dari depan.
        while self._sessions:
            oldest_id = next(iter(self._sessions))
            if now - self._sessions[oldest_id].last_used <= self.ttl_s:
                break
            del self._sessions[oldest_id]


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
