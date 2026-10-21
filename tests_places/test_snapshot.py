"""Tes data offline (provider snapshot) dan perbaikan curl lengket. Tanpa internet."""
import json
import os
from datetime import datetime, timezone

import pytest

from conftest import run
from nearby_places.cache import NearbyCache
from nearby_places.categories import CATEGORIES
from nearby_places.config import load_settings
from nearby_places.limits import UsageLedger
from nearby_places.providers import SnapshotProvider
from nearby_places.providers.base import NO_BUDGET, Place, PlacesError
from nearby_places.providers.snapshot import HINT_SNAPSHOT
from nearby_places.schemas import NearbyRequest
from nearby_places.service import PlacesService
from test_osm_v2 import A, ByHost, Clock, FakeRunner, curl_ok, make, node, search, tls_error

SEMARANG = (-6.99, 110.42)


def way(oid, lat, lng, **tags):
    return {"type": "way", "id": oid, "center": {"lat": lat, "lon": lng}, "tags": tags}


def elements():
    return [
        node(1, -6.98, 110.41, shop="convenience", name="Indomaret Pemuda"),
        node(2, -6.99, 110.42, amenity="fuel", shop="convenience", name="SPBU 44.501.01"),
        way(3, -7.10, 110.40, highway="services", name="Rest Area KM 429"),
        node(4, -6.985, 110.409, tourism="hotel", name="Hotel Ciputra"),
        node(5, -6.99, 110.43, tourism="guest_house"),
        node(6, -7.566, 110.816, shop="convenience", name="Alfamart Slamet Riyadi"),
        node(7, -6.99, 110.42, amenity="cafe", name="Kopi"),
        {"type": "node", "id": 8, "lat": None, "lon": 110.42, "tags": {"shop": "convenience"}},
        {"type": "relation", "id": 9, "tags": {"tourism": "motel"}},  # tanpa center: dibuang
        "bukan elemen",
    ]


def write(tmp_path, data, name="places_snapshot.json"):
    path = tmp_path / name
    path.write_text(data if isinstance(data, str) else json.dumps(data), encoding="utf-8")
    return path


def overpass(items=None, stamp="2026-10-20T12:00:00Z", **extra):
    data = {"version": 0.6, "generator": "Overpass API", "osm3s": {"timestamp_osm_base": stamp},
            "elements": elements() if items is None else items}
    data.update(extra)
    return data


def settings_for(path, provider="snapshot", **env):
    return load_settings({"PLACES_PROVIDER": provider, "PLACES_USAGE_FILE": "off",
                          "PLACES_SNAPSHOT_FILE": str(path), **env})


def provider_for(tmp_path, data=None, **env):
    path = write(tmp_path, overpass() if data is None else data)
    return SnapshotProvider(settings_for(path, **env))


def find(provider, category, lat=SEMARANG[0], lng=SEMARANG[1], radius=None):
    cat = CATEGORIES[category]
    return run(provider.search(cat, lat, lng, radius or cat.default_radius_m, NO_BUDGET))


# ---------------------------------------------------------------------------
# Konfigurasi
# ---------------------------------------------------------------------------
def test_snapshot_is_a_provider_and_a_fallback(tmp_path):
    path = write(tmp_path, overpass())
    main = settings_for(path)
    assert main.configured and main.provider == "snapshot" and main.snapshot_file == str(path)
    assert any("file offline" in n for n in main.notes)
    backup = settings_for(path, provider="osm", PLACES_FALLBACK_PROVIDER="snapshot")
    assert backup.configured and backup.fallback_provider == "snapshot"


def test_default_snapshot_file_is_in_repo_root():
    settings = load_settings({"PLACES_PROVIDER": "osm", "PLACES_USAGE_FILE": "off"})
    assert settings.snapshot_file.endswith("places_snapshot.json")
    assert os.path.isabs(settings.snapshot_file)


def test_missing_snapshot_file_is_a_note_not_a_problem(tmp_path):
    settings = settings_for(tmp_path / "belum_ada.json")
    assert settings.configured
    assert any("belum ada (belum_ada.json)" in n and "Data offline" in n for n in settings.notes)


# ---------------------------------------------------------------------------
# Memuat file
# ---------------------------------------------------------------------------
def test_loads_places_per_category(tmp_path):
    provider = provider_for(tmp_path)
    assert provider.problem is None
    counts = {key: len(items) for key, items in provider.places.items()}
    assert counts == {"rest_area": 1, "minimarket": 3, "lodging": 2, "spbu": 1}
    assert provider.count == 7  # SPBU yang juga minimarket dihitung di dua kategori
    assert provider.bbox == (-7.566, 110.40, -6.98, 110.816)
    rest = provider.places["rest_area"][0]
    assert (rest.id, rest.lat, rest.provider_type) == ("osm:way/3", -7.10, "highway=services")
    assert rest.maps_url == "https://www.openstreetmap.org/way/3"


