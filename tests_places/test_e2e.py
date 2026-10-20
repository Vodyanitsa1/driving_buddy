"""Tes end-to-end lewat jaringan sungguhan (loopback).

Dua server uvicorn berjalan di thread: (1) server palsu yang meniru Google Places API (New) dan Overpass,
(2) aplikasi FastAPI kita dengan provider ASLI (httpx sungguhan). Jadi yang diuji termasuk header, FieldMask,
timeout, retry, 429, API key salah, billing mati, dan seterusnya, tanpa internet dan tanpa API key.
"""
import contextlib
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import httpx
import pytest
import uvicorn
from fastapi import FastAPI

from fake_places import API_KEY, CENTER, create_fake_places
from nearby_places import build_router
from nearby_places.config import load_settings
from nearby_places.geo import haversine_m
from nearby_places.providers import google as google_module

LAT, LNG = CENTER

PRO_MASK = ("places.id,places.displayName,places.formattedAddress,places.location,places.googleMapsUri,"
            "places.businessStatus,places.primaryType")


class Running:
    """Satu server uvicorn di thread sendiri, di port acak yang sudah di-bind lebih dulu (tanpa balapan port)."""

    def __init__(self, app):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        config = uvicorn.Config(app, host="127.0.0.1", port=self.port, log_level="error", lifespan="off")
        self.server = uvicorn.Server(config)
        self.thread = threading.Thread(target=self.server.run, kwargs={"sockets": [self.sock]}, daemon=True)

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}"

    def start(self):
        self.thread.start()
        deadline = time.time() + 10
        while not self.server.started:
            if time.time() > deadline:
                raise RuntimeError("server tes tidak mau start")
            time.sleep(0.01)
        return self

    def stop(self):
        self.server.should_exit = True
        self.thread.join(timeout=10)
        self.sock.close()


@pytest.fixture(scope="module")
def upstream():
    running = Running(create_fake_places()).start()
    yield running
    running.stop()


@pytest.fixture(autouse=True)
def fast_retries(monkeypatch):
    monkeypatch.setattr(google_module, "BACKOFF_S", 0.0)


def set_mode(upstream, **modes):
    assert httpx.post(f"{upstream.url}/_mode", json=modes).status_code == 200


def state(upstream):
    return httpx.get(f"{upstream.url}/_state").json()


@contextlib.contextmanager
def our_app(env):
    settings = load_settings({"PLACES_USAGE_FILE": "off", **env})
    app = FastAPI()
    app.include_router(build_router(settings=settings))
    running = Running(app).start()
    client = httpx.Client(base_url=running.url, timeout=15)
    try:
        yield client
    finally:
        client.close()
        running.stop()


def google_env(upstream, **extra):
    return {"PLACES_PROVIDER": "google", "GOOGLE_PLACES_API_KEY": API_KEY,
            "GOOGLE_PLACES_BASE_URL": f"{upstream.url}/v1", "PLACES_TIMEOUT_S": "2", **extra}


def with_osm(upstream, **extra):
    return {"PLACES_OSM_URL": f"{upstream.url}/api/interpreter", **extra}


def ask(client, category="all", **extra):
    body = {"lat": LAT, "lng": LNG, "category": category, "limit": 5, **extra}
    response = client.post("/places/nearby", json=body)
    assert response.status_code == 200, response.text
    return response.json()


def by_category(body):
    grouped = {}
    for item in body["results"]:
        grouped.setdefault(item["category"], []).append(item)
    return grouped


