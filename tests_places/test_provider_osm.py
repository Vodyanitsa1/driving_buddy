"""Tes provider OpenStreetMap (Overpass) pakai httpx.MockTransport: tanpa internet."""
import asyncio
import json
import re
from urllib.parse import parse_qs

import httpx
import pytest

from conftest import run
from nearby_places.categories import CATEGORIES
from nearby_places.config import OSM_USER_AGENT, load_settings
from nearby_places.providers import osm as osm_module
from nearby_places.providers.base import NO_BUDGET, Budget, PlacesError
from nearby_places.providers.osm import ELEMENT_CAP, OverpassProvider, build_query


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def make(handler, clock=None, **env):
    base = {"PLACES_PROVIDER": "osm", "PLACES_USAGE_FILE": "off"}
    settings = load_settings({**base, **env})
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return OverpassProvider(settings, client, clock=clock or Clock())


def search(provider, category="rest_area", lat=-6.2, lng=106.8, radius=30000, budget=NO_BUDGET):
    return run(provider.search(CATEGORIES[category], lat, lng, radius, budget))


def node(oid, lat=-6.15, lng=106.8, **tags):
    return {"type": "node", "id": oid, "lat": lat, "lon": lng, "tags": tags}


def way(oid, lat=-6.15, lng=106.8, **tags):
    return {"type": "way", "id": oid, "center": {"lat": lat, "lon": lng}, "tags": tags}


def ok(*elements):
    return httpx.Response(200, json={"version": 0.6, "elements": list(elements)})


def query_of(request: httpx.Request) -> str:
    return parse_qs(request.content.decode())["data"][0]


def radius_of(request: httpx.Request) -> int:
    return int(re.search(r"around:(\d+),", query_of(request)).group(1))


class Calls:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def __call__(self, request):
        self.requests.append(request)
        item = self.responses[min(len(self.requests), len(self.responses)) - 1]
        if isinstance(item, Exception):
            raise item
        return item


class CountingBudget(Budget):
    def __init__(self, limit=None):
        self.calls = 0
        self.limit = limit

    def take(self):
        if self.limit is not None and self.calls >= self.limit:
            raise PlacesError("budget_exhausted", "habis")
        self.calls += 1


# ---------------------------------------------------------------------------
# Bentuk permintaan
# ---------------------------------------------------------------------------
def test_request_is_post_with_user_agent_and_form_body():
    calls = Calls(ok())
    search(make(calls))
    assert len(calls.requests) == 1
    request = calls.requests[0]
    assert request.method == "POST"
    assert str(request.url) == "https://overpass-api.de/api/interpreter"
    assert request.headers["user-agent"] == OSM_USER_AGENT  # kebijakan Overpass: wajib User-Agent sendiri
    assert "driving-buddy" in request.headers["user-agent"]
    assert request.headers["content-type"].startswith("application/x-www-form-urlencoded")
    assert request.url.query == b""  # query tidak ditaruh di URL


def test_custom_user_agent_and_url():
    calls = Calls(ok())
    provider = make(calls, PLACES_OSM_URL="http://127.0.0.1:9999/api/interpreter",
                    PLACES_OSM_USER_AGENT="tim-lima/2.0 (contoh@kampus.ac.id)")
    search(provider)
    assert str(calls.requests[0].url) == "http://127.0.0.1:9999/api/interpreter"
    assert calls.requests[0].headers["user-agent"] == "tim-lima/2.0 (contoh@kampus.ac.id)"


def test_query_for_rest_area_uses_regex_filter_for_node_and_way():
    query = build_query(CATEGORIES["rest_area"], -6.2, 106.8, 30000, 6, 300)
    assert query.startswith("[out:json][timeout:6];")
    assert '["highway"~"^(rest_area|services)$"]' in query
    assert 'node["highway"~"^(rest_area|services)$"](around:30000,-6.200000,106.800000);' in query
    assert 'way["highway"~"^(rest_area|services)$"](around:30000,-6.200000,106.800000);' in query
    assert query.rstrip().endswith("out center 300;")


def test_query_for_single_value_uses_equality():
    query = build_query(CATEGORIES["minimarket"], -6.2, 106.8, 3000, 6, 300)
    assert 'node["shop"="convenience"](around:3000,' in query
    assert "~" not in query


def test_query_for_lodging_lists_all_tourism_values():
    query = build_query(CATEGORIES["lodging"], -6.2, 106.8, 15000, 6, 300)
    assert '["tourism"~"^(hotel|motel|guest_house|hostel)$"]' in query


def test_server_timeout_is_below_client_timeout():
    calls = Calls(ok())
    search(make(calls, PLACES_OSM_TIMEOUT_S="8"))
    assert "[timeout:6]" in query_of(calls.requests[0])


