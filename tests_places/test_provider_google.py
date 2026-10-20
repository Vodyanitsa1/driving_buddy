"""Tes provider Google pakai httpx.MockTransport: tanpa internet, tanpa API key asli."""
import asyncio
import json
import logging

import httpx
import pytest

from conftest import run
from nearby_places.categories import CATEGORIES
from nearby_places.config import load_settings
from nearby_places.providers import google as google_module
from nearby_places.providers.base import NO_BUDGET, Budget, PlacesError
from nearby_places.providers.google import FETCH_COUNT, GooglePlacesProvider

KEY = "AIzaSyTestKey123"
ENTERPRISE_FIELDS = ("rating", "currentOpeningHours", "regularOpeningHours", "userRatingCount",
                     "internationalPhoneNumber", "nationalPhoneNumber", "websiteUri", "priceLevel", "reviews")


@pytest.fixture(autouse=True)
def no_backoff(monkeypatch):
    monkeypatch.setattr(google_module, "BACKOFF_S", 0.0)


def make(handler, **env):
    base = {"PLACES_PROVIDER": "google", "GOOGLE_PLACES_API_KEY": KEY, "PLACES_USAGE_FILE": "off",
            "PLACES_TIMEOUT_S": "1"}
    settings = load_settings({**base, **env})
    return GooglePlacesProvider(settings, httpx.AsyncClient(transport=httpx.MockTransport(handler)))


def search(provider, category="rest_area", lat=-6.2, lng=106.8, radius=30000, budget=NO_BUDGET):
    return run(provider.search(CATEGORIES[category], lat, lng, radius, budget))


def gplace(pid="p1", name="Rest Area KM 10", lat=-6.15, lng=106.8, **extra):
    data = {"id": pid, "displayName": {"text": name, "languageCode": "id"}, "formattedAddress": "Jl. Tol KM 10",
            "location": {"latitude": lat, "longitude": lng}, "googleMapsUri": f"https://maps.google.com/?cid={pid}",
            "businessStatus": "OPERATIONAL", "primaryType": "rest_stop"}
    data.update(extra)
    return data


def ok(*places):
    return httpx.Response(200, json={"places": list(places)} if places else {})


def gerr(status, message, g_status="", reason="", headers=None):
    body = {"error": {"code": status, "message": message, "status": g_status}}
    if reason:
        body["error"]["details"] = [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason}]
    return httpx.Response(status, json=body, headers=headers or {})


