import re

import pytest

from nearby_places import categories
from nearby_places.config import (DEFAULT_MONTHLY_BUDGET_ENTERPRISE, DEFAULT_MONTHLY_BUDGET_PRO, load_settings,
                                  parse_env_file)

KEY = "AIzaSyTestKey123"


def env(**kw):
    base = {"PLACES_USAGE_FILE": "off"}
    base.update(kw)
    return load_settings(base)


# ------------------------------------------------------------------ kategori
def test_all_categories_are_complete():
    assert list(categories.CATEGORIES) == ["rest_area", "minimarket", "lodging", "spbu"]
    for key, cat in categories.CATEGORIES.items():
        assert cat.key == key
        assert cat.google_types and all(re.fullmatch(r"[a-z_]+", t) for t in cat.google_types)
        assert cat.osm_filters and all(vals for _, vals in cat.osm_filters)
        assert 100 <= cat.default_radius_m <= 50000
        assert cat.label and cat.speech


def test_card_categories_use_the_right_google_types():
    c = categories.CATEGORIES
    assert c["rest_area"].google_types == ("rest_stop",)
    assert c["minimarket"].google_types == ("convenience_store",)
    assert {"hotel", "motel"} <= set(c["lodging"].google_types)


def test_all_means_the_three_card_categories_and_not_spbu():
    assert [c.key for c in categories.expand("all")] == ["rest_area", "minimarket", "lodging"]
    assert [c.key for c in categories.expand("spbu")] == ["spbu"]
    assert categories.valid_keys() == ["all", "rest_area", "minimarket", "lodging", "spbu"]
    with pytest.raises(KeyError):
        categories.expand("bank")


# -------------------------------------------------------------------- config
def test_empty_environment_is_mock_and_ready():
    s = load_settings({})
    assert s.provider == "mock" and s.configured and s.fallback_provider == ""
    assert any("MOCK" in n for n in s.notes)
    assert s.usage_file and s.usage_file.endswith(".places_usage.json")


def test_google_is_picked_when_only_the_key_is_set():
    s = env(GOOGLE_PLACES_API_KEY=KEY)
    assert s.provider == "google" and s.configured


def test_placeholder_key_without_provider_stays_mock_and_with_provider_is_a_problem():
    assert env(GOOGLE_PLACES_API_KEY="YOUR_GOOGLE_PLACES_API_KEY").provider == "mock"
    s = env(PLACES_PROVIDER="google", GOOGLE_PLACES_API_KEY="YOUR_GOOGLE_PLACES_API_KEY")
    assert not s.configured and "contoh" in s.problem


def test_google_without_key_is_a_clear_problem():
    s = env(PLACES_PROVIDER="google")
    assert not s.configured and "GOOGLE_PLACES_API_KEY" in s.problem


def test_osm_needs_no_key_but_warns_about_fair_use():
    s = env(PLACES_PROVIDER="osm")
    assert s.configured and any("fair use" in n for n in s.notes)


def test_unknown_provider_is_a_problem():
    s = env(PLACES_PROVIDER="bing")
    assert not s.configured and "bing" in s.problem


def test_key_with_space_or_quote_is_rejected():
    for bad in ("AIza abc", 'AIza"abc', "AIza'abc"):
        assert not env(PLACES_PROVIDER="google", GOOGLE_PLACES_API_KEY=bad).configured


def test_key_is_never_in_repr():
    assert KEY not in repr(env(GOOGLE_PLACES_API_KEY=KEY))


def test_plain_http_to_a_remote_host_is_refused_but_localhost_is_fine():
    bad = env(GOOGLE_PLACES_API_KEY=KEY, GOOGLE_PLACES_BASE_URL="http://places.example.com/v1")
    assert not bad.configured and "https" in bad.problem
    assert env(GOOGLE_PLACES_API_KEY=KEY, GOOGLE_PLACES_BASE_URL="http://127.0.0.1:9200/v1/").configured
    assert env(GOOGLE_PLACES_API_KEY=KEY, GOOGLE_PLACES_BASE_URL="http://localhost:9200/v1").configured
    assert env(GOOGLE_PLACES_API_KEY=KEY, GOOGLE_PLACES_BASE_URL="https://proxy.example.com/v1").configured
    assert not env(GOOGLE_PLACES_API_KEY=KEY, GOOGLE_PLACES_BASE_URL="ftp://x").configured
    assert env(GOOGLE_PLACES_API_KEY=KEY, GOOGLE_PLACES_BASE_URL="https://x.test/v1/").google_base_url == "https://x.test/v1"


def test_bad_osm_url_is_a_problem_only_when_osm_is_used():
    assert not env(PLACES_PROVIDER="osm", PLACES_OSM_URL="nope").configured
    assert env(PLACES_PROVIDER="mock", PLACES_OSM_URL="nope").configured


