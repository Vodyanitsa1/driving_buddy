"""Tes endpoint HTTP /places/* lewat FastAPI TestClient (provider palsu, tanpa internet)."""
import logging

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from nearby_places import build_router
from nearby_places.config import load_settings
from nearby_places.providers.base import BaseProvider, Place, PlacesError
from nearby_places.service import PlacesService

SECRET = "AIzaSySecretKeyDoNotLeak123"


class Clock:
    def __init__(self):
        self.now = 5000.0

    def __call__(self):
        return self.now


class StubProvider(BaseProvider):
    name = "google"

    def __init__(self, places=None, error=None):
        self.places = places if places is not None else [
            Place(id="p1", name="Minimarket Satu", lat=-6.2, lng=106.8 + 0.003)]
        self.error = error
        self.calls = 0

    async def search(self, category, lat, lng, radius_m, budget):
        budget.take()
        self.calls += 1
        if self.error:
            raise self.error
        return list(self.places)


def make_client(env=None, providers=None, clock=None, raise_server_exceptions=True):
    base = {"PLACES_PROVIDER": "mock", "PLACES_USAGE_FILE": "off"}
    settings = load_settings({**base, **(env or {})})
    app = FastAPI()
    app.include_router(build_router(settings=settings, providers=providers, clock=clock or Clock()))
    return TestClient(app, raise_server_exceptions=raise_server_exceptions)


def google_client(provider=None, clock=None, **env):
    provider = provider or StubProvider()
    client = make_client({"PLACES_PROVIDER": "google", "GOOGLE_PLACES_API_KEY": SECRET, **env},
                         providers={"google": provider}, clock=clock)
    return client, provider


# ---------------------------------------------------------------------------
# POST /places/nearby
# ---------------------------------------------------------------------------
def test_nearby_returns_places_with_mock_provider():
    r = make_client().post("/places/nearby", json={"lat": -6.2, "lng": 106.8, "category": "all", "limit": 3})
    assert r.status_code == 200
    body = r.json()
    assert {"results", "summary", "category", "provider", "cached", "degraded", "errors", "fallback_used",
            "warnings", "latency_ms"} <= set(body)
    assert body["provider"] == "mock" and body["degraded"] is False
    assert {x["category"] for x in body["results"]} == {"rest_area", "minimarket", "lodging"}
    first = body["results"][0]
    assert {"id", "name", "category", "category_label", "address", "lat", "lng", "distance_m", "distance_text",
            "bearing_deg", "ahead", "open_now", "rating", "maps_url", "navigate_url", "source",
            "provider_type"} <= set(first)
    assert first["navigate_url"].startswith("https://www.google.com/maps/dir/?api=1&destination=")
    assert body["summary"]


def test_geolocator_style_field_names_are_accepted():
    r = make_client().post("/places/nearby", json={
        "latitude": -6.4026, "longitude": 107.3517, "heading": 95.0, "speed": 27.0, "accuracy": 8.0,
        "category": "rest_area", "prefer_ahead": True})
    assert r.status_code == 200
    results = r.json()["results"]
    assert results and all(x["ahead"] is not None for x in results)
    assert results[0]["ahead"] is True  # prefer_ahead: yang di depan lebih dulu


def test_camel_case_field_names_are_accepted():
    r = make_client().post("/places/nearby", json={
        "lat": -6.2, "lng": 106.8, "category": "minimarket", "radiusM": 1000, "headingDeg": 40, "speedMps": 10,
        "preferAhead": True})
    assert r.status_code == 200
    assert all(x["distance_m"] <= 1000 for x in r.json()["results"])


def test_sensor_garbage_for_heading_speed_accuracy_is_ignored():
    client = make_client()
    r = client.post("/places/nearby", json={"lat": -6.2, "lng": 106.8, "heading": -1, "speed": -1, "accuracy": -1})
    assert r.status_code == 200 and all(x["ahead"] is None for x in r.json()["results"])
    raw = client.post("/places/nearby", content='{"lat": -6.2, "lng": 106.8, "heading": NaN, "speed": "abc"}',
                      headers={"content-type": "application/json"})
    assert raw.status_code == 200


def test_unknown_fields_are_ignored():
    r = make_client().post("/places/nearby", json={"lat": -6.2, "lng": 106.8, "foo": "bar", "provider": "google"})
    assert r.status_code == 200


