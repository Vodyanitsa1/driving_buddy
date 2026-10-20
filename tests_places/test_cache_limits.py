import json
import logging

import pytest

from nearby_places.cache import NearbyCache
from nearby_places.geo import destination_point
from nearby_places.limits import LedgerBudget, RateLimiter, UsageLedger
from nearby_places.providers.base import Place, PlacesError

LAT, LNG = -6.2, 106.8


def place(pid="p1"):
    return Place(id=pid, name=pid, lat=LAT, lng=LNG)


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


# ----------------------------------------------------------------- cache
def test_cache_hit_within_tolerance_and_miss_beyond():
    clock = Clock()
    cache = NearbyCache(ttl_s=90, tolerance_m=250, clock=clock)
    cache.put("google", "rest_area", 30000, LAT, LNG, [place()])
    near = destination_point(LAT, LNG, 45, 200)
    far = destination_point(LAT, LNG, 45, 400)
    assert cache.get("google", "rest_area", 30000, *near) == [place()]
    assert cache.get("google", "rest_area", 30000, *far) is None


def test_cache_key_includes_provider_category_and_radius():
    cache = NearbyCache(clock=Clock())
    cache.put("google", "rest_area", 30000, LAT, LNG, [place()])
    assert cache.get("osm", "rest_area", 30000, LAT, LNG) is None
    assert cache.get("google", "minimarket", 30000, LAT, LNG) is None
    assert cache.get("google", "rest_area", 5000, LAT, LNG) is None
    assert cache.get("google", "rest_area", 30000, LAT, LNG) is not None


def test_cache_expires_after_ttl():
    clock = Clock()
    cache = NearbyCache(ttl_s=90, clock=clock)
    cache.put("google", "spbu", 1000, LAT, LNG, [place()])
    clock.t += 90
    assert cache.get("google", "spbu", 1000, LAT, LNG) is not None
    clock.t += 0.1
    assert cache.get("google", "spbu", 1000, LAT, LNG) is None
    assert len(cache) == 0


def test_empty_result_is_cached_and_distinguishable_from_a_miss():
    cache = NearbyCache(clock=Clock())
    assert cache.get("google", "rest_area", 30000, LAT, LNG) is None
    cache.put("google", "rest_area", 30000, LAT, LNG, [])
    assert cache.get("google", "rest_area", 30000, LAT, LNG) == []


def test_cache_prefers_the_closest_entry_and_returns_copies():
    cache = NearbyCache(clock=Clock(), tolerance_m=500)
    a = destination_point(LAT, LNG, 0, 300)
    cache.put("g", "c", 1, *a, [place("a")])
    cache.put("g", "c", 1, LAT, LNG, [place("b")])
    got = cache.get("g", "c", 1, LAT, LNG)
    assert [p.id for p in got] == ["b"]
    got.append(place("zzz"))
    assert [p.id for p in cache.get("g", "c", 1, LAT, LNG)] == ["b"]


def test_cache_is_bounded_and_lru():
    cache = NearbyCache(max_entries=2, clock=Clock())
    for i in range(3):
        p = destination_point(LAT, LNG, 0, 10_000 * i)
        cache.put("g", "c", 1, *p, [place(str(i))])
    assert len(cache) == 2
    assert cache.get("g", "c", 1, LAT, LNG) is None  # entri paling lama dibuang


def test_cache_disabled_when_ttl_is_zero():
    cache = NearbyCache(ttl_s=0, clock=Clock())
    cache.put("g", "c", 1, LAT, LNG, [place()])
    assert cache.get("g", "c", 1, LAT, LNG) is None and len(cache) == 0


# ---------------------------------------------------------- rate limiter
def test_rate_limiter_sliding_window():
    clock = Clock()
    rl = RateLimiter(2, window_s=60, clock=clock)
    assert rl.hit("a") == (True, 0.0) and rl.hit("a") == (True, 0.0)
    ok, wait = rl.hit("a")
    assert not ok and wait == pytest.approx(60)
    assert rl.hit("b")[0] is True  # key lain tidak terpengaruh
    clock.t += 61
    assert rl.hit("a")[0] is True


def test_rate_limiter_disabled_and_sweeps_old_keys():
    assert RateLimiter(0).hit("x") == (True, 0.0)
    clock = Clock()
    rl = RateLimiter(1000, window_s=10, clock=clock)
    for i in range(300):
        rl.hit(f"k{i}")
    assert len(rl._hits) == 300
    clock.t += 100  # semua key lama sudah di luar jendela
    for _ in range(300):  # total permintaan yang diizinkan melewati kelipatan 256 -> penyapuan berjalan
        rl.hit("fresh")
    assert set(rl._hits) == {"fresh"}


# ---------------------------------------------------------------- ledger
JAKARTA_NOON = 1_760_000_000.0  # 2025-10-09 ~08:53 UTC


class Wall:
    def __init__(self, t=JAKARTA_NOON):
        self.t = t

    def __call__(self):
        return self.t


def test_ledger_enforces_daily_and_monthly_limits():
    ledger = UsageLedger(None, wall_clock=Wall())
    assert [ledger.reserve("google", 3, 100) for _ in range(4)] == [None, None, None, "daily"]
    assert ledger.snapshot("google") == {"today": 3, "month": 3}  # yang ditolak tidak dihitung
    ledger2 = UsageLedger(None, wall_clock=Wall())
    assert [ledger2.reserve("google", 0, 2) for _ in range(3)] == [None, None, "monthly"]