class Calls:
    """Handler yang mencatat request dan membalas sesuai urutan `responses` (yang terakhir diulang)."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def __call__(self, request):
        self.requests.append(request)
        item = self.responses[min(len(self.requests), len(self.responses)) - 1]
        if isinstance(item, Exception):
            raise item
        return item

    def body(self, i=0):
        return json.loads(self.requests[i].content)


class CountingBudget(Budget):
    def __init__(self, limit=None):
        self.calls = 0
        self.limit = limit

    def take(self):
        if self.limit is not None and self.calls >= self.limit:
            raise PlacesError("budget_exhausted", "habis")
        self.calls += 1


# ------------------------------------------------------------------ bentuk request
def test_request_is_built_exactly_as_places_api_new_expects():
    calls = Calls(ok(gplace()))
    search(make(calls))
    req = calls.requests[0]
    assert req.method == "POST" and str(req.url) == "https://places.googleapis.com/v1/places:searchNearby"
    assert req.headers["x-goog-api-key"] == KEY
    assert req.headers["content-type"] == "application/json"
    assert KEY not in str(req.url)  # key hanya di header, tidak pernah di URL
    body = calls.body()
    assert body["includedTypes"] == ["rest_stop"]
    assert body["rankPreference"] == "DISTANCE"  # bawaan Google POPULARITY: tanpa ini "terdekat" bukan terdekat
    assert body["maxResultCount"] == FETCH_COUNT == 20
    assert body["languageCode"] == "id" and body["regionCode"] == "ID"
    assert body["locationRestriction"] == {"circle": {"center": {"latitude": -6.2, "longitude": 106.8},
                                                      "radius": 30000.0}}


def test_radius_is_always_a_positive_float_within_google_limits():
    calls = Calls(ok())
    search(make(calls), radius=60000)
    assert calls.body()["locationRestriction"]["circle"]["radius"] == 50000.0
    search(make(calls), radius=0)
    assert calls.body(1)["locationRestriction"]["circle"]["radius"] == 1.0  # 0 akan ditolak Google


def test_coordinates_are_rounded_to_six_decimals():
    calls = Calls(ok())
    search(make(calls), lat=-6.123456789012, lng=106.987654321098)
    center = calls.body()["locationRestriction"]["circle"]["center"]
    assert center == {"latitude": -6.123457, "longitude": 106.987654}


def test_field_mask_contains_only_pro_tier_fields_by_default():
    calls = Calls(ok())
    search(make(calls))
    mask = calls.requests[0].headers["x-goog-fieldmask"]
    fields = mask.split(",")
    assert all(f.startswith("places.") for f in fields) and " " not in mask
    for needed in ("places.id", "places.displayName", "places.location", "places.businessStatus"):
        assert needed in fields
    for expensive in ENTERPRISE_FIELDS:
        assert f"places.{expensive}" not in fields, f"{expensive} memindahkan permintaan ke SKU Enterprise"


def test_rating_hours_option_adds_exactly_the_enterprise_fields_we_parse():
    calls = Calls(ok())
    search(make(calls, PLACES_GOOGLE_RATING_HOURS="true"))
    fields = calls.requests[0].headers["x-goog-fieldmask"].split(",")
    assert "places.rating" in fields and "places.currentOpeningHours" in fields


@pytest.mark.parametrize("category,types", [
    ("rest_area", ["rest_stop"]), ("minimarket", ["convenience_store"]),
    ("lodging", ["hotel", "motel", "guest_house", "lodging"]), ("spbu", ["gas_station"]),
])
def test_each_category_sends_its_google_types(category, types):
    calls = Calls(ok())
    search(make(calls), category=category)
    assert calls.body()["includedTypes"] == types


def test_type_override_from_settings_is_used():
    calls = Calls(ok())
    search(make(calls, PLACES_GOOGLE_TYPES_REST_AREA="rest_stop,truck_stop"))
    assert calls.body()["includedTypes"] == ["rest_stop", "truck_stop"]


def test_custom_language_and_region():
    calls = Calls(ok())
    search(make(calls, PLACES_LANGUAGE="en", PLACES_REGION="MY"))
    assert (calls.body()["languageCode"], calls.body()["regionCode"]) == ("en", "MY")


# ------------------------------------------------------------------------ parsing
def test_parses_a_normal_response():
    places = search(make(Calls(ok(gplace("a", "Rest Area A", -6.1, 106.81), gplace("b", "Rest Area B")))))
    assert [p.id for p in places] == ["a", "b"]
    a = places[0]
    assert (a.name, a.lat, a.lng, a.address, a.provider_type) == ("Rest Area A", -6.1, 106.81, "Jl. Tol KM 10", "rest_stop")
    assert a.maps_url == "https://maps.google.com/?cid=a" and a.open_now is None and a.rating is None


def test_no_results_means_google_omits_places_and_we_return_empty():
    assert search(make(Calls(ok()))) == []
    assert search(make(Calls(httpx.Response(200, json={"places": []})))) == []


def test_closed_and_not_yet_open_places_are_dropped():
    items = [gplace("open"), gplace("c1", businessStatus="CLOSED_TEMPORARILY"),
             gplace("c2", businessStatus="CLOSED_PERMANENTLY"), gplace("f", businessStatus="FUTURE_OPENING"),
             gplace("nostatus", businessStatus=None), gplace("unspec", businessStatus="BUSINESS_STATUS_UNSPECIFIED")]
    items[4].pop("businessStatus")
    assert [p.id for p in search(make(Calls(ok(*items))))] == ["open", "nostatus", "unspec"]


def test_malformed_places_are_skipped_not_fatal():
    items = [gplace("good"), "bukan dict", {"id": "x"}, gplace("noloc", location=None),
             gplace("badlat", location={"latitude": 95, "longitude": 10}),
             gplace("strlat", location={"latitude": "1", "longitude": "2"}),
             gplace("boollat", location={"latitude": True, "longitude": False}),
             gplace("", name="tanpa id")]
    assert [p.id for p in search(make(Calls(ok(*items))))] == ["good"]


def test_missing_name_becomes_empty_string_and_service_layer_handles_it():
    place = gplace("n")
    del place["displayName"]
    assert search(make(Calls(ok(place))))[0].name == ""


def test_rating_and_open_now_are_parsed_when_present():
    place = gplace("r", rating=4.4, currentOpeningHours={"openNow": False})
    got = search(make(Calls(ok(place)), PLACES_GOOGLE_RATING_HOURS="true"))[0]
    assert got.rating == 4.4 and got.open_now is False
    odd = gplace("o", rating="bagus", currentOpeningHours={"openNow": "ya"})
    got = search(make(Calls(ok(odd))))[0]
    assert got.rating is None and got.open_now is None


def test_places_field_of_wrong_type_is_a_bad_response():
    with pytest.raises(PlacesError) as exc:
        search(make(Calls(httpx.Response(200, json={"places": "x"}), httpx.Response(200, json={"places": "x"}))))
    assert exc.value.kind == "bad_response"


@pytest.mark.parametrize("response", [httpx.Response(200, text="<html>bad gateway</html>"),
                                      httpx.Response(200, json=["bukan", "objek"])])
def test_garbage_200_is_a_bad_response_and_retried_once(response):
    calls = Calls(response)
    with pytest.raises(PlacesError) as exc:
        search(make(calls))
    assert exc.value.kind == "bad_response" and len(calls.requests) == 2


# --------------------------------------------------------------------- error mapping
@pytest.mark.parametrize("response,kind,hint_part", [
    (gerr(400, "API key not valid. Please pass a valid API key.", "INVALID_ARGUMENT", "API_KEY_INVALID"), "auth",
     "tidak mengenali"),
    (gerr(403, "Places API (New) has not been used in project 123 before or it is disabled.", "PERMISSION_DENIED",
          "SERVICE_DISABLED"), "auth", "Places API (New)"),
    (gerr(403, "This API method requires billing to be enabled.", "PERMISSION_DENIED", "BILLING_DISABLED"), "auth",
     "Billing"),
    (gerr(403, "Requests to this API places.googleapis.com are blocked.", "PERMISSION_DENIED",
          "API_KEY_SERVICE_BLOCKED"), "auth", "API restrictions"),
    (gerr(403, "IP address restriction.", "PERMISSION_DENIED", "API_KEY_IP_ADDRESS_BLOCKED"), "auth", "IP"),
    (gerr(403, "Referer restriction.", "PERMISSION_DENIED", "API_KEY_ANDROID_APP_BLOCKED"), "auth", "server"),
    (gerr(401, "unauthenticated"), "auth", None),
    (gerr(429, "Quota exceeded", "RESOURCE_EXHAUSTED"), "rate_limited", "quota"),
    (gerr(400, "Invalid includedTypes", "INVALID_ARGUMENT"), "bad_request", None),
    (gerr(404, "not found"), "bad_request", None),
    (gerr(500, "Internal error", "INTERNAL"), "upstream", None),
    (gerr(503, "unavailable", "UNAVAILABLE"), "upstream", None),
])
def test_http_errors_are_classified_with_helpful_hints(response, kind, hint_part):
    with pytest.raises(PlacesError) as exc:
        search(make(Calls(response)))
    assert exc.value.kind == kind
    if hint_part:
        assert hint_part.lower() in (exc.value.hint or "").lower()
    else:
        assert exc.value.hint is None


def test_non_json_error_body_is_still_classified():
    with pytest.raises(PlacesError) as exc:
        search(make(Calls(httpx.Response(502, text="<html>Bad Gateway</html>"))))
    assert exc.value.kind == "upstream" and exc.value.status == 502


def test_api_key_echoed_by_google_is_redacted():
    with pytest.raises(PlacesError) as exc:
        search(make(Calls(gerr(403, f"The provided API key {KEY} is not allowed", "PERMISSION_DENIED"))))
    assert KEY not in exc.value.detail and "***" in exc.value.detail


def test_api_key_is_never_logged(caplog):
    with caplog.at_level(logging.DEBUG, logger="driving_buddy.places"):
        search(make(Calls(ok(gplace()))))
        with pytest.raises(PlacesError):
            search(make(Calls(gerr(403, f"bad key {KEY}", "PERMISSION_DENIED"))))
    assert KEY not in caplog.text


# ---------------------------------------------------------------------- retry/timeout
def test_5xx_is_retried_once_then_succeeds():
    calls = Calls(gerr(503, "overloaded"), ok(gplace()))
    assert len(search(make(calls))) == 1 and len(calls.requests) == 2


def test_gives_up_after_max_retries_and_max_retries_zero_means_one_attempt():
    calls = Calls(gerr(500, "boom"))
    with pytest.raises(PlacesError) as exc:
        search(make(calls))
    assert exc.value.kind == "upstream" and len(calls.requests) == 2
    calls0 = Calls(gerr(500, "boom"))
    with pytest.raises(PlacesError):
        search(make(calls0, PLACES_MAX_RETRIES="0"))
    assert len(calls0.requests) == 1


def test_429_is_retried_only_when_google_asks_for_a_short_wait():
    short = Calls(gerr(429, "slow down", "RESOURCE_EXHAUSTED", headers={"retry-after": "0"}), ok(gplace()))
    assert len(search(make(short))) == 1 and len(short.requests) == 2
    for headers in ({"retry-after": "30"}, {}):
        calls = Calls(gerr(429, "quota", "RESOURCE_EXHAUSTED", headers=headers))
        with pytest.raises(PlacesError) as exc:
            search(make(calls))
        assert exc.value.kind == "rate_limited" and len(calls.requests) == 1


def test_auth_and_bad_request_are_not_retried():
    for response in (gerr(403, "nope", "PERMISSION_DENIED", "SERVICE_DISABLED"), gerr(400, "bad", "INVALID_ARGUMENT")):
        calls = Calls(response)
        with pytest.raises(PlacesError):
            search(make(calls))
        assert len(calls.requests) == 1


def test_timeout_is_reported_without_retry():
    calls = Calls(httpx.ReadTimeout("lambat"))
    with pytest.raises(PlacesError) as exc:
        search(make(calls))
    assert exc.value.kind == "timeout" and len(calls.requests) == 1


def test_connection_error_is_retried_then_reported_as_network():
    calls = Calls(httpx.ConnectError("tidak bisa konek"))
    with pytest.raises(PlacesError) as exc:
        search(make(calls))
    assert exc.value.kind == "network" and len(calls.requests) == 2


def test_hard_deadline_even_if_the_server_trickles():
    async def slow(request):
        await asyncio.sleep(2)
        return ok()

    with pytest.raises(PlacesError) as exc:
        search(make(slow, PLACES_TIMEOUT_S="0.2"))
    assert exc.value.kind == "timeout"


# ---------------------------------------------------------------------------- jatah
def test_budget_is_charged_for_every_http_attempt_including_retries():
    budget = CountingBudget()
    search(make(Calls(gerr(503, "x"), ok(gplace()))), budget=budget)
    assert budget.calls == 2
    budget2 = CountingBudget()
    with pytest.raises(PlacesError):
        search(make(Calls(gerr(500, "x"))), budget=budget2)
    assert budget2.calls == 2
    budget3 = CountingBudget()
    search(make(Calls(ok())), budget=budget3)
    assert budget3.calls == 1


def test_exhausted_budget_stops_before_any_http_request():
    calls = Calls(ok(gplace()))
    with pytest.raises(PlacesError) as exc:
        search(make(calls), budget=CountingBudget(limit=0))
    assert exc.value.kind == "budget_exhausted" and calls.requests == []


def test_budget_running_out_mid_retry_stops_the_retry():
    calls = Calls(gerr(500, "x"), ok(gplace()))
    with pytest.raises(PlacesError) as exc:
        search(make(calls), budget=CountingBudget(limit=1))
    assert exc.value.kind == "budget_exhausted" and len(calls.requests) == 1


def test_probe_returns_the_number_of_results():
    assert run(make(Calls(ok(gplace("a"), gplace("b")))).probe(NO_BUDGET)) == 2