# ---------------------------------------------------------------------------
# Google
# ---------------------------------------------------------------------------
def test_google_happy_path_sorted_by_distance_with_correct_requests(upstream):
    set_mode(upstream, google="ok")
    with our_app(google_env(upstream)) as client:
        body = ask(client, "all")
    assert body["degraded"] is False and body["errors"] == {} and body["provider"] == "google"

    groups = by_category(body)
    assert [x["id"] for x in groups["rest_area"]] == ["rest-1", "rest-2"]  # rest-far (66 km) di luar radius 50 km
    assert [x["id"] for x in groups["minimarket"]] == ["mini-1", "mini-2", "mini-3", "mini-4", "mini-5"]
    assert [x["id"] for x in groups["lodging"]] == ["hotel-1", "motel-1", "guest-1"]  # hotel-closed dibuang
    for item in body["results"]:
        assert item["source"] == "google"
        assert abs(item["distance_m"] - haversine_m(LAT, LNG, item["lat"], item["lng"])) <= 1
        assert item["navigate_url"].endswith("&destination_place_id=" + item["id"])
        assert item["open_now"] is None and item["rating"] is None  # field mahal tidak diminta

    calls = state(upstream)["google_requests"]
    assert len(calls) == 3
    for call in calls:
        assert call["headers"]["x-goog-api-key"] == API_KEY
        assert call["headers"]["x-goog-fieldmask"] == PRO_MASK  # tier Pro saja
        assert call["query"] == ""  # API key tidak pernah di URL
        request = call["body"]
        assert request["rankPreference"] == "DISTANCE" and request["maxResultCount"] == 20
        assert request["languageCode"] == "id" and request["regionCode"] == "ID"
        assert isinstance(request["locationRestriction"]["circle"]["radius"], float)
    types = sorted(tuple(c["body"]["includedTypes"]) for c in calls)
    assert types == [("convenience_store",), ("hotel", "motel", "guest_house", "lodging"), ("rest_stop",)]


def test_rating_and_hours_only_when_enabled(upstream):
    set_mode(upstream, google="ok")
    with our_app(google_env(upstream, PLACES_GOOGLE_RATING_HOURS="true")) as client:
        body = ask(client, "minimarket")
        health = client.get("/places/health").json()
    assert body["results"][0]["rating"] == 4.3 and body["results"][0]["open_now"] is True
    mask = state(upstream)["google_requests"][0]["headers"]["x-goog-fieldmask"]
    assert mask == PRO_MASK + ",places.rating,places.currentOpeningHours"
    assert health["usage"]["google"]["monthly_limit"] == 900  # jatah gratis tier Enterprise lebih kecil


def test_second_identical_request_never_reaches_google(upstream):
    set_mode(upstream, google="ok")
    with our_app(google_env(upstream)) as client:
        first = ask(client, "minimarket")
        second = ask(client, "minimarket")
        health = client.get("/places/health").json()
    assert (first["cached"], second["cached"]) == (False, True)
    assert state(upstream)["google_calls"] == 1
    assert [x["id"] for x in second["results"]] == [x["id"] for x in first["results"]]
    assert health["usage"]["google"]["today"] == 1 and health["cache_entries"] == 1


def test_heading_marks_places_ahead_and_prefer_ahead_reorders(upstream):
    set_mode(upstream, google="ok")
    with our_app(google_env(upstream)) as client:
        plain = ask(client, "rest_area", heading_deg=180, speed_mps=25)
        preferred = ask(client, "rest_area", heading_deg=180, speed_mps=25, prefer_ahead=True)
    assert [x["id"] for x in plain["results"]] == ["rest-1", "rest-2"]  # rest-1 di utara (belakang), rest-2 di selatan
    assert [x["ahead"] for x in plain["results"]] == [False, True]
    assert [x["id"] for x in preferred["results"]] == ["rest-2", "rest-1"]
    assert "di depan" in preferred["summary"]


def test_google_500_is_retried_once_then_osm_fallback(upstream):
    set_mode(upstream, google="500", osm="ok")
    with our_app(google_env(upstream, **with_osm(upstream, PLACES_FALLBACK_PROVIDER="osm"))) as client:
        body = ask(client, "minimarket")
    assert body["degraded"] is False and body["fallback_used"] is True and body["provider"] == "google"
    assert body["results"] and all(x["source"] == "osm" for x in body["results"])
    snapshot = state(upstream)
    assert snapshot["google_calls"] == 2 and snapshot["osm_calls"] == 1  # 1 percobaan + 1 retry, lalu cadangan
    assert "driving-buddy" in snapshot["osm_requests"][0]["user_agent"]


