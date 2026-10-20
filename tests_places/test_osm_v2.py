"""Tes OSM v2: failover multi-server, transport curl, cache basi, diagnosa. Tanpa internet."""
import asyncio
import http.server
import shutil
import ssl
import threading
from urllib.parse import parse_qs

import httpx
import pytest

from conftest import run
from nearby_places.cache import NearbyCache
from nearby_places.categories import CATEGORIES
from nearby_places.config import OSM_URL, load_settings
from nearby_places.providers import osm as osm_module
from nearby_places.providers.base import NO_BUDGET, Budget, Place, PlacesError
from nearby_places.providers.osm import HINT_CAPACITY, HINT_TLS, OverpassProvider, is_tls_error, sanitize

A = "https://a.example/api/interpreter"
B = "https://b.example/api/interpreter"
C = "https://c.example/api/interpreter"
THREE = f"{A}, {B} {C}"


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def ok(*elements):
    return httpx.Response(200, json={"elements": list(elements)})


def node(oid, lat=-6.2001, lng=106.8, **tags):
    return {"type": "node", "id": oid, "lat": lat, "lon": lng, "tags": tags}


class ByHost:
    """Handler MockTransport: balasan per host (urutan per host), rekam host yang dipanggil."""

    def __init__(self, **plan):
        self.plan = {h: list(v) for h, v in plan.items()}
        self.hosts = []

    def __call__(self, request):
        host = request.url.host.split(".")[0]
        self.hosts.append(host)
        items = self.plan[host]
        item = items.pop(0) if len(items) > 1 else items[0]
        if isinstance(item, Exception):
            raise item
        if callable(item):
            return item(request)
        return item


def make(handler, clock=None, runner=None, which=None, **env):
    base = {"PLACES_PROVIDER": "osm", "PLACES_USAGE_FILE": "off", "PLACES_OSM_URL": THREE}
    settings = load_settings({**base, **env})
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return OverpassProvider(settings, client, clock=clock or Clock(), runner=runner,
                            which=which or (lambda name: "/usr/bin/curl"))


def search(provider, category="minimarket", budget=NO_BUDGET):
    return run(provider.search(CATEGORIES[category], -6.2, 106.8, 3000, budget))


class CountingBudget(Budget):
    def __init__(self):
        self.calls = 0

    def take(self):
        self.calls += 1


# ---------------------------------------------------------------------------
# Konfigurasi
# ---------------------------------------------------------------------------
def test_url_list_parsing_comma_and_space():
    s = load_settings({"PLACES_PROVIDER": "osm", "PLACES_OSM_URL": f" {A},{B}  {C} ,{A}"})
    assert s.osm_urls == (A, B, C)
    assert s.osm_url == A and s.configured


def test_default_is_single_main_server():
    s = load_settings({"PLACES_PROVIDER": "osm"})
    assert s.osm_urls == (OSM_URL,) and s.osm_url == OSM_URL
    assert s.osm_transport == "auto" and s.osm_deadline_s == 20.0
    assert s.stale_ttl_s == 21600.0 and s.stale_cache_file is None


def test_invalid_url_in_list_is_dropped_with_note():
    s = load_settings({"PLACES_PROVIDER": "osm", "PLACES_OSM_URL": f"{A},ftp://x,nope"})
    assert s.configured and s.osm_urls == (A,)
    assert any("2 alamat tidak valid" in n for n in s.notes)


def test_all_invalid_is_a_problem():
    assert not load_settings({"PLACES_PROVIDER": "osm", "PLACES_OSM_URL": "nope,ftp://x"}).configured