@pytest.mark.parametrize("payload", [
    {"lat": 0, "lng": 0},
    {"latitude": 0.0, "longitude": 0.0},
    {"lat": 91, "lng": 106.8},
    {"lat": -6.2, "lng": 181},
    {"lat": -6.2},
    {"lng": 106.8},
    {},
    {"lat": "bukan angka", "lng": 106.8},
    {"lat": -6.2, "lng": 106.8, "category": "kolam_renang"},
    {"lat": -6.2, "lng": 106.8, "limit": 0},
    {"lat": -6.2, "lng": 106.8, "limit": 11},
    {"lat": -6.2, "lng": 106.8, "radius_m": 50},
    {"lat": -6.2, "lng": 106.8, "radius_m": 60000},
])
def test_invalid_requests_get_422(payload):
    r = make_client().post("/places/nearby", json=payload)
    assert r.status_code == 422
    assert isinstance(r.json()["detail"], list) and r.json()["detail"][0]["msg"]


def test_null_island_message_is_readable():
    r = make_client().post("/places/nearby", json={"lat": 0, "lng": 0})
    assert "Koordinat (0, 0) ditolak" in r.json()["detail"][0]["msg"]


def test_nan_latitude_is_rejected():
    r = make_client().post("/places/nearby", content='{"lat": NaN, "lng": 106.8}',
                           headers={"content-type": "application/json"})
    assert r.status_code == 422


def test_malformed_json_gets_422():
    r = make_client().post("/places/nearby", content="{bukan json", headers={"content-type": "application/json"})
    assert r.status_code == 422


def test_get_is_not_allowed_so_coordinates_never_reach_urls():
    r = make_client().get("/places/nearby", params={"lat": -6.2, "lng": 106.8})
    assert r.status_code == 405


def test_provider_failure_is_http_200_with_degraded_flag():
    client, _ = google_client(StubProvider(error=PlacesError("auth", "API key not valid", status=400)))
    r = client.post("/places/nearby", json={"lat": -6.2, "lng": 106.8, "category": "minimarket"})
    assert r.status_code == 200
    body = r.json()
    assert body["degraded"] is True and body["errors"] == {"minimarket": "auth"} and body["results"] == []
    assert SECRET not in r.text


def test_unexpected_bug_is_http_500_without_details(monkeypatch, caplog):
    async def boom(self, req):
        raise RuntimeError("rahasia internal xyz")

    monkeypatch.setattr(PlacesService, "nearby", boom)
    client = make_client(raise_server_exceptions=False)
    with caplog.at_level(logging.ERROR):
        r = client.post("/places/nearby", json={"lat": -6.2, "lng": 106.8})
    assert r.status_code == 500 and r.json() == {"detail": {"error": "internal"}}
    assert "rahasia internal xyz" not in r.text
    assert "error tak terduga" in caplog.text and "rahasia internal xyz" in caplog.text  # tapi tercatat di log server


def test_coordinates_are_never_logged(caplog):
    with caplog.at_level(logging.DEBUG):
        r = make_client().post("/places/nearby", json={"lat": -7.123456, "lng": 110.654321, "category": "all"})
    assert r.status_code == 200
    assert "7.1234" not in caplog.text and "110.6543" not in caplog.text
    assert "[PLACES]" in caplog.text  # log ringkas tetap ada


# ---------------------------------------------------------------------------
# Pembatasan laju
# ---------------------------------------------------------------------------
def test_per_client_rate_limit_returns_429_with_retry_after():
    clock = Clock()
    client, _ = google_client(clock=clock, PLACES_RATE_PER_CLIENT_PER_MIN="3")
    payload = {"lat": -6.2, "lng": 106.8, "category": "minimarket"}
    assert [client.post("/places/nearby", json=payload).status_code for _ in range(3)] == [200, 200, 200]
    blocked = client.post("/places/nearby", json=payload)
    assert blocked.status_code == 429
    retry = int(blocked.headers["retry-after"])
    assert 1 <= retry <= 60
    assert blocked.json()["detail"] == {"error": "rate_limited", "retry_after_s": retry}
    clock.now += 61
    assert client.post("/places/nearby", json=payload).status_code == 200


def test_global_rate_limit_applies_across_clients():
    client, _ = google_client(PLACES_RATE_GLOBAL_PER_MIN="2", PLACES_RATE_PER_CLIENT_PER_MIN="100")
    payload = {"lat": -6.2, "lng": 106.8, "category": "minimarket"}
    codes = [client.post("/places/nearby", json=payload).status_code for _ in range(3)]
    assert codes == [200, 200, 429]


def test_invalid_requests_do_not_consume_rate_limit():
    client, _ = google_client(PLACES_RATE_PER_CLIENT_PER_MIN="2")
    for _ in range(5):
        assert client.post("/places/nearby", json={"lat": 0, "lng": 0}).status_code == 422
    assert client.post("/places/nearby", json={"lat": -6.2, "lng": 106.8}).status_code == 200