def test_radius_and_center_in_query():
    calls = Calls(ok())
    search(make(calls), lat=-7.25, lng=112.75, radius=12345)
    assert "(around:12345,-7.250000,112.750000)" in query_of(calls.requests[0])


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------
def test_parses_nodes_and_ways():
    places = search(make(Calls(ok(
        node(1, -6.1, 106.8, name="Rest Area KM 10", highway="services"),
        way(2, -6.3, 106.9, name="Rest Area KM 20", highway="rest_area"),
    ))))
    assert [p.id for p in places] == ["osm:node/1", "osm:way/2"]
    assert places[0].name == "Rest Area KM 10"
    assert (places[1].lat, places[1].lng) == (-6.3, 106.9)  # way -> titik tengah (center)
    assert places[0].provider_type == "highway=services"
    assert places[1].provider_type == "highway=rest_area"
    assert places[0].maps_url == "https://www.openstreetmap.org/node/1"
    assert places[1].maps_url == "https://www.openstreetmap.org/way/2"


def test_name_falls_back_to_brand_then_operator_then_empty():
    places = search(make(Calls(ok(
        node(1, name=""), node(2, brand="Alfamart"), node(3, operator="PT Jasa Marga"),
        node(4, **{"name:id": "Rest Area Nama Lokal"}), node(5),
    ))), category="minimarket")
    assert [p.name for p in places] == ["", "Alfamart", "PT Jasa Marga", "Rest Area Nama Lokal", ""]


def test_address_variants():
    places = search(make(Calls(ok(
        node(1, **{"addr:full": "Jl. Raya Puncak No. 1, Bogor"}),
        node(2, **{"addr:street": "Jl. Sudirman", "addr:housenumber": "12", "addr:suburb": "Menteng",
                   "addr:city": "Jakarta"}),
        node(3, **{"addr:city": "Bandung"}),
        node(4, **{"addr:street": "Jl. Tanpa Nomor"}),
        node(5),
    ))), category="minimarket")
    assert places[0].address == "Jl. Raya Puncak No. 1, Bogor"
    assert places[1].address == "Jl. Sudirman 12, Menteng, Jakarta"
    assert places[2].address == "Bandung"
    assert places[3].address == "Jl. Tanpa Nomor"
    assert places[4].address == ""


def test_invalid_elements_are_skipped():
    elements = [
        node(1, -6.1, 106.8, name="Valid"),
        {"type": "node", "id": 2, "tags": {"name": "tanpa koordinat"}},
        {"type": "node", "id": 3, "lat": True, "lon": 106.8},
        {"type": "node", "id": 4, "lat": 95.0, "lon": 106.8},
        {"type": "node", "id": 5, "lat": float("nan"), "lon": 106.8},
        {"type": "way", "id": 6, "tags": {}},  # way tanpa center
        {"type": "way", "id": 7, "center": "bukan dict"},
        {"type": "area", "id": 8, "lat": -6.1, "lon": 106.8},
        {"type": "node", "lat": -6.1, "lon": 106.8},  # tanpa id
        "bukan dict",
        42,
        {"type": "node", "id": 9, "lat": -6.2, "lon": 106.7, "tags": "aneh"},  # tags bukan dict: tetap dipakai
    ]
    # NaN tidak ada di JSON standar, tapi json.loads Python menerimanya; pastikan tetap ditolak.
    response = httpx.Response(200, content=json.dumps({"elements": elements}, allow_nan=True).encode(),
                              headers={"content-type": "application/json"})
    places = search(make(Calls(response)), category="minimarket")
    assert [p.id for p in places] == ["osm:node/1", "osm:node/9"]


def test_tags_that_are_not_a_dict_do_not_crash():
    places = search(make(Calls(ok({"type": "node", "id": 1, "lat": -6.1, "lon": 106.8, "tags": ["a"]}))),
                    category="minimarket")
    assert len(places) == 1 and places[0].name == ""


def test_empty_result_is_not_an_error():
    assert search(make(Calls(ok()))) == []


def test_ignores_unrelated_remark():
    response = httpx.Response(200, json={"remark": "peringatan biasa", "elements": [node(1, name="X")]})
    assert len(search(make(Calls(response)), category="minimarket")) == 1


# ---------------------------------------------------------------------------
# Kegagalan
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("status", [429, 406])
def test_rate_limit_blocks_following_calls_for_30_seconds(status):
    clock = Clock()
    calls = Calls(httpx.Response(status, text="slow down"), ok(node(1, name="A")))
    provider = make(calls, clock=clock)
    with pytest.raises(PlacesError) as first:
        search(provider)
    assert first.value.kind == "rate_limited" and first.value.status == status
    assert first.value.retry_after == osm_module.BLOCK_S
    assert len(calls.requests) == 1

    # Masih dalam jeda: ditolak tanpa memanggil server dan tanpa memakai jatah
    budget = CountingBudget()
    clock.now += 10
    with pytest.raises(PlacesError) as blocked:
        search(provider, budget=budget)
    assert blocked.value.kind == "rate_limited"
    assert 19 <= blocked.value.retry_after <= 21
    assert len(calls.requests) == 1 and budget.calls == 0

    clock.now += 25  # jeda selesai
    places = search(provider, category="minimarket")
    assert [p.id for p in places] == ["osm:node/1"]
    assert len(calls.requests) == 2


@pytest.mark.parametrize("status,kind", [(500, "upstream"), (502, "upstream"), (504, "upstream"),
                                         (400, "bad_request"), (403, "bad_request"), (404, "bad_request")])