def test_transport_and_deadline_settings():
    s = load_settings({"PLACES_PROVIDER": "osm", "PLACES_OSM_TRANSPORT": "CURL", "PLACES_OSM_DEADLINE_S": "500",
                       "PLACES_STALE_TTL_S": "0", "PLACES_STALE_CACHE_FILE": "/tmp/x.json"})
    assert s.osm_transport == "curl" and s.osm_deadline_s == 120.0 and s.stale_ttl_s == 0.0
    assert s.stale_cache_file == "/tmp/x.json"
    bad = load_settings({"PLACES_PROVIDER": "osm", "PLACES_OSM_TRANSPORT": "carrier-pigeon"})
    assert bad.osm_transport == "auto" and any("PLACES_OSM_TRANSPORT" in n for n in bad.notes)


# ---------------------------------------------------------------------------
# Failover
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("failure", [
    httpx.Response(502, text="This Overpass API server is currently at capacity."),
    httpx.Response(504, text="Gateway Time-out"),
    httpx.ReadTimeout("lambat"),
    httpx.ConnectError("putus"),
    httpx.Response(200, text="<html>bukan json</html>"),
    httpx.Response(429, text="slow down"),
])
def test_fails_over_to_next_server(failure):
    calls = ByHost(a=[failure], b=[ok(node(1, name="Indomaret"))], c=[ok()])
    places = search(make(calls))
    assert [p.name for p in places] == ["Indomaret"]
    assert calls.hosts == ["a", "b"]


def test_bad_request_does_not_fail_over():
    calls = ByHost(a=[httpx.Response(400, text="query salah")], b=[ok()], c=[ok()])
    with pytest.raises(PlacesError) as err:
        search(make(calls))
    assert err.value.kind == "bad_request" and calls.hosts == ["a"]


def test_all_fail_raises_first_error_with_summary():
    calls = ByHost(a=[httpx.Response(502, text="at capacity")], b=[httpx.ReadTimeout("x")],
                   c=[httpx.Response(504, text="gw")])
    with pytest.raises(PlacesError) as err:
        search(make(calls))
    assert err.value.kind == "upstream" and err.value.status == 502
    assert "cadangan: b.example: timeout, c.example: upstream" in err.value.detail
    assert err.value.hint == HINT_CAPACITY
    assert calls.hosts == ["a", "b", "c"]


def test_budget_taken_once_per_attempt():
    budget = CountingBudget()
    calls = ByHost(a=[httpx.Response(502)], b=[httpx.Response(502)], c=[ok()])
    search(make(calls), budget=budget)
    assert budget.calls == 3


def test_last_success_goes_first_and_failed_server_cools_down():
    clock = Clock()
    calls = ByHost(a=[httpx.Response(502), ok()], b=[ok()], c=[ok()])
    provider = make(calls, clock=clock)
    search(provider)
    assert calls.hosts == ["a", "b"]
    clock.now += 5
    search(provider)  # b terakhir sukses -> duluan
    assert calls.hosts == ["a", "b", "b"]
    clock.now += 100  # cooldown a selesai, tapi b tetap paling depan karena terakhir sukses
    search(provider)
    assert calls.hosts[-1] == "b"


def test_recently_failed_server_is_tried_last():
    clock = Clock()
    calls = ByHost(a=[httpx.Response(502)], b=[httpx.Response(502), ok()], c=[httpx.Response(502), ok()])
    provider = make(calls, clock=clock)
    with pytest.raises(PlacesError):
        search(provider)
    assert calls.hosts == ["a", "b", "c"]
    clock.now += 1
    calls.hosts.clear()
    search(provider)  # semua baru gagal -> urutan asli; a masih 502, b sekarang sukses
    assert calls.hosts == ["a", "b"]


def test_rate_limited_server_is_skipped_for_30_seconds():
    clock = Clock()
    calls = ByHost(a=[httpx.Response(429), ok()], b=[ok()], c=[ok()])
    provider = make(calls, clock=clock)
    search(provider)
    clock.now += 10
    search(provider)
    assert calls.hosts == ["a", "b", "b"]  # a dijeda, tidak dipanggil


