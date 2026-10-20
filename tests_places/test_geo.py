import math

import pytest

from nearby_places import geo


def test_haversine_one_degree_of_latitude_is_about_111_km():
    assert geo.haversine_m(0, 0, 1, 0) == pytest.approx(111_195, rel=1e-3)


def test_haversine_london_paris():
    assert geo.haversine_m(51.5074, -0.1278, 48.8566, 2.3522) == pytest.approx(343_560, rel=3e-3)


def test_haversine_basic_properties():
    assert geo.haversine_m(-6.2, 106.8, -6.2, 106.8) == 0
    ab = geo.haversine_m(-6.2, 106.8, -7.25, 112.75)
    ba = geo.haversine_m(-7.25, 112.75, -6.2, 106.8)
    assert ab == pytest.approx(ba)
    assert ab == pytest.approx(665_000, rel=0.02)  # Jakarta - Surabaya, sekitar 660-670 km garis lurus


def test_haversine_antipodes_do_not_crash():
    assert geo.haversine_m(0, 0, 0, 180) == pytest.approx(math.pi * geo.EARTH_RADIUS_M, rel=1e-9)


@pytest.mark.parametrize("target,expected", [((1, 0), 0), ((0, 1), 90), ((-1, 0), 180), ((0, -1), 270)])
def test_bearing_cardinal_directions(target, expected):
    assert geo.bearing_deg(0, 0, *target) == pytest.approx(expected, abs=1e-6)


def test_bearing_is_always_in_0_360():
    for lat, lng in [(-6.2, 106.8), (10, -170), (-80, 179.9), (0, 0.0001)]:
        for t_lat, t_lng in [(-6.3, 106.7), (11, 170), (-79, -179.9), (0.0001, 0)]:
            assert 0 <= geo.bearing_deg(lat, lng, t_lat, t_lng) < 360


@pytest.mark.parametrize("a,b,expected", [(350, 10, 20), (10, 350, 20), (0, 180, 180), (90, 270, 180), (45, 45, 0),
                                          (359, 1, 2), (720, 0, 0), (-90, 90, 180)])
def test_angle_diff(a, b, expected):
    assert geo.angle_diff_deg(a, b) == pytest.approx(expected)


@pytest.mark.parametrize("bearing", [0, 33, 90, 135, 180, 271, 359])
@pytest.mark.parametrize("distance", [50, 1000, 30000])
def test_destination_point_round_trip(bearing, distance):
    lat, lng = -6.2, 106.8
    d_lat, d_lng = geo.destination_point(lat, lng, bearing, distance)
    assert geo.haversine_m(lat, lng, d_lat, d_lng) == pytest.approx(distance, abs=0.5)
    assert geo.angle_diff_deg(geo.bearing_deg(lat, lng, d_lat, d_lng), bearing) < 0.5


def test_destination_point_wraps_longitude():
    _, lng = geo.destination_point(0, 179.9, 90, 50_000)
    assert -180 <= lng < 180 and lng < 0


@pytest.mark.parametrize("meters,text", [
    (0, "10 m"), (4, "10 m"), (350, "350 m"), (354, "350 m"), (355, "360 m"), (996, "1 km"), (999.4, "1 km"),
    (1000, "1 km"), (1049, "1 km"), (1400, "1,4 km"), (2345, "2,3 km"), (9949, "9,9 km"), (9960, "10 km"),
    (10_400, "10 km"), (10_500, "11 km"), (35_000, "35 km"), (-5, "10 m"),
])
def test_format_distance(meters, text):
    assert geo.format_distance(meters) == text


@pytest.mark.parametrize("meters,text", [(350, "350 meter"), (2345, "2,3 kilometer"), (35_000, "35 kilometer"),
                                         (1000, "1 kilometer")])
def test_speak_distance(meters, text):
    assert geo.speak_distance(meters) == text


@pytest.mark.parametrize("lat,lng,ok", [
    (-6.2, 106.8, True), (90, 180, True), (-90, -180, True), (91, 0, False), (0, 181, False),
    (float("nan"), 0, False), (0, float("inf"), False), (None, 1, False), ("a", 1, False),
])
def test_in_range(lat, lng, ok):
    assert geo.in_range(lat, lng) is ok


def test_null_island():
    assert geo.is_null_island(0, 0)
    assert geo.is_null_island(1e-7, -1e-7)
    assert not geo.is_null_island(0, 0.001)
    assert not geo.is_null_island(-6.2, 106.8)