def test_rate_limit_can_be_disabled():
    client, _ = google_client(PLACES_RATE_PER_CLIENT_PER_MIN="0", PLACES_RATE_GLOBAL_PER_MIN="0")
    assert all(client.post("/places/nearby", json={"lat": -6.2, "lng": 106.8, "category": "minimarket"}).status_code
               == 200 for _ in range(30))


# ---------------------------------------------------------------------------
# Belum dikonfigurasi
# ---------------------------------------------------------------------------
def test_not_configured_returns_503_but_server_keeps_running():
    client = make_client({"PLACES_PROVIDER": "google"})  # tanpa API key
    r = client.post("/places/nearby", json={"lat": -6.2, "lng": 106.8})
    assert r.status_code == 503
    detail = r.json()["detail"]
    assert detail["error"] == "places_not_configured" and "GOOGLE_PLACES_API_KEY" in detail["message"]
    health = client.get("/places/health").json()
    assert health["status"] == "not_configured" and "GOOGLE_PLACES_API_KEY" in health["problem"]
    assert "usage" not in health
    assert client.get("/places/categories").status_code == 200  # endpoint lain tetap hidup


def test_unknown_provider_is_a_clear_problem_not_a_crash():
    client = make_client({"PLACES_PROVIDER": "bing"})
    assert client.post("/places/nearby", json={"lat": -6.2, "lng": 106.8}).status_code == 503
    assert "bing" in client.get("/places/health").json()["problem"]


# ---------------------------------------------------------------------------
# GET /places/categories dan /places/health
# ---------------------------------------------------------------------------
def test_categories_listing():
    r = make_client().get("/places/categories")
    assert r.status_code == 200
    rows = r.json()
    assert [x["key"] for x in rows] == ["all", "rest_area", "minimarket", "lodging", "spbu"]
    assert rows[0] == {"key": "all", "label": "Semua terdekat", "default_radius_m": None, "in_all": False}
    by_key = {x["key"]: x for x in rows}
    assert by_key["rest_area"]["default_radius_m"] == 50000 and by_key["rest_area"]["in_all"] is True
    assert by_key["spbu"]["in_all"] is False


def test_health_never_reveals_the_api_key():
    client, _ = google_client()
    r = client.get("/places/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok" and body["provider"] == "google" and body["api_key_configured"] is True
    assert body["google_host"] == "places.googleapis.com" and body["problem"] is None
    assert SECRET not in r.text
    assert body["usage"]["google"]["today"] == 0 and body["cache_entries"] == 0


def test_health_reports_usage_and_cache_after_a_search():
    client, _ = google_client()
    client.post("/places/nearby", json={"lat": -6.2, "lng": 106.8, "category": "minimarket"})
    body = client.get("/places/health").json()
    assert body["usage"]["google"]["today"] == 1 and body["cache_entries"] == 1


def test_health_in_mock_mode_explains_it():
    body = make_client().get("/places/health").json()
    assert body["status"] == "ok" and body["provider"] == "mock"
    assert any("MOCK" in note for note in body["notes"])


def test_shallow_health_does_not_call_the_provider():
    client, provider = google_client()
    client.get("/places/health")
    assert provider.calls == 0


def test_deep_health_probes_once_and_is_cached_for_a_minute():
    clock = Clock()
    client, provider = google_client(clock=clock)
    first = client.get("/places/health", params={"deep": "true"}).json()
    assert first["reachable"] is True and first["sample_count"] == 1 and "latency_ms" in first
    assert provider.calls == 1
    client.get("/places/health", params={"deep": "true"})
    assert provider.calls == 1  # dalam 60 detik: jawaban disimpan, tidak memakai jatah lagi
    clock.now += 61
    client.get("/places/health", params={"deep": "true"})
    assert provider.calls == 2


def test_deep_health_explains_google_failures():
    provider = StubProvider(error=PlacesError("auth", "API key not valid", status=400, hint="Google tidak mengenali key"))
    client, _ = google_client(provider)
    body = client.get("/places/health", params={"deep": "true"}).json()
    assert body["reachable"] is False and body["error"] == "auth" and body["http_status"] == 400
    assert body["hint"] == "Google tidak mengenali key"
    assert SECRET not in client.get("/places/health", params={"deep": "true"}).text


def test_openapi_documents_the_endpoints():
    spec = make_client().get("/openapi.json").json()
    assert {"/places/nearby", "/places/categories", "/places/health"} <= set(spec["paths"])
    assert "post" in spec["paths"]["/places/nearby"] and "get" not in spec["paths"]["/places/nearby"]
    assert {"200", "422", "429", "503"} <= set(spec["paths"]["/places/nearby"]["post"]["responses"])