def test_date_comes_from_overpass_timestamp_in_wib(tmp_path):
    provider = provider_for(tmp_path, overpass(stamp="2026-10-20T18:30:00Z"))
    assert provider.data_date == "21 Okt 2026"  # 01.30 WIB keesokan harinya
    assert provider.source_note == ("Data tempat dari salinan OpenStreetMap tanggal 21 Okt 2026 (offline), "
                                    "bisa ada yang sudah berubah.")


def test_date_falls_back_to_file_time(tmp_path):
    data = overpass()
    del data["osm3s"]
    path = write(tmp_path, data)
    stamp = datetime(2026, 10, 19, 3, 0, tzinfo=timezone.utc).timestamp()
    os.utime(path, (stamp, stamp))
    assert SnapshotProvider(settings_for(path)).data_date == "19 Okt 2026"


@pytest.mark.parametrize("content,problem", [
    ("{bukan json", "bukan JSON"),
    ({"remark": "x"}, "tidak ada 'elements'"),
    ([1, 2], "tidak ada 'elements'"),
    (overpass(remark="runtime error: Query timed out in \"query\" at line 3 after 181 seconds."), "berisi error"),
    (overpass(items=[node(1, -6.99, 110.42, amenity="cafe")]), "tidak berisi tempat"),
    (overpass(items=[]), "tidak berisi tempat"),
])
def test_bad_files_become_a_problem(tmp_path, content, problem):
    provider = provider_for(tmp_path, content)
    assert problem in provider.problem and provider.count == 0
    with pytest.raises(PlacesError) as err:
        find(provider, "minimarket")
    assert err.value.kind == "upstream" and err.value.hint == HINT_SNAPSHOT
    with pytest.raises(PlacesError):
        run(provider.probe(NO_BUDGET))


def test_missing_file_is_a_problem(tmp_path):
    provider = SnapshotProvider(settings_for(tmp_path / "places_snapshot.json"))
    assert provider.problem == "file data offline belum ada (places_snapshot.json)"
    assert provider.describe()["problem"] == provider.problem and provider.describe()["area"] is None


# ---------------------------------------------------------------------------
# Pencarian
# ---------------------------------------------------------------------------
def test_search_filters_by_category_and_radius(tmp_path):
    provider = provider_for(tmp_path)
    assert sorted(p.id for p in find(provider, "minimarket", radius=3000)) == ["osm:node/1", "osm:node/2"]
    assert [p.name for p in find(provider, "spbu")] == ["SPBU 44.501.01"]
    assert [p.name for p in find(provider, "rest_area", radius=10000)] == []  # rest area 12 km jauhnya
    assert [p.name for p in find(provider, "rest_area", radius=15000)] == ["Rest Area KM 429"]
    assert len(find(provider, "minimarket", radius=50000)) == 2  # Solo sekitar 77 km
    assert run(provider.probe(NO_BUDGET)) == 7


def test_location_outside_data_area_is_an_error_not_empty(tmp_path):
    provider = provider_for(tmp_path)
    with pytest.raises(PlacesError) as err:
        find(provider, "minimarket", lat=-6.2, lng=106.8)  # Jakarta
    assert err.value.kind == "upstream" and "di luar area" in err.value.detail
    assert provider.covers(-6.97, 110.41)  # sekitar 1 km di luar sebaran data: masih dilayani
    assert not provider.covers(-6.95, 110.41)


def test_describe_for_health(tmp_path):
    info = provider_for(tmp_path).describe()
    assert info == {"file": "places_snapshot.json", "problem": None, "date": "20 Okt 2026",
                    "places": {"rest_area": 1, "minimarket": 3, "lodging": 2, "spbu": 1},
                    "area": [-7.566, 110.4, -6.98, 110.816]}


# ---------------------------------------------------------------------------
# Service: keterangan sumber data dan cadangan
# ---------------------------------------------------------------------------
class DownOsm:
    name = "osm"
    max_concurrency = 1

    def __init__(self, fail=None):
        self.fail = fail
        self.calls = 0

    async def search(self, category, lat, lng, radius_m, budget):
        self.calls += 1
        if self.fail:
            raise self.fail
        return [Place(id="osm:node/99", name="Indomaret Live", lat=lat + 0.001, lng=lng)]


def service_for(settings, providers):
    cache = NearbyCache(settings.cache_ttl_s, settings.cache_tolerance_m, settings.cache_max_entries, Clock(),
                        stale_ttl_s=settings.stale_ttl_s)
    return PlacesService(settings, providers, UsageLedger(None), cache)


