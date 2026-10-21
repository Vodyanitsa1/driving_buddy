"""Kategori tempat yang bisa dicari, dan pemetaannya ke tipe tiap provider.

Kartu Trello meminta: rest area, minimarket, hotel/motel. SPBU ditambahkan sebagai bonus
(pengemudi Indonesia biasanya berhenti di SPBU) dan TIDAK ikut kategori "all" supaya
biaya per permintaan tidak membengkak.

Kenapa radius bawaan beda-beda: Google menghitung biaya per permintaan, bukan per jarak,
dan hasilnya diurutkan dari yang terdekat, jadi radius besar itu murah. Rest area di jalan
tol jaraknya bisa puluhan kilometer (perjalanan antar kota, mis. dari Semarang), minimarket
cukup beberapa kilometer. Untuk OSM radius besar = query lebih berat (tapi rest area sedikit,
jadi aman), dan kalau hasilnya terlalu banyak radius otomatis dikecilkan.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Tuple

ALL = "all"


@dataclass(frozen=True)
class Category:
    key: str
    label: str  # tampilan di aplikasi
    speech: str  # kalimat yang dibacakan TTS
    google_types: Tuple[str, ...]  # tipe "Table A" Places API (New); cukup cocok dengan salah satu
    osm_filters: Tuple[Tuple[str, Tuple[str, ...]], ...]  # (tag OSM, nilai-nilai yang diterima)
    default_radius_m: int
    in_all: bool = True
    # Elemen OSM yang lolos osm_filters tapi jelas salah tag, dibuang: punya salah satu tag ini, atau
    # nama/merek/operatornya cocok regex ini (huruf besar/kecil diabaikan).
    osm_exclude_tags: Tuple[Tuple[str, Tuple[str, ...]], ...] = ()
    osm_exclude_names: str = ""


CATEGORIES: Dict[str, Category] = {
    c.key: c
    for c in (
        Category(
            key="rest_area",
            label="Rest area",
            speech="rest area",
            google_types=("rest_stop",),
            # highway=services = rest area tol lengkap (SPBU, makanan); highway=rest_area = tempat singgah sederhana.
            osm_filters=(("highway", ("rest_area", "services")),),
            default_radius_m=50000,  # = batas maksimum Google; jarak antar rest area tol bisa puluhan km
            # Di OSM Indonesia ada bengkel yang ditandai highway=services (dikira "servis"), mis. "bengkel motor"
            # dan "Honda Ahass" di sekitar Semarang. Itu bukan tempat istirahat, jadi dibuang.
            osm_exclude_tags=(("shop", ("car_repair", "motorcycle_repair", "tyres", "car_parts", "motorcycle", "car")),
                              ("amenity", ("car_wash",))),
            osm_exclude_names=(r"\b(bengkel|ahass|servis|service\s*(center|centre|motor|mobil)|body\s*repair|"
                               r"tambal\s*ban|cuci\s*(motor|mobil)|spare\s*-?part|onderdil|dealer|showroom)"),
        ),
        Category(
            key="minimarket",
            label="Minimarket",
            speech="minimarket",
            google_types=("convenience_store",),
            osm_filters=(("shop", ("convenience",)),),
            default_radius_m=3000,
        ),
        Category(
            key="lodging",
            label="Hotel / motel",
            speech="hotel atau penginapan",
            # "lodging" sudah mencakup semuanya; empat tipe lain dicantumkan supaya maksudnya jelas dan tidak
            # ada penginapan kecil yang terlewat kalau Google tidak menambahkan tipe umumnya.
            google_types=("hotel", "motel", "guest_house", "lodging"),
            osm_filters=(("tourism", ("hotel", "motel", "guest_house", "hostel")),),
            default_radius_m=25000,  # penginapan di luar kota biasanya di kota kecamatan, bukan di pinggir tol
        ),
        Category(
            key="spbu",
            label="SPBU",
            speech="SPBU",
            google_types=("gas_station",),
            osm_filters=(("amenity", ("fuel",)),),
            default_radius_m=10000,
            in_all=False,
        ),
    )
}


def valid_keys() -> List[str]:
    return [ALL] + list(CATEGORIES)


def expand(key: str) -> List[Category]:
    """'all' -> kategori yang ikut 'all'; selain itu satu kategori. Key tak dikenal -> KeyError."""
    if key == ALL:
        return [c for c in CATEGORIES.values() if c.in_all]
    return [CATEGORIES[key]]
