"""Hitungan jarak dan arah di permukaan bumi (tanpa library tambahan)."""
from __future__ import annotations

import math
from typing import Tuple

EARTH_RADIUS_M = 6_371_008.8  # radius rata-rata bumi (IUGG)


def in_range(lat: float, lng: float) -> bool:
    """True kalau lat/lng angka hingga (bukan NaN/inf) dan berada di rentang yang sah."""
    try:
        return math.isfinite(lat) and math.isfinite(lng) and -90.0 <= lat <= 90.0 and -180.0 <= lng <= 180.0
    except TypeError:
        return False


def is_null_island(lat: float, lng: float) -> bool:
    """(0, 0) hampir pasti bukan posisi sopir: itu nilai bawaan saat GPS belum dapat sinyal."""
    return abs(lat) < 1e-6 and abs(lng) < 1e-6


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Jarak garis lurus di permukaan bumi, dalam meter."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = p2 - p1
    dlmb = math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def bearing_deg(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Arah dari titik 1 ke titik 2: 0 = utara, 90 = timur, 180 = selatan, 270 = barat (0 <= hasil < 360)."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dlmb = math.radians(lng2 - lng1)
    y = math.sin(dlmb) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dlmb)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def angle_diff_deg(a: float, b: float) -> float:
    """Selisih terkecil antara dua arah, 0..180."""
    d = abs(a - b) % 360.0
    return 360.0 - d if d > 180.0 else d


def destination_point(lat: float, lng: float, bearing: float, distance_m: float) -> Tuple[float, float]:
    """Titik yang dicapai kalau berjalan `distance_m` meter ke arah `bearing` dari (lat, lng)."""
    ang = distance_m / EARTH_RADIUS_M
    brg = math.radians(bearing)
    p1, l1 = math.radians(lat), math.radians(lng)
    p2 = math.asin(math.sin(p1) * math.cos(ang) + math.cos(p1) * math.sin(ang) * math.cos(brg))
    l2 = l1 + math.atan2(math.sin(brg) * math.sin(ang) * math.cos(p1), math.cos(ang) - math.sin(p1) * math.sin(p2))
    return math.degrees(p2), (math.degrees(l2) + 540.0) % 360.0 - 180.0


def format_distance(distance_m: float) -> str:
    """'350 m', '2,3 km', '35 km' (koma desimal ala Indonesia)."""
    d = max(0.0, float(distance_m))
    rounded = int(math.floor(d / 10.0 + 0.5)) * 10
    if rounded < 1000:
        return "%d m" % max(rounded, 10)
    km = d / 1000.0
    if km < 10:
        text = "%.1f" % km
        if text.endswith(".0"):
            text = text[:-2]
        return text.replace(".", ",") + " km"
    return "%d km" % int(math.floor(km + 0.5))


def speak_distance(distance_m: float) -> str:
    """Versi yang enak dibacakan TTS: '350 meter', '2,3 kilometer'."""
    text = format_distance(distance_m)
    if text.endswith(" km"):
        return text[:-3] + " kilometer"
    return text[:-2] + " meter"