def ask(service, category="all", lat=SEMARANG[0], lng=SEMARANG[1]):
    return run(service.nearby(NearbyRequest(lat=lat, lng=lng, category=category)))


def test_service_answers_from_snapshot_with_one_note(tmp_path):
    path = write(tmp_path, overpass())
    settings = settings_for(path)
    service = service_for(settings, {"snapshot": SnapshotProvider(settings)})
    res = ask(service)
    assert not res.degraded and res.provider == "snapshot"
    assert {r.category for r in res.results} == {"rest_area", "minimarket", "lodging"}
    assert all(r.source == "snapshot" for r in res.results)
    assert [r.name for r in res.results if r.id == "osm:node/5"] == ["Hotel / motel (tanpa nama)"]
    assert res.warnings == [SnapshotProvider(settings).source_note]
    assert res.summary.startswith("Rest area terdekat: Rest Area KM 429")


def test_snapshot_first_then_live_osm_outside_area(tmp_path):
    settings = settings_for(write(tmp_path, overpass()), PLACES_FALLBACK_PROVIDER="osm")
    osm = DownOsm()
    service = service_for(settings, {"snapshot": SnapshotProvider(settings), "osm": osm})
    inside = ask(service, "minimarket")
    assert osm.calls == 0 and inside.results[0].source == "snapshot" and not inside.fallback_used
    outside = ask(service, "minimarket", lat=-6.2, lng=106.8)
    assert osm.calls == 1 and outside.fallback_used and outside.results[0].name == "Indomaret Live"
    assert outside.warnings == []  # data live: tanpa keterangan offline


def test_live_osm_first_then_snapshot_when_overpass_is_down(tmp_path):
    settings = settings_for(write(tmp_path, overpass()), provider="osm", PLACES_FALLBACK_PROVIDER="snapshot")
    service = service_for(settings, {"osm": DownOsm(PlacesError("timeout", "lambat")),
                                     "snapshot": SnapshotProvider(settings)})
    res = ask(service, "minimarket")
    assert not res.degraded and res.fallback_used
    assert [r.id for r in res.results] == ["osm:node/2", "osm:node/1"]
    assert any("salinan OpenStreetMap" in w for w in res.warnings)


def test_missing_snapshot_degrades_without_crashing(tmp_path):
    settings = settings_for(tmp_path / "belum_ada.json")
    res = ask(service_for(settings, {"snapshot": SnapshotProvider(settings)}), "minimarket")
    assert res.degraded and res.errors == {"minimarket": "upstream"} and res.results == []


# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------
def test_router_builds_snapshot_provider_and_reports_it(tmp_path):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from nearby_places.router import build_router

    app = FastAPI()
    app.include_router(build_router(settings=settings_for(write(tmp_path, overpass()))))
    client = TestClient(app)
    health = client.get("/places/health").json()
    assert health["status"] == "ok" and health["provider"] == "snapshot"
    assert health["snapshot"]["places"] == {"rest_area": 1, "minimarket": 3, "lodging": 2, "spbu": 1}
    assert "osm" not in health
    deep = client.get("/places/health", params={"deep": "true"}).json()
    assert deep["reachable"] is True and deep["sample_count"] == 7
    body = client.post("/places/nearby", json={"lat": -6.99, "lng": 110.42, "category": "spbu"}).json()
    assert [r["name"] for r in body["results"]] == ["SPBU 44.501.01"]
    assert body["results"][0]["source"] == "snapshot" and "20 Okt 2026" in body["warnings"][0]


# ---------------------------------------------------------------------------
# OSM: curl lengket setelah TLS gagal, walaupun percobaan curl pertama gagal
# ---------------------------------------------------------------------------
def test_tls_failure_sticks_to_curl_even_if_first_curl_fails():
    calls = ByHost(a=[tls_error()])
    runner = FakeRunner((28, b"", b"curl: (28) Operation timed out"), curl_ok(node(7, name="Alfamart")))
    provider = make(calls, runner=runner, PLACES_OSM_URL=A)
    with pytest.raises(PlacesError) as err:
        search(provider)
    assert err.value.kind == "timeout"
    assert [p.name for p in search(provider)] == ["Alfamart"]
    assert calls.hosts == ["a"] and len(runner.calls) == 2  # httpx tidak dicoba lagi


def test_no_sticky_curl_when_curl_is_missing():
    calls = ByHost(a=[tls_error()])
    provider = make(calls, runner=FakeRunner(curl_ok()), which=lambda name: None, PLACES_OSM_URL=A)
    for _ in range(2):
        with pytest.raises(PlacesError) as err:
            search(provider)
        assert err.value.kind == "network" and "curl" in err.value.hint
    assert calls.hosts == ["a", "a"]
