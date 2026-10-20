import pytest
from pydantic import ValidationError

from nearby_places.schemas import MIN_SPEED_FOR_HEADING_MPS, NearbyRequest


def req(**kw):
    base = {"lat": -6.2297, "lng": 106.8261}
    base.update(kw)
    return NearbyRequest.model_validate(base)


def test_defaults():
    r = req()
    assert (r.category, r.limit, r.radius_m, r.prefer_ahead) == ("all", 5, None, False)
    assert r.heading_deg is None and r.speed_mps is None and r.accuracy_m is None


def test_geolocator_position_fields_are_accepted_as_is():
    r = NearbyRequest.model_validate({"latitude": -6.4, "longitude": 107.35, "heading": 95.5, "speed": 27.0,
                                      "accuracy": 8.0, "altitude": 12.0, "timestamp": "x"})
    assert (r.lat, r.lng, r.heading_deg, r.speed_mps, r.accuracy_m) == (-6.4, 107.35, 95.5, 27.0, 8.0)


def test_camel_case_and_snake_case_both_work():
    r = NearbyRequest.model_validate({"lat": 1, "lon": 2, "radiusM": 1234, "headingDeg": 10, "speedMps": 5,
                                      "accuracyM": 3, "preferAhead": True})
    assert (r.lng, r.radius_m, r.heading_deg, r.speed_mps, r.accuracy_m, r.prefer_ahead) == (2, 1234, 10, 5, 3, True)
    r2 = NearbyRequest.model_validate({"lat": 1, "lng": 2, "radius_m": 99999 // 100 * 100 // 2, "prefer_ahead": True})
    assert r2.prefer_ahead is True


def test_null_island_is_rejected_with_a_helpful_message():
    with pytest.raises(ValidationError) as exc:
        req(lat=0, lng=0)
    assert "GPS" in str(exc.value)
    assert req(lat=0, lng=0.5).lng == 0.5  # hanya titik (0, 0) yang ditolak


@pytest.mark.parametrize("lat,lng", [(91, 0), (-91, 10), (10, 181), (10, -181), (float("nan"), 1), (1, float("inf")),
                                     ("abc", 1), (None, 1)])
def test_invalid_coordinates_are_rejected(lat, lng):
    with pytest.raises(ValidationError):
        req(lat=lat, lng=lng)


def test_missing_coordinates_are_rejected():
    with pytest.raises(ValidationError):
        NearbyRequest.model_validate({"lat": 1})


def test_category_is_normalized_and_validated():
    assert req(category=" REST_AREA ").category == "rest_area"
    assert req(category="SPBU").category == "spbu"
    with pytest.raises(ValidationError) as exc:
        req(category="bank")
    assert "rest_area" in str(exc.value)


@pytest.mark.parametrize("radius,ok", [(99, False), (100, True), (5000.0, True), (50000, True), (50001, False),
                                       (5000.5, False), (-1, False)])
def test_radius_bounds(radius, ok):
    if ok:
        assert req(radius_m=radius).radius_m == int(radius)
    else:
        with pytest.raises(ValidationError):
            req(radius_m=radius)


@pytest.mark.parametrize("limit,ok", [(0, False), (1, True), (10, True), (11, False)])
def test_limit_bounds(limit, ok):
    if ok:
        assert req(limit=limit).limit == limit
    else:
        with pytest.raises(ValidationError):
            req(limit=limit)


@pytest.mark.parametrize("raw,expected", [
    (90, 90.0), (0, 0.0), (360, 0.0), (359.9, 359.9), (-1, None), (361, None), ("abc", None), (float("nan"), None),
    (float("inf"), None), (True, None), (None, None), ("45", 45.0),
])
def test_heading_is_lenient(raw, expected):
    assert req(heading=raw).heading_deg == expected


@pytest.mark.parametrize("raw,expected", [(0, 0.0), (27.5, 27.5), (-1, None), (500, None), ("x", None), (None, None)])
def test_speed_is_lenient(raw, expected):
    assert req(speed=raw).speed_mps == expected


@pytest.mark.parametrize("raw,expected", [(5, 5.0), (-3, None), ("x", None), (float("nan"), None)])
def test_accuracy_is_lenient(raw, expected):
    assert req(accuracy=raw).accuracy_m == expected


def test_effective_heading_is_ignored_when_the_vehicle_is_nearly_stopped():
    assert req(heading=90).effective_heading == 90
    assert req(heading=90, speed=10).effective_heading == 90
    assert req(heading=90, speed=0.3).effective_heading is None
    assert req(heading=90, speed=MIN_SPEED_FOR_HEADING_MPS).effective_heading == 90
    assert req(speed=20).effective_heading is None
