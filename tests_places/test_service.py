"""Tes alur pencarian (PlacesService) dengan provider palsu: cache, cadangan, jatah, urutan, arah, ringkasan."""
import asyncio
import logging

import pytest

from conftest import run
from nearby_places import categories
from nearby_places.cache import NearbyCache
from nearby_places.config import load_settings
from nearby_places.geo import destination_point, haversine_m
from nearby_places.limits import UsageLedger
from nearby_places.providers.base import BaseProvider, Place, PlacesError
from nearby_places.schemas import NearbyRequest
from nearby_places.service import (FALLBACK_SUMMARY, MAX_NAME_CHARS, PlacesService, clean_name, navigate_url,
                                   search_url)

HERE = (-6.2, 106.8)


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class FakeProvider(BaseProvider):
    """results: kategori -> daftar Place, atau Exception yang dilempar."""

    def __init__(self, name, results=None, max_concurrency=3, delay=0.0):
        self.name = name
        self.max_concurrency = max_concurrency
        self.results = dict(results or {})
        self.delay = delay
        self.calls = []
        self.in_flight = 0
        self.peak = 0

    async def search(self, category, lat, lng, radius_m, budget):
        budget.take()
        self.calls.append((category.key, lat, lng, radius_m))
        self.in_flight += 1
        self.peak = max(self.peak, self.in_flight)
        try:
            if self.delay:
                await asyncio.sleep(self.delay)
            outcome = self.results.get(category.key, [])
            if isinstance(outcome, BaseException):
                raise outcome
            return list(outcome)
        finally:
            self.in_flight -= 1


def place(pid, bearing=0, meters=1000, name=None, origin=HERE, **extra):
    lat, lng = destination_point(origin[0], origin[1], bearing, meters)
    return Place(id=pid, name=name if name is not None else f"Tempat {pid}", lat=lat, lng=lng, **extra)


def make_service(google=None, osm=None, **env):
    base = {"PLACES_PROVIDER": "google", "GOOGLE_PLACES_API_KEY": "k-test", "PLACES_USAGE_FILE": "off"}
    if osm is not None:
        base["PLACES_FALLBACK_PROVIDER"] = "osm"
    settings = load_settings({**base, **env})
    providers = {"google": google if google is not None else FakeProvider("google")}
    if osm is not None:
        providers["osm"] = osm
    clock = Clock()
    cache = NearbyCache(settings.cache_ttl_s, settings.cache_tolerance_m, settings.cache_max_entries, clock)
    ledger = UsageLedger(None, settings.tz_offset_hours, wall_clock=lambda: 1_760_000_000.0)
    service = PlacesService(settings, providers, ledger, cache)
    service.test_clock = clock
    return service


def req(lat=HERE[0], lng=HERE[1], **kw):
    return NearbyRequest(lat=lat, lng=lng, **kw)


def nearby(service, **kw):
    return run(service.nearby(req(**kw)))


# ---------------------------------------------------------------------------
# Urutan, jarak, arah
# ---------------------------------------------------------------------------
def test_results_are_sorted_by_distance_and_recomputed():
    google = FakeProvider("google", {"minimarket": [
        place("far", 0, 2600), place("near", 90, 300), place("mid", 180, 1200)]})
    response = nearby(make_service(google), category="minimarket")
    assert [r.id for r in response.results] == ["near", "mid", "far"]
    near, mid, far = response.results
    assert abs(near.distance_m - 300) <= 1 and near.distance_text == "300 m"
    assert abs(mid.distance_m - 1200) <= 1 and mid.distance_text == "1,2 km"
    assert far.distance_text == "2,6 km"
    assert abs(near.bearing_deg - 90) <= 1 and abs(mid.bearing_deg - 180) <= 1
    assert near.category == "minimarket" and near.category_label == "Minimarket"
    assert near.source == "google"


def test_places_outside_radius_are_dropped():
    google = FakeProvider("google", {"minimarket": [place("in", 0, 900), place("out", 0, 1100)]})
    response = nearby(make_service(google), category="minimarket", radius_m=1000)
    assert [r.id for r in response.results] == ["in"]


def test_provider_receives_default_radius_per_category():
    google = FakeProvider("google")
    nearby(make_service(google), category="all")
    radii = {call[0]: call[3] for call in google.calls}
    assert radii == {"rest_area": 50000, "minimarket": 3000, "lodging": 25000}