def test_all_servers_rate_limited_raises_without_network():
    clock = Clock()
    calls = ByHost(a=[httpx.Response(429)], b=[httpx.Response(406)], c=[httpx.Response(429)])
    provider = make(calls, clock=clock)
    with pytest.raises(PlacesError) as first:
        search(provider)
    assert first.value.kind == "rate_limited"
    clock.now += 12
    budget = CountingBudget()
    with pytest.raises(PlacesError) as err:
        search(provider, budget=budget)
    assert err.value.kind == "rate_limited" and 17 <= err.value.retry_after <= 19
    assert len(calls.hosts) == 3 and budget.calls == 0


def test_deadline_stops_further_attempts():
    clock = Clock()

    def slow_fail(request):
        clock.now += 15  # tiap percobaan "memakan" 15 detik
        return httpx.Response(504)

    calls = ByHost(a=[slow_fail], b=[slow_fail], c=[ok()])
    with pytest.raises(PlacesError) as err:
        search(make(calls, clock=clock, PLACES_OSM_DEADLINE_S="20", PLACES_OSM_TIMEOUT_S="15"))
    assert calls.hosts == ["a", "b"]  # sisa 20-30 < 1 detik -> c tidak dicoba
    assert err.value.kind == "upstream"


def test_attempt_timeout_shrinks_to_remaining_deadline():
    clock = Clock()
    queries = []

    def record(request):
        queries.append(parse_qs(request.content.decode())["data"][0])
        clock.now += 12
        return httpx.Response(502)

    calls = ByHost(a=[record], b=[record], c=[record])
    with pytest.raises(PlacesError):
        search(make(calls, clock=clock, PLACES_OSM_DEADLINE_S="20", PLACES_OSM_TIMEOUT_S="15"))
    assert "[timeout:13]" in queries[0]  # min(15, 20) - 2
    assert "[timeout:6]" in queries[1]  # min(15, 8) - 2


# ---------------------------------------------------------------------------
# TLS -> curl
# ---------------------------------------------------------------------------
def tls_error():
    exc = httpx.ConnectError("[SSL: SSLV3_ALERT_HANDSHAKE_FAILURE] sslv3 alert handshake failure")
    exc.__cause__ = ssl.SSLError(1, "SSLV3_ALERT_HANDSHAKE_FAILURE")
    return exc


class FakeRunner:
    def __init__(self, *results):
        self.results = list(results)
        self.calls = []

    async def __call__(self, argv, stdin, timeout):
        self.calls.append((list(argv), stdin, timeout))
        item = self.results.pop(0) if len(self.results) > 1 else self.results[0]
        if isinstance(item, BaseException):
            raise item
        return item


def curl_ok(*elements, status=200):
    import json
    return 0, json.dumps({"elements": list(elements)}).encode() + f"\n{status}".encode(), b""


def test_is_tls_error_detection():
    assert is_tls_error(tls_error())
    assert is_tls_error(httpx.ConnectError("certificate verify failed"))
    assert not is_tls_error(httpx.ConnectError("Name or service not known"))


def test_auto_mode_retries_tls_failure_with_curl_and_sticks():
    calls = ByHost(a=[tls_error()], b=[ok()], c=[ok()])
    runner = FakeRunner(curl_ok(node(7, name="Alfamart")))
    budget = CountingBudget()
    provider = make(calls, runner=runner)
    places = search(provider, budget=budget)
    assert [p.name for p in places] == ["Alfamart"]
    assert calls.hosts == ["a"] and len(runner.calls) == 1
    assert budget.calls == 1  # gagal TLS tidak sampai ke Overpass, jatah tidak dipotong dua kali
    argv, stdin, _ = runner.calls[0]
    assert argv[0] == "/usr/bin/curl" and argv[-1] == A
    assert "--data-binary" in argv and "@-" in argv
    assert argv[argv.index("-A") + 1].startswith("driving-buddy-places/")
    assert parse_qs(stdin.decode())["data"][0].startswith("[out:json]")
    search(provider)  # lengket: langsung curl, httpx tidak dipanggil lagi untuk a
    assert calls.hosts == ["a"] and len(runner.calls) == 2