def test_invalid_key_is_auth_error_without_retry_and_health_explains(upstream):
    set_mode(upstream, google="invalid_key")
    with our_app(google_env(upstream)) as client:
        body = ask(client, "minimarket")
        deep = client.get("/places/health", params={"deep": "true"}).json()
    assert body["degraded"] is True and body["errors"] == {"minimarket": "auth"} and body["results"] == []
    assert state(upstream)["google_calls"] == 2  # 1 pencarian (tanpa retry) + 1 deep check
    assert deep["reachable"] is False and deep["error"] == "auth" and deep["http_status"] == 400
    assert "API key" in deep["hint"]
    assert API_KEY not in str(deep) and API_KEY not in str(body)


@pytest.mark.parametrize("mode,hint_part", [("service_disabled", "enable"), ("billing_disabled", "Billing")])
def test_setup_mistakes_get_actionable_hints(upstream, mode, hint_part):
    set_mode(upstream, google=mode)
    with our_app(google_env(upstream)) as client:
        deep = client.get("/places/health", params={"deep": "true"}).json()
        body = ask(client, "minimarket")
    assert deep["reachable"] is False and deep["error"] == "auth" and hint_part in deep["hint"]
    assert body["errors"] == {"minimarket": "auth"}


def test_google_429_is_rate_limited_and_not_retried_without_retry_after(upstream):
    set_mode(upstream, google="429")
    with our_app(google_env(upstream)) as client:
        body = ask(client, "minimarket")
    assert body["errors"] == {"minimarket": "rate_limited"} and body["degraded"] is True
    assert state(upstream)["google_calls"] == 1


def test_slow_google_times_out_and_driver_is_not_kept_waiting(upstream):
    set_mode(upstream, google="slow")  # fake menunggu 1,5 detik
    with our_app(google_env(upstream, PLACES_TIMEOUT_S="0.5")) as client:
        started = time.monotonic()
        body = ask(client, "minimarket")
        elapsed = time.monotonic() - started
    assert body["errors"] == {"minimarket": "timeout"} and body["degraded"] is True
    assert elapsed < 1.4
    assert state(upstream)["google_calls"] == 1  # timeout tidak diulang


def test_html_error_page_is_bad_response(upstream):
    set_mode(upstream, google="html")
    with our_app(google_env(upstream)) as client:
        body = ask(client, "minimarket")
    assert body["errors"] == {"minimarket": "bad_response"}
    assert state(upstream)["google_calls"] == 2  # diulang sekali


def test_budget_stops_calls_before_they_reach_google(upstream):
    set_mode(upstream, google="ok")
    with our_app(google_env(upstream, PLACES_GOOGLE_DAILY_BUDGET="2")) as client:
        body = ask(client, "all")
        health = client.get("/places/health").json()
    assert state(upstream)["google_calls"] == 2
    assert body["degraded"] is True and list(body["errors"].values()) == ["budget_exhausted"]
    assert len(by_category(body)) == 2  # dua kategori lain tetap menjawab
    assert health["usage"]["google"] == {"today": 2, "daily_limit": 2, "month": 2, "monthly_limit": 4500}


def test_unreachable_google_is_network_error(upstream):
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    dead_port = probe.getsockname()[1]
    probe.close()  # tidak ada yang mendengarkan di port ini
    env = google_env(upstream, GOOGLE_PLACES_BASE_URL=f"http://127.0.0.1:{dead_port}/v1")
    with our_app(env) as client:
        body = ask(client, "minimarket")
    assert body["errors"] == {"minimarket": "network"} and body["degraded"] is True


