"""Tempat palsu untuk pengembangan frontend dan tes: tanpa internet, tanpa API key, tanpa biaya.

Tempatnya dibuat relatif terhadap posisi yang diminta (arah dan jarak tetap), jadi di mana pun
pengembang mengetes (Jakarta, Denpasar, ...) hasilnya selalu ada. Nama diberi tanda "(contoh)" supaya
tidak tertukar dengan data asli.
"""
from __future__ import annotations

from typing import Dict, List, Tuple

from ..categories import Category
from ..geo import destination_point
from .base import BaseProvider, Budget, Place

# (nama, arah dari posisi sopir dalam derajat, jarak meter)
_SEED: Dict[str, Tuple[Tuple[str, int, int], ...]] = {
    "rest_area": (
        ("Rest Area KM 57 A (contoh)", 0, 2400),
        ("Rest Area KM 72 B (contoh)", 180, 11800),
        ("Rest Area KM 88 (contoh)", 20, 26000),
    ),
    "minimarket": (
        ("Alfamart (contoh)", 40, 350),
        ("Indomaret (contoh)", 200, 820),
        ("Minimarket 24 Jam (contoh)", 95, 1900),
    ),
    "lodging": (
        ("Hotel Indah (contoh)", 10, 3100),
        ("Penginapan Singgah (contoh)", 160, 5200),
        ("Motel Transit (contoh)", 280, 9100),
    ),
    "spbu": (
        ("SPBU Pertamina (contoh)", 70, 1200),
        ("SPBU Kota (contoh)", 250, 4300),
    ),
}


class MockProvider(BaseProvider):
    name = "mock"
    max_concurrency = 10

    async def search(self, category: Category, lat: float, lng: float, radius_m: int,
                     budget: Budget) -> List[Place]:
        places: List[Place] = []
        for index, (name, bearing, distance) in enumerate(_SEED.get(category.key, ())):
            if distance > radius_m:
                continue
            p_lat, p_lng = destination_point(lat, lng, bearing, distance)
            places.append(Place(
                id=f"mock:{category.key}:{index}",
                name=name,
                lat=p_lat,
                lng=p_lng,
                address="Alamat contoh, Indonesia",
                provider_type="mock",
                maps_url=f"https://www.google.com/maps/search/?api=1&query={p_lat:.6f},{p_lng:.6f}",
            ))
        return places
