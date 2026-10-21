"""Kontrak umum untuk provider pencarian tempat (Google, OpenStreetMap, mock)."""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional

from ..categories import CATEGORIES, Category

# Titik uji untuk health check: Monas, Jakarta. Kawasan padat, jadi pasti ada minimarket di dekatnya.
PROBE_LAT, PROBE_LNG, PROBE_RADIUS_M = -6.1754, 106.8272, 2000


class PlacesError(Exception):
    """Kegagalan saat memanggil provider. `kind` dipakai aplikasi/log, bukan teks error mentah provider."""

    def __init__(self, kind: str, detail: str = "", status: Optional[int] = None,
                 retry_after: Optional[float] = None, hint: Optional[str] = None):
        super().__init__(f"{kind}: {detail}" if detail else kind)
        # timeout | network | rate_limited | auth | bad_request | upstream | bad_response | budget_exhausted
        self.kind = kind
        self.detail = detail
        self.status = status
        self.retry_after = retry_after
        self.hint = hint  # saran perbaikan berbahasa Indonesia, hanya ditampilkan di /places/health?deep=true


@dataclass(frozen=True)
class Place:
    id: str
    name: str
    lat: float
    lng: float
    address: str = ""
    provider_type: str = ""
    open_now: Optional[bool] = None
    rating: Optional[float] = None
    maps_url: str = ""


class Budget:
    """Penjaga jatah panggilan. `take()` dipanggil SEBELUM setiap permintaan HTTP (termasuk retry),
    dan melempar PlacesError('budget_exhausted') kalau jatah habis. Versi dasar ini tanpa batas."""

    def take(self) -> None:
        return None


NO_BUDGET = Budget()


class BaseProvider:
    name = ""
    # Berapa kategori boleh dicari bersamaan. OSM 1 supaya sopan ke server publik.
    max_concurrency = 1
    # Keterangan sumber data yang perlu diketahui pengemudi (mis. data offline). Ikut di `warnings` jawaban.
    source_note: Optional[str] = None

    async def search(self, category: Category, lat: float, lng: float, radius_m: int,
                     budget: Budget) -> List[Place]:
        """Semua tempat yang ditemukan dalam radius (belum dipotong `limit`, belum tentu urut jarak)."""
        raise NotImplementedError

    async def probe(self, budget: Budget) -> int:
        """Satu pencarian kecil untuk health check. Return jumlah hasil."""
        found = await self.search(CATEGORIES["minimarket"], PROBE_LAT, PROBE_LNG, PROBE_RADIUS_M, budget)
        return len(found)

    async def aclose(self) -> None:
        return None