# ---------------------------------------------------------------------------
# OpenStreetMap (Overpass)
# ---------------------------------------------------------------------------
def test_osm_only_provider(upstream):
    set_mode(upstream, osm="ok")
    with our_app(with_osm(upstream, PLACES_PROVIDER="osm")) as client:
        body = ask(client, "rest_area")
        health = client.get("/places/health").json()
    assert body["provider"] == "osm" and body["degraded"] is False
    assert [x["name"] for x in body["results"]] == ["Rest Area KM 10 (fake)", "Rest Area KM 20 (fake)"]
    assert all(x["id"].startswith("osm:") and x["maps_url"].startswith("https://www.openstreetmap.org/")
               for x in body["results"])
    assert all("destination_place_id" not in x["navigate_url"] for x in body["results"])
    snapshot = state(upstream)
    assert snapshot["osm_calls"] == 1 and "around:50000," in snapshot["osm_requests"][0]["query"]
    assert snapshot["osm_requests"][0]["url_query"] == ""
    assert any("fair use" in n for n in health["notes"])


def test_osm_rate_limit_blocks_following_requests_locally(upstream):
    set_mode(upstream, osm="429")
    with our_app(with_osm(upstream, PLACES_PROVIDER="osm")) as client:
        first = ask(client, "minimarket")
        second = ask(client, "spbu")
    assert first["errors"] == {"minimarket": "rate_limited"} and second["errors"] == {"spbu": "rate_limited"}
    assert state(upstream)["osm_calls"] == 1  # permintaan kedua tidak sampai ke Overpass (jeda 30 detik)


def test_osm_dense_area_shrinks_radius_and_still_answers(upstream):
    set_mode(upstream, osm="many")
    with our_app(with_osm(upstream, PLACES_PROVIDER="osm")) as client:
        body = ask(client, "minimarket", radius_m=3000, limit=3)
    radii = [int(r["query"].split("around:")[1].split(",")[0]) for r in state(upstream)["osm_requests"]]
    assert radii == [3000, 1500, 750, 500]
    assert len(body["results"]) == 3 and body["degraded"] is False


def test_osm_runtime_error_remark_is_an_error_not_an_empty_answer(upstream):
    set_mode(upstream, osm="remark_timeout")
    with our_app(with_osm(upstream, PLACES_PROVIDER="osm")) as client:
        body = ask(client, "minimarket")
    assert body["errors"] == {"minimarket": "timeout"} and body["degraded"] is True
    assert "Tidak ada minimarket" not in body["summary"]


@pytest.mark.parametrize("mode,kind", [("504", "upstream"), ("html", "bad_response")])
def test_osm_failures(upstream, mode, kind):
    set_mode(upstream, osm=mode)
    with our_app(with_osm(upstream, PLACES_PROVIDER="osm")) as client:
        body = ask(client, "minimarket")
    assert body["errors"] == {"minimarket": kind}


# ---------------------------------------------------------------------------
# Beban & ketahanan
# ---------------------------------------------------------------------------
def test_many_concurrent_requests_all_succeed(upstream):
    set_mode(upstream, google="ok")
    with our_app(google_env(upstream, PLACES_RATE_PER_CLIENT_PER_MIN="1000", PLACES_RATE_GLOBAL_PER_MIN="1000")) as client:
        with ThreadPoolExecutor(max_workers=10) as pool:
            responses = list(pool.map(lambda _: client.post(
                "/places/nearby", json={"lat": LAT, "lng": LNG, "category": "all"}), range(20)))
    assert all(r.status_code == 200 for r in responses)
    assert all(not r.json()["degraded"] and len(r.json()["results"]) >= 3 for r in responses)
    assert state(upstream)["google_calls"] <= 20 * 3


def test_server_with_broken_config_still_serves_other_endpoints(upstream):
    with our_app({"PLACES_PROVIDER": "google"}) as client:  # tanpa API key
        assert client.post("/places/nearby", json={"lat": LAT, "lng": LNG}).status_code == 503
        assert client.get("/places/health").json()["status"] == "not_configured"
        assert client.get("/openapi.json").status_code == 200