def test_requested_radius_is_capped_by_setting():
    google = FakeProvider("google")
    nearby(make_service(google, PLACES_MAX_RADIUS_M="20000"), category="rest_area", radius_m=40000)
    assert google.calls[0][3] == 20000


def test_duplicates_by_id_are_removed():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 500), place("a", 0, 500), place("b", 90, 800)]})
    response = nearby(make_service(google), category="minimarket")
    assert [r.id for r in response.results] == ["a", "b"]


def test_limit_applies_per_category():
    google = FakeProvider("google", {key: [place(f"{key}-{i}", 0, 100 + i * 10) for i in range(4)]
                                     for key in ("rest_area", "minimarket", "lodging")})
    response = nearby(make_service(google), category="all", limit=2)
    assert len(response.results) == 6
    per_category = {}
    for r in response.results:
        per_category.setdefault(r.category, []).append(r.id)
    assert {k: len(v) for k, v in per_category.items()} == {"rest_area": 2, "minimarket": 2, "lodging": 2}


def test_all_excludes_spbu_but_spbu_can_be_requested():
    google = FakeProvider("google", {"spbu": [place("s", 0, 500)]})
    service = make_service(google)
    nearby(service, category="all")
    assert "spbu" not in {c[0] for c in google.calls}
    google.calls.clear()
    response = nearby(service, category="spbu")
    assert [c[0] for c in google.calls] == ["spbu"] and response.results[0].category == "spbu"


def test_ahead_flag_uses_heading():
    google = FakeProvider("google", {"minimarket": [place("n", 0, 500), place("s", 180, 400),
                                                    place("e", 90, 300), place("w", 270, 200)]})
    response = nearby(make_service(google), category="minimarket", heading_deg=0, speed_mps=20)
    ahead = {r.id: r.ahead for r in response.results}
    assert ahead == {"n": True, "s": False, "e": False, "w": False}  # tepat 90 derajat = bukan "di depan"


def test_ahead_is_unknown_without_trusted_heading():
    google = FakeProvider("google", {"minimarket": [place("n", 0, 500)]})
    service = make_service(google)
    assert nearby(service, category="minimarket").results[0].ahead is None
    assert nearby(service, category="minimarket", heading_deg=0, speed_mps=0.3).results[0].ahead is None
    assert nearby(service, category="minimarket", heading_deg=0, speed_mps=10).results[0].ahead is True


def test_prefer_ahead_puts_ahead_first_even_if_farther():
    google = FakeProvider("google", {"minimarket": [place("behind", 180, 200), place("ahead", 0, 900)]})
    service = make_service(google)
    plain = nearby(service, category="minimarket", heading_deg=0, speed_mps=20)
    assert [r.id for r in plain.results] == ["behind", "ahead"]
    preferred = nearby(service, category="minimarket", heading_deg=0, speed_mps=20, prefer_ahead=True)
    assert [r.id for r in preferred.results] == ["ahead", "behind"]
    # tanpa arah gerak, prefer_ahead tidak mengubah urutan
    unknown = nearby(service, category="minimarket", prefer_ahead=True)
    assert [r.id for r in unknown.results] == ["behind", "ahead"]


# ---------------------------------------------------------------------------
# Bersih-bersih data pihak ketiga & tautan
# ---------------------------------------------------------------------------
def test_clean_name():
    assert clean_name("  Rest\x00Area\n\tKM   10  ") == "Rest Area KM 10"
    assert clean_name("x" * 200) == "x" * MAX_NAME_CHARS
    assert clean_name("") == "" and clean_name(None) == ""
    assert len(clean_name("a" * 79 + "  b" * 20)) <= MAX_NAME_CHARS


def test_empty_name_gets_placeholder():
    google = FakeProvider("google", {"rest_area": [place("a", 0, 500, name="")]})
    response = nearby(make_service(google), category="rest_area")
    assert response.results[0].name == "Rest area (tanpa nama)"


def test_urls():
    p = Place(id="ChIJabc", name="X", lat=-6.15, lng=106.8)
    assert navigate_url(p, "google") == (
        "https://www.google.com/maps/dir/?api=1&destination=-6.150000,106.800000&travelmode=driving"
        "&destination_place_id=ChIJabc")
    assert navigate_url(p, "osm") == (
        "https://www.google.com/maps/dir/?api=1&destination=-6.150000,106.800000&travelmode=driving")
    assert search_url(p) == "https://www.google.com/maps/search/?api=1&query=-6.150000,106.800000"