def test_fallback_provider_rules():
    assert env(PLACES_PROVIDER="google", GOOGLE_PLACES_API_KEY=KEY, PLACES_FALLBACK_PROVIDER="osm").fallback_provider == "osm"
    assert env(PLACES_PROVIDER="osm", PLACES_FALLBACK_PROVIDER="osm").fallback_provider == ""
    assert env(PLACES_PROVIDER="google", GOOGLE_PLACES_API_KEY=KEY, PLACES_FALLBACK_PROVIDER="none").fallback_provider == ""
    s = env(PLACES_PROVIDER="google", GOOGLE_PLACES_API_KEY=KEY, PLACES_FALLBACK_PROVIDER="bing")
    assert s.fallback_provider == "" and s.configured and any("bing" in n for n in s.notes)


def test_monthly_budget_default_depends_on_rating_hours():
    s = env(PLACES_PROVIDER="google", GOOGLE_PLACES_API_KEY=KEY)
    assert (s.google_daily_budget, s.google_monthly_budget) == (300, DEFAULT_MONTHLY_BUDGET_PRO) == (300, 4500)
    pro = env(PLACES_PROVIDER="google", GOOGLE_PLACES_API_KEY=KEY, PLACES_GOOGLE_RATING_HOURS="true")
    assert pro.google_rating_hours and pro.google_monthly_budget == DEFAULT_MONTHLY_BUDGET_ENTERPRISE == 900
    assert any("Enterprise" in n for n in pro.notes)
    explicit = env(PLACES_PROVIDER="google", GOOGLE_PLACES_API_KEY=KEY, PLACES_GOOGLE_RATING_HOURS="1",
                   PLACES_GOOGLE_MONTHLY_BUDGET="500")
    assert explicit.google_monthly_budget == 500


def test_default_budgets_stay_below_the_free_tiers():
    assert DEFAULT_MONTHLY_BUDGET_PRO < 5000 and DEFAULT_MONTHLY_BUDGET_ENTERPRISE < 1000


def test_zero_budget_means_unlimited_but_warns():
    s = env(PLACES_PROVIDER="google", GOOGLE_PLACES_API_KEY=KEY, PLACES_GOOGLE_DAILY_BUDGET="0")
    assert s.budget_for("google") == (0, 4500) and any("quota cap" in n for n in s.notes)
    assert s.budget_for("osm") == (500, 0) and s.budget_for("mock") == (0, 0)


def test_numbers_are_clamped_or_defaulted_with_a_note():
    s = env(PLACES_TIMEOUT_S="999", PLACES_MAX_RETRIES="x", PLACES_CACHE_TTL_S="-5", PLACES_MAX_RADIUS_M="99999")
    assert s.timeout_s == 30.0 and s.max_retries == 1 and s.cache_ttl_s == 0.0 and s.max_radius_m == 50000
    assert len(s.notes) >= 4
    assert env(PLACES_TIMEOUT_S="nan").timeout_s == 4.0


def test_bad_flag_value_falls_back_to_default():
    s = env(PLACES_GOOGLE_RATING_HOURS="mungkin")
    assert s.google_rating_hours is False and any("true/false" in n for n in s.notes)


def test_google_types_override():
    s = env(PLACES_GOOGLE_TYPES_REST_AREA=" Rest_Stop , truck_stop,rest_stop ")
    assert s.google_types["rest_area"] == ("rest_stop", "truck_stop")
    assert s.google_types["minimarket"] == ("convenience_store",)


@pytest.mark.parametrize("raw", ["rest stop", "Rest-Stop", ",,", ",".join(f"t{i}" for i in range(51))])
def test_invalid_google_types_keep_the_default(raw):
    s = env(PLACES_GOOGLE_TYPES_REST_AREA=raw)
    assert s.google_types["rest_area"] == ("rest_stop",) and any("PLACES_GOOGLE_TYPES_REST_AREA" in n for n in s.notes)


def test_language_and_region_are_validated():
    s = env(PLACES_LANGUAGE="en-US", PLACES_REGION="my")
    assert (s.language, s.region) == ("en-US", "MY")
    bad = env(PLACES_LANGUAGE="indonesia!!", PLACES_REGION="IDN")
    assert (bad.language, bad.region) == ("id", "ID")


def test_usage_file_setting():
    assert env(PLACES_USAGE_FILE="off").usage_file is None
    assert env(PLACES_USAGE_FILE="/tmp/x.json").usage_file == "/tmp/x.json"


def test_env_file_is_read_and_real_environment_wins(tmp_path):
    f = tmp_path / ".env"
    f.write_text('# komentar\nPLACES_PROVIDER=osm\nexport PLACES_REGION="MY"\nPLACES_LANGUAGE=en  # inline\n'
                 'PLACES_USAGE_FILE=off\n')
    assert parse_env_file(f) == {"PLACES_PROVIDER": "osm", "PLACES_REGION": "MY", "PLACES_LANGUAGE": "en",
                                 "PLACES_USAGE_FILE": "off"}
    s = load_settings({}, env_file=str(f))
    assert (s.provider, s.region, s.language) == ("osm", "MY", "en")
    assert load_settings({"PLACES_PROVIDER": "mock"}, env_file=str(f)).provider == "mock"
    assert parse_env_file(tmp_path / "tidak-ada") == {}