def test_http_status_to_error_kind(status, kind):
    with pytest.raises(PlacesError) as err:
        search(make(Calls(httpx.Response(status, text="ada masalah"))))
    assert err.value.kind == kind and err.value.status == status


def test_bad_request_detail_is_truncated():
    with pytest.raises(PlacesError) as err:
        search(make(Calls(httpx.Response(400, text="x" * 5000))))
    assert len(err.value.detail) < 400


@pytest.mark.parametrize("response", [
    httpx.Response(200, text="<html>oops</html>", headers={"content-type": "text/html"}),
    httpx.Response(200, json=["bukan", "dict"]),
    httpx.Response(200, json={"version": 0.6}),
    httpx.Response(200, json={"elements": "bukan list"}),
])
def test_bad_responses(response):
    with pytest.raises(PlacesError) as err:
        search(make(Calls(response)))
    assert err.value.kind == "bad_response"


def test_runtime_error_remark_timed_out_is_timeout():
    remark = 'runtime error: Query timed out in "query" at line 4 after 7 seconds.'
    with pytest.raises(PlacesError) as err:
        search(make(Calls(httpx.Response(200, json={"remark": remark, "elements": []}))))
    assert err.value.kind == "timeout"  # BUKAN "tidak ada tempat"


def test_runtime_error_remark_out_of_memory_is_upstream():
    remark = "runtime error: Query run out of memory using about 2048 MB of RAM."
    with pytest.raises(PlacesError) as err:
        search(make(Calls(httpx.Response(200, json={"remark": remark, "elements": []}))))
    assert err.value.kind == "upstream"


def test_httpx_timeout_is_timeout():
    with pytest.raises(PlacesError) as err:
        search(make(Calls(httpx.ReadTimeout("lambat"))))
    assert err.value.kind == "timeout"


def test_connection_error_is_network():
    with pytest.raises(PlacesError) as err:
        search(make(Calls(httpx.ConnectError("tidak bisa konek"))))
    assert err.value.kind == "network"


def test_hard_deadline_when_server_hangs():
    async def hang(request):
        await asyncio.sleep(5)
        return ok()

    provider = make(hang, PLACES_OSM_TIMEOUT_S="1")
    with pytest.raises(PlacesError) as err:
        search(provider)
    assert err.value.kind == "timeout"


# ---------------------------------------------------------------------------
# Jatah panggilan dan hasil terpotong
# ---------------------------------------------------------------------------
def test_budget_is_taken_once_per_http_call():
    budget = CountingBudget()
    search(make(Calls(ok())), budget=budget)
    assert budget.calls == 1


def test_exhausted_budget_stops_before_any_http_call():
    calls = Calls(ok())
    with pytest.raises(PlacesError) as err:
        search(make(calls), budget=CountingBudget(limit=0))
    assert err.value.kind == "budget_exhausted"
    assert calls.requests == []


def _many(count, start=0):
    return [node(start + i, -6.2 + 0.0001 * (i + 1), 106.8, name=f"n{i}") for i in range(count)]


def test_radius_shrinks_when_result_hits_the_cap():
    def handler(request):
        if radius_of(request) > 8000:
            return ok(*_many(ELEMENT_CAP))
        return ok(*_many(5))

    seen = []

    def recording(request):
        seen.append(radius_of(request))
        return handler(request)

    places = search(make(recording), category="minimarket", radius=30000)
    assert seen == [30000, 15000, 7500]
    assert len(places) == 5


def test_gives_up_shrinking_after_max_shrinks_and_still_returns_results(caplog):
    seen = []

    def always_full(request):
        seen.append(radius_of(request))
        return ok(*_many(ELEMENT_CAP))

    with caplog.at_level("WARNING"):
        places = search(make(always_full), category="minimarket", radius=30000)
    assert seen == [30000, 15000, 7500, 3750]
    assert len(places) == ELEMENT_CAP
    assert "terpotong" in caplog.text


def test_shrinking_stops_at_minimum_radius():
    seen = []

    def always_full(request):
        seen.append(radius_of(request))
        return ok(*_many(ELEMENT_CAP))

    search(make(always_full), category="minimarket", radius=600)
    assert seen == [600, 500]


def test_each_shrink_attempt_uses_budget():
    budget = CountingBudget()

    def full_then_small(request):
        return ok(*_many(ELEMENT_CAP)) if radius_of(request) > 8000 else ok(*_many(2))

    search(make(full_then_small), category="minimarket", radius=30000, budget=budget)
    assert budget.calls == 3


# ---------------------------------------------------------------------------
def test_aclose_closes_only_owned_client():
    settings = load_settings({"PLACES_PROVIDER": "osm", "PLACES_USAGE_FILE": "off"})
    injected = httpx.AsyncClient(transport=httpx.MockTransport(Calls(ok())))
    provider = OverpassProvider(settings, injected)
    run(provider.aclose())
    assert not injected.is_closed  # klien suntikan dikelola pemiliknya
    run(injected.aclose())

    async def own_and_close():
        owned = OverpassProvider(settings)
        owned._client()
        await owned.aclose()
        assert owned._http is None

    run(own_and_close())