def test_navigate_url_has_no_api_key_and_maps_url_falls_back_to_search():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 500), place("b", 90, 600, maps_url="https://maps.google.com/?cid=1")]})
    response = nearby(make_service(google), category="minimarket")
    a, b = response.results
    assert "k-test" not in a.navigate_url and "key=" not in a.navigate_url
    assert a.navigate_url.startswith("https://www.google.com/maps/dir/?api=1&destination=")
    assert a.maps_url.startswith("https://www.google.com/maps/search/?api=1&query=")
    assert b.maps_url == "https://maps.google.com/?cid=1"


def test_open_now_and_rating_pass_through():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 500, open_now=True, rating=4.5, address="Jl. A")]})
    r = nearby(make_service(google), category="minimarket").results[0]
    assert (r.open_now, r.rating, r.address) == (True, 4.5, "Jl. A")


# ---------------------------------------------------------------------------
# Ringkasan suara
# ---------------------------------------------------------------------------
def test_summary_with_results_ahead_behind_and_unknown():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 350, name="Alfamart Satu")]})
    service = make_service(google)
    assert nearby(service, category="minimarket").summary == "Minimarket terdekat: Alfamart Satu, sekitar 350 meter."
    assert nearby(service, category="minimarket", heading_deg=0, speed_mps=20).summary == (
        "Minimarket terdekat: Alfamart Satu, sekitar 350 meter di depan.")
    assert nearby(service, category="minimarket", heading_deg=180, speed_mps=20).summary == (
        "Minimarket terdekat: Alfamart Satu, sekitar 350 meter di belakang.")


def test_summary_when_nothing_found():
    response = nearby(make_service(FakeProvider("google")), category="minimarket")
    assert response.results == [] and not response.degraded
    assert response.summary == "Tidak ada minimarket dalam 3 kilometer."


def test_summary_all_categories_combined():
    google = FakeProvider("google", {
        "rest_area": [place("r", 0, 2300, name="Rest Area KM 57")],
        "lodging": [place("h", 90, 3100, name="Hotel Indah")],
    })
    response = nearby(make_service(google), category="all")
    assert response.summary == ("Rest area terdekat: Rest Area KM 57, sekitar 2,3 kilometer. "
                                "Tidak ada minimarket dalam 3 kilometer. "
                                "Hotel atau penginapan terdekat: Hotel Indah, sekitar 3,1 kilometer.")


def test_summary_mentions_failed_category_and_all_failed_uses_safe_message():
    google = FakeProvider("google", {"rest_area": [place("r", 0, 2300, name="Rest Area KM 57")],
                                     "minimarket": PlacesError("timeout", "lambat")})
    partial = nearby(make_service(google), category="all")
    assert "Pencarian minimarket lagi bermasalah." in partial.summary
    assert "Rest area terdekat: Rest Area KM 57" in partial.summary

    broken = FakeProvider("google", {k: PlacesError("network", "putus") for k in ("rest_area", "minimarket", "lodging")})
    response = nearby(make_service(broken), category="all")
    assert response.summary == FALLBACK_SUMMARY and response.degraded


def test_long_name_in_summary_is_shortened():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 350, name="N" * 70)]})
    summary = nearby(make_service(google), category="minimarket").summary
    assert "N" * 50 in summary and "N" * 51 not in summary


def test_low_accuracy_warning():
    service = make_service(FakeProvider("google"))
    assert nearby(service, category="minimarket", accuracy_m=50).warnings == []
    warned = nearby(service, category="minimarket", accuracy_m=2500).warnings
    assert len(warned) == 1 and "Akurasi lokasi rendah" in warned[0] and "2,5 km" in warned[0]


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------
def test_second_identical_request_is_served_from_cache():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 500)]})
    service = make_service(google)
    first = nearby(service, category="minimarket")
    second = nearby(service, category="minimarket")
    assert len(google.calls) == 1
    assert (first.cached, second.cached) == (False, True)
    assert [r.id for r in second.results] == ["a"]


def test_cache_expires_after_ttl():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 500)]})
    service = make_service(google, PLACES_CACHE_TTL_S="60")
    nearby(service, category="minimarket")
    service.test_clock.now += 61
    nearby(service, category="minimarket")
    assert len(google.calls) == 2