def test_httpx_mode_reports_tls_with_hint_and_fails_over():
    calls = ByHost(a=[tls_error()], b=[tls_error()], c=[tls_error()])
    runner = FakeRunner(curl_ok())
    with pytest.raises(PlacesError) as err:
        search(make(calls, runner=runner, PLACES_OSM_TRANSPORT="httpx"))
    assert err.value.kind == "network" and err.value.hint == HINT_TLS
    assert runner.calls == []


def test_curl_mode_never_uses_httpx():
    calls = ByHost(a=[ok()], b=[ok()], c=[ok()])
    runner = FakeRunner(curl_ok(node(1, name="X")))
    search(make(calls, runner=runner, PLACES_OSM_TRANSPORT="curl"))
    assert calls.hosts == [] and len(runner.calls) == 1


@pytest.mark.parametrize("result,kind", [
    ((28, b"", b"curl: (28) Operation timed out"), "timeout"),
    ((6, b"", b"curl: (6) Could not resolve host: a.example"), "network"),
    ((0, b"<html>at capacity</html>\n502", b""), "upstream"),
    ((0, b"slow\n429", b""), "rate_limited"),
    ((0, b"tanpa kode", b""), "bad_response"),
    (asyncio.TimeoutError(), "timeout"),
])
def test_curl_error_mapping(result, kind):
    runner = FakeRunner(result)
    provider = make(ByHost(a=[ok()]), runner=runner, PLACES_OSM_TRANSPORT="curl", PLACES_OSM_URL=A)
    with pytest.raises(PlacesError) as err:
        search(provider)
    assert err.value.kind == kind


def test_missing_curl_gives_hint():
    provider = make(ByHost(a=[tls_error()]), runner=FakeRunner(curl_ok()), which=lambda name: None,
                    PLACES_OSM_URL=A)
    provider._which = lambda name: None
    with pytest.raises(PlacesError) as err:
        search(provider)
    assert err.value.kind == "network" and "curl" in err.value.hint


def test_user_agent_control_chars_are_stripped_for_curl():
    runner = FakeRunner(curl_ok())
    provider = make(ByHost(a=[ok()]), runner=runner, PLACES_OSM_TRANSPORT="curl", PLACES_OSM_URL=A,
                    PLACES_OSM_USER_AGENT="tim\nlima\r/1.0")
    search(provider)
    agent = runner.calls[0][0][runner.calls[0][0].index("-A") + 1]
    assert "\n" not in agent and "\r" not in agent