def test_ledger_zero_limit_means_unlimited_and_providers_are_separate():
    ledger = UsageLedger(None, wall_clock=Wall())
    assert all(ledger.reserve("osm", 0, 0) is None for _ in range(50))
    assert ledger.snapshot("osm")["today"] == 50 and ledger.snapshot("google")["today"] == 0


def test_ledger_rolls_over_at_local_midnight_not_utc_midnight():
    # 2025-10-09 16:59 UTC = 23:59 WIB; semenit kemudian sudah tanggal 10 di WIB.
    wall = Wall(1_760_029_140.0)
    ledger = UsageLedger(None, tz_offset_hours=7, wall_clock=wall)
    assert ledger.reserve("google", 1, 100) is None
    assert ledger.reserve("google", 1, 100) == "daily"
    wall.t += 60
    assert ledger.reserve("google", 1, 100) is None  # hari baru
    assert ledger.snapshot("google") == {"today": 1, "month": 2}


def test_ledger_resets_the_month_counter_in_a_new_month():
    wall = Wall(1_761_929_940.0)  # 2025-10-31 23:59 WIB (= 16:59 UTC)
    ledger = UsageLedger(None, tz_offset_hours=7, wall_clock=wall)
    assert ledger.reserve("google", 0, 1) is None and ledger.reserve("google", 0, 1) == "monthly"
    wall.t += 120
    assert ledger.reserve("google", 0, 1) is None


def test_ledger_persists_across_restarts(tmp_path):
    path = str(tmp_path / "usage.json")
    wall = Wall()
    first = UsageLedger(path, wall_clock=wall)
    for _ in range(5):
        assert first.reserve("google", 0, 0) is None
    second = UsageLedger(path, wall_clock=wall)
    assert second.snapshot("google") == {"today": 5, "month": 5}
    assert second.reserve("google", 5, 0) == "daily"
    data = json.loads((tmp_path / "usage.json").read_text())
    assert data["version"] == 1 and data["counts"]["google"] == {"day": 5, "month": 5}


def test_ledger_ignores_stale_days_and_months_in_the_file(tmp_path):
    path = tmp_path / "usage.json"
    wall = Wall()
    UsageLedger(str(path), wall_clock=wall).reserve("google", 0, 0)
    wall.t += 86_400  # besok
    assert UsageLedger(str(path), wall_clock=wall).snapshot("google") == {"today": 0, "month": 1}
    wall.t += 40 * 86_400  # bulan depan
    assert UsageLedger(str(path), wall_clock=wall).snapshot("google") == {"today": 0, "month": 0}


@pytest.mark.parametrize("content", ["bukan json", "[]", '{"version": 99}', '{"version":1,"counts":{"g":{"day":-1,"month":0}}}',
                                     '{"version":1,"counts":{"g":{"day":"x","month":0}}}', '{"version":1,"counts":5}'])
def test_corrupt_usage_file_starts_from_zero_with_one_warning(tmp_path, caplog, content):
    path = tmp_path / "usage.json"
    path.write_text(content)
    with caplog.at_level(logging.WARNING, logger="driving_buddy.places"):
        ledger = UsageLedger(str(path), wall_clock=Wall())
        assert ledger.snapshot("google") == {"today": 0, "month": 0}
        assert ledger.reserve("google", 0, 0) is None
    assert sum("hitungan pemakaian" in r.getMessage() for r in caplog.records) == 1
    assert json.loads(path.read_text())["counts"]["google"]["day"] == 1  # file diperbaiki saat berikutnya menyimpan


def test_unusable_usage_path_does_not_break_counting(tmp_path, caplog):
    blocker = tmp_path / "file"
    blocker.write_text("x")
    with caplog.at_level(logging.WARNING, logger="driving_buddy.places"):
        ledger = UsageLedger(str(blocker / "sub" / "usage.json"), wall_clock=Wall())  # folder induk = file biasa
        assert ledger.reserve("google", 2, 0) is None and ledger.reserve("google", 2, 0) is None
        assert ledger.reserve("google", 2, 0) == "daily"
    assert sum("hitungan pemakaian" in r.getMessage() for r in caplog.records) == 1  # satu kali, tidak membanjiri log


def test_failing_save_is_reported_once_and_counting_continues(tmp_path, caplog, monkeypatch):
    import nearby_places.limits as limits

    def disk_full(src, dst):
        raise OSError("disk penuh")

    monkeypatch.setattr(limits.os, "replace", disk_full)
    ledger = UsageLedger(str(tmp_path / "usage.json"), wall_clock=Wall())
    with caplog.at_level(logging.WARNING, logger="driving_buddy.places"):
        assert [ledger.reserve("google", 0, 0) for _ in range(3)] == [None, None, None]
    assert ledger.snapshot("google")["today"] == 3
    assert sum("gagal menyimpan" in r.getMessage() for r in caplog.records) == 1


def test_ledger_budget_raises_budget_exhausted_with_the_env_name():
    ledger = UsageLedger(None, wall_clock=Wall())
    budget = LedgerBudget(ledger, "google", 1, 100)
    budget.take()
    with pytest.raises(PlacesError) as exc:
        budget.take()
    assert exc.value.kind == "budget_exhausted" and "PLACES_GOOGLE_DAILY_BUDGET" in exc.value.detail
    monthly = LedgerBudget(UsageLedger(None, wall_clock=Wall()), "google", 0, 1)
    monthly.take()
    with pytest.raises(PlacesError) as exc2:
        monthly.take()
    assert "PLACES_GOOGLE_MONTHLY_BUDGET" in exc2.value.detail