def test_nearby_position_reuses_cache_but_distance_is_recomputed():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 1000)]})
    service = make_service(google)
    first = nearby(service, category="minimarket")
    moved = destination_point(HERE[0], HERE[1], 0, 100)  # maju 100 m ke arah tempat itu
    second = run(service.nearby(req(lat=moved[0], lng=moved[1], category="minimarket")))
    assert len(google.calls) == 1 and second.cached
    assert first.results[0].distance_m - second.results[0].distance_m in range(98, 103)


def test_far_position_misses_cache():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 1000)]})
    service = make_service(google)
    nearby(service, category="minimarket")
    moved = destination_point(HERE[0], HERE[1], 0, 600)
    run(service.nearby(req(lat=moved[0], lng=moved[1], category="minimarket")))
    assert len(google.calls) == 2


def test_empty_result_is_cached_too():
    google = FakeProvider("google")
    service = make_service(google)
    nearby(service, category="minimarket")
    assert nearby(service, category="minimarket").cached
    assert len(google.calls) == 1


def test_failures_are_not_cached():
    google = FakeProvider("google", {"minimarket": PlacesError("upstream", "sibuk")})
    service = make_service(google)
    nearby(service, category="minimarket")
    google.results["minimarket"] = [place("a", 0, 500)]
    response = nearby(service, category="minimarket")
    assert len(google.calls) == 2 and response.results and not response.degraded


def test_cache_is_per_category_and_radius():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 500)], "spbu": [place("s", 0, 500)]})
    service = make_service(google)
    nearby(service, category="minimarket")
    nearby(service, category="spbu")
    nearby(service, category="minimarket", radius_m=1000)
    assert len(google.calls) == 3


# ---------------------------------------------------------------------------
# Kegagalan, cadangan, jatah
# ---------------------------------------------------------------------------
def test_failure_without_fallback_is_degraded_not_an_exception():
    google = FakeProvider("google", {"minimarket": PlacesError("auth", "key salah", status=400)})
    response = nearby(make_service(google), category="minimarket")
    assert response.degraded and response.errors == {"minimarket": "auth"}
    assert response.results == [] and not response.cached


def test_fallback_provider_is_used_when_primary_fails():
    google = FakeProvider("google", {"minimarket": PlacesError("upstream", "sibuk", status=503)})
    osm = FakeProvider("osm", {"minimarket": [place("osm:node/1", 0, 400)]}, max_concurrency=1)
    response = nearby(make_service(google, osm), category="minimarket")
    assert not response.degraded and response.errors == {}
    assert response.fallback_used and response.provider == "google"
    assert response.results[0].source == "osm"
    assert "google.com/maps/dir" in response.results[0].navigate_url  # OSM pun diarahkan lewat Google Maps
    assert "destination_place_id" not in response.results[0].navigate_url


def test_error_reported_is_the_primary_providers():
    google = FakeProvider("google", {"minimarket": PlacesError("auth", "key salah")})
    osm = FakeProvider("osm", {"minimarket": PlacesError("timeout", "lambat")}, max_concurrency=1)
    response = nearby(make_service(google, osm), category="minimarket")
    assert response.errors == {"minimarket": "auth"} and response.degraded


def test_cached_fallback_result_spares_the_failing_primary():
    google = FakeProvider("google", {"minimarket": PlacesError("rate_limited", "kuota")})
    osm = FakeProvider("osm", {"minimarket": [place("osm:node/1", 0, 400)]}, max_concurrency=1)
    service = make_service(google, osm)
    nearby(service, category="minimarket")
    second = nearby(service, category="minimarket")
    assert len(google.calls) == 1 and len(osm.calls) == 1  # primer tidak dicoba lagi selama hasil cadangan masih segar
    assert second.cached and second.fallback_used


def test_unexpected_exception_is_contained_and_logged(caplog):
    google = FakeProvider("google", {"minimarket": ValueError("bug di provider")})
    osm = FakeProvider("osm", {"minimarket": [place("osm:node/1", 0, 400)]}, max_concurrency=1)
    with caplog.at_level(logging.ERROR):
        response = nearby(make_service(google, osm), category="minimarket")
    assert response.results and response.fallback_used
    assert "error tak terduga" in caplog.text and "bug di provider" in caplog.text

    alone = nearby(make_service(FakeProvider("google", {"minimarket": ValueError("x")})), category="minimarket")
    assert alone.errors == {"minimarket": "internal"} and alone.degraded