class _OverpassStub(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode()
        type(self).seen.append((self.headers.get("User-Agent"), parse_qs(body)["data"][0]))
        payload = b'{"elements":[{"type":"node","id":5,"lat":-6.2001,"lon":106.8,"tags":{"name":"Rest Area Lokal"}}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


@pytest.mark.skipif(shutil.which("curl") is None, reason="curl tidak ada")
def test_real_curl_against_local_server():
    server = http.server.HTTPServer(("127.0.0.1", 0), _OverpassStub)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{server.server_address[1]}/api/interpreter"
        settings = load_settings({"PLACES_PROVIDER": "osm", "PLACES_USAGE_FILE": "off", "PLACES_OSM_URL": url,
                                  "PLACES_OSM_TRANSPORT": "curl"})
        provider = OverpassProvider(settings)
        places = run(provider.search(CATEGORIES["rest_area"], -6.2, 106.8, 3000, NO_BUDGET))
        assert [p.name for p in places] == ["Rest Area Lokal"]
        agent, query = _OverpassStub.seen[-1]
        assert agent.startswith("driving-buddy-places/") and 'highway"~"^(rest_area|services)$"' in query
    finally:
        server.shutdown()
        server.server_close()


def test_real_subprocess_runner_kills_on_timeout():
    if shutil.which("sleep") is None:
        pytest.skip("sleep tidak ada")
    with pytest.raises(asyncio.TimeoutError):
        run(osm_module.run_subprocess(["sleep", "5"], b"", 0.3))


# ---------------------------------------------------------------------------
# Sanitasi
# ---------------------------------------------------------------------------
def test_sanitize_hides_query_strings_and_keys():
    text = "gagal ke https://x.example/api/interpreter?apikey=RAHASIA123&a=1 key=ABC\x00\n"
    out = sanitize(text)
    assert "RAHASIA" not in out and "ABC" not in out and "\x00" not in out
    assert "https://x.example/api/interpreter?***" in out
    assert len(sanitize("y" * 999)) == 200


# ---------------------------------------------------------------------------
# Cache basi
# ---------------------------------------------------------------------------
P = Place(id="osm:node/1", name="Rest Area 1", lat=-6.25, lng=106.8)


def test_stale_entry_not_used_by_normal_get_but_by_get_stale():
    clock = Clock()
    cache = NearbyCache(ttl_s=90, clock=clock, stale_ttl_s=3600)
    cache.put("osm", "rest_area", 50000, -6.2, 106.8, [P])
    clock.now += 600
    assert cache.get("osm", "rest_area", 50000, -6.2, 106.8) is None
    assert len(cache) == 0 and cache.stale_entries == 1
    places, age, provider = cache.get_stale("rest_area", 50000, -6.21, 106.8)
    assert places == [P] and age == 600 and provider == "osm"


def test_get_stale_limits():
    clock = Clock()
    cache = NearbyCache(ttl_s=90, clock=clock, stale_ttl_s=3600)
    cache.put("osm", "minimarket", 3000, -6.2, 106.8, [P])
    assert cache.get_stale("minimarket", 3000, -6.2, 106.8) is not None
    assert cache.get_stale("minimarket", 3000, -6.21, 106.8) is None  # 1,1 km > 3000/5
    assert cache.get_stale("minimarket", 5000, -6.2, 106.8) is None  # radius beda
    assert cache.get_stale("lodging", 3000, -6.2, 106.8) is None
    clock.now += 3601
    assert cache.get_stale("minimarket", 3000, -6.2, 106.8) is None


def test_stale_disabled_by_default_in_cache_class():
    clock = Clock()
    cache = NearbyCache(ttl_s=90, clock=clock)
    cache.put("osm", "rest_area", 50000, -6.2, 106.8, [P])
    clock.now += 91
    assert cache.get_stale("rest_area", 50000, -6.2, 106.8) is None and cache.stale_entries == 0


def test_stale_file_survives_restart(tmp_path):
    path = tmp_path / "cache.json"
    clock, wall = Clock(), [5_000_000.0]
    first = NearbyCache(clock=clock, stale_ttl_s=3600, stale_file=str(path), wall_clock=lambda: wall[0])
    first.put("osm", "rest_area", 50000, -6.2, 106.8, [P])
    assert path.is_file()
    wall[0] += 900
    second = NearbyCache(clock=Clock(), stale_ttl_s=3600, stale_file=str(path), wall_clock=lambda: wall[0])
    places, age, _ = second.get_stale("rest_area", 50000, -6.2, 106.8)
    assert places[0].name == "Rest Area 1" and 899 <= age <= 901
    wall[0] += 3600
    third = NearbyCache(clock=Clock(), stale_ttl_s=3600, stale_file=str(path), wall_clock=lambda: wall[0])
    assert third.get_stale("rest_area", 50000, -6.2, 106.8) is None


def test_corrupt_stale_file_is_ignored(tmp_path):
    path = tmp_path / "cache.json"
    path.write_text("{rusak")
    cache = NearbyCache(stale_ttl_s=3600, stale_file=str(path))
    assert cache.stale_entries == 0


# ---------------------------------------------------------------------------
# Service: cache basi dipakai saat provider gagal; health menampilkan detail
# ---------------------------------------------------------------------------
from nearby_places.limits import UsageLedger  # noqa: E402
from nearby_places.schemas import NearbyRequest  # noqa: E402
from nearby_places.service import PlacesService, format_age  # noqa: E402


class FlakyProvider:
    name = "osm"
    max_concurrency = 1

    def __init__(self):
        self.fail = None
        self.places = [Place(id="osm:node/1", name="Rest Area KM 429", lat=-6.25, lng=106.8)]

    async def search(self, category, lat, lng, radius_m, budget):
        if self.fail:
            raise self.fail
        return list(self.places)

    async def probe(self, budget):
        if self.fail:
            raise self.fail
        return 1

    async def aclose(self):
        return None


def osm_service(**env):
    settings = load_settings({"PLACES_PROVIDER": "osm", "PLACES_USAGE_FILE": "off", **env})
    clock = Clock()
    cache = NearbyCache(settings.cache_ttl_s, settings.cache_tolerance_m, settings.cache_max_entries, clock,
                        stale_ttl_s=settings.stale_ttl_s)
    provider = FlakyProvider()
    service = PlacesService(settings, {"osm": provider}, UsageLedger(None), cache)
    return service, provider, clock


def test_service_uses_stale_data_when_provider_fails():
    service, provider, clock = osm_service()
    first = run(service.nearby(NearbyRequest(lat=-6.2, lng=106.8, category="rest_area")))
    assert not first.degraded and first.results
    clock.now += 25 * 60
    provider.fail = PlacesError("upstream", "HTTP 502")
    second = run(service.nearby(NearbyRequest(lat=-6.201, lng=106.8, category="rest_area")))
    assert not second.degraded and second.errors == {} and second.cached
    assert second.results[0].name == "Rest Area KM 429"
    assert second.results[0].distance_m != first.results[0].distance_m  # jarak dihitung ulang
    assert any("25 menit lalu" in w and "tidak bisa dihubungi" in w for w in second.warnings)


def test_service_without_stale_data_stays_degraded():
    service, provider, clock = osm_service(PLACES_STALE_TTL_S="0")
    run(service.nearby(NearbyRequest(lat=-6.2, lng=106.8, category="rest_area")))
    clock.now += 600
    provider.fail = PlacesError("timeout", "lambat")
    res = run(service.nearby(NearbyRequest(lat=-6.2, lng=106.8, category="rest_area")))
    assert res.degraded and res.errors == {"rest_area": "timeout"} and res.warnings == []


def test_probe_reports_sanitized_detail_and_hint():
    service, provider, _ = osm_service()
    provider.fail = PlacesError("network", "ConnectError: ssl fail at https://x.example/i?apikey=SECRET\n",
                                hint=HINT_TLS)
    info = run(service.probe())
    assert info["reachable"] is False and info["error"] == "network" and info["hint"] == HINT_TLS
    assert "SECRET" not in info["detail"] and "\n" not in info["detail"]


@pytest.mark.parametrize("seconds,text", [(10, "kurang dari 1 menit lalu"), (25 * 60, "25 menit lalu"),
                                          (3600, "1 jam lalu"), (3 * 3600 + 5 * 60, "3 jam 5 menit lalu")])
def test_format_age(seconds, text):
    assert format_age(seconds) == text


def test_health_lists_osm_servers_and_transport():
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from nearby_places.router import build_router

    settings = load_settings({"PLACES_PROVIDER": "osm", "PLACES_USAGE_FILE": "off", "PLACES_OSM_URL": THREE,
                              "PLACES_OSM_TRANSPORT": "curl"})
    app = FastAPI()
    app.include_router(build_router(settings=settings, providers={"osm": FlakyProvider()}))
    body = TestClient(app).get("/places/health").json()
    assert body["osm"] == {"servers": ["a.example", "b.example", "c.example"], "transport": "curl"}
    assert body["stale_cache_entries"] == 0