def test_one_failed_category_does_not_hide_the_others():
    google = FakeProvider("google", {"rest_area": PlacesError("timeout", "lambat"),
                                     "minimarket": [place("m", 0, 500)]})
    response = nearby(make_service(google), category="all")
    assert response.degraded and response.errors == {"rest_area": "timeout"}
    assert [r.id for r in response.results] == ["m"]


def test_daily_budget_stops_calls_to_google():
    google = FakeProvider("google", {k: [place(f"{k}-1", 0, 500)] for k in ("rest_area", "minimarket", "lodging")})
    service = make_service(google, PLACES_GOOGLE_DAILY_BUDGET="2")
    response = nearby(service, category="all")
    assert len(google.calls) == 2
    assert response.degraded and list(response.errors.values()) == ["budget_exhausted"]
    assert service.usage()["google"] == {"today": 2, "daily_limit": 2, "month": 2, "monthly_limit": 4500}
    # permintaan berikutnya (cache untuk dua kategori, satu kategori masih gagal) tidak menambah pemakaian
    nearby(service, category="all")
    assert service.usage()["google"]["today"] == 2


def test_budget_exhaustion_falls_back_to_osm():
    google = FakeProvider("google", {k: [place(f"g-{k}", 0, 500)] for k in ("rest_area", "minimarket", "lodging")})
    osm = FakeProvider("osm", {k: [place(f"o-{k}", 0, 600)] for k in ("rest_area", "minimarket", "lodging")},
                       max_concurrency=1)
    response = nearby(make_service(google, osm, PLACES_GOOGLE_DAILY_BUDGET="2"), category="all")
    assert not response.degraded and response.fallback_used
    assert sorted(r.source for r in response.results) == ["google", "google", "osm"]


def test_usage_reports_every_configured_provider():
    service = make_service(FakeProvider("google"), FakeProvider("osm", max_concurrency=1))
    nearby(service, category="minimarket")
    usage = service.usage()
    assert set(usage) == {"google", "osm"}
    assert usage["google"]["today"] == 1 and usage["osm"]["today"] == 0
    assert usage["osm"]["monthly_limit"] is None and usage["osm"]["daily_limit"] == 500


# ---------------------------------------------------------------------------
# Konkurensi & event loop
# ---------------------------------------------------------------------------
def test_provider_concurrency_limit_is_respected():
    narrow = FakeProvider("google", max_concurrency=1, delay=0.01)
    nearby(make_service(narrow), category="all")
    assert narrow.peak == 1
    wide = FakeProvider("google", max_concurrency=3, delay=0.01)
    nearby(make_service(wide), category="all")
    assert wide.peak == 3


def test_service_survives_being_used_from_different_event_loops():
    google = FakeProvider("google", {"minimarket": [place("a", 0, 500)]}, delay=0.001)
    service = make_service(google, PLACES_CACHE_TTL_S="0")
    for _ in range(3):  # setiap run() = event loop baru (Python 3.9 mengikat semaphore ke loop)
        assert nearby(service, category="all").results


def test_probe_success_and_failure():
    ok_provider = FakeProvider("google", {"minimarket": [place("a", 0, 500), place("b", 0, 600)]})
    result = run(make_service(ok_provider).probe())
    assert result["reachable"] is True and result["sample_count"] == 2 and "latency_ms" in result

    bad = FakeProvider("google", {"minimarket": PlacesError("auth", "API key not valid", status=400, hint="ganti key")})
    failed = run(make_service(bad).probe())
    assert failed["reachable"] is False and failed["error"] == "auth"
    assert failed["http_status"] == 400 and failed["hint"] == "ganti key"


def test_probe_uses_a_budget_slot():
    google = FakeProvider("google")
    service = make_service(google)
    run(service.probe())
    assert service.usage()["google"]["today"] == 1


def test_missing_provider_is_rejected_at_startup():
    settings = load_settings({"PLACES_PROVIDER": "google", "GOOGLE_PLACES_API_KEY": "k", "PLACES_USAGE_FILE": "off",
                              "PLACES_FALLBACK_PROVIDER": "osm"})
    with pytest.raises(ValueError, match="osm"):
        PlacesService(settings, {"google": FakeProvider("google")}, UsageLedger(None), NearbyCache())


def test_category_listing_matches_service_expansion():
    assert [c.key for c in categories.expand("all")] == ["rest_area", "minimarket", "lodging"]
    assert haversine_m(*HERE, *destination_point(HERE[0], HERE[1], 33, 1234)) == pytest.approx(1234, abs=0.5)
