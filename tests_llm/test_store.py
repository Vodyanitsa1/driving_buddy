from llm_chat.store import RateLimiter, SessionStore


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def test_history_keeps_only_last_n_turns():
    store = SessionStore(history_turns=2)
    s = store.get("a")
    for i in range(3):
        s.add_turn(f"tanya{i}", f"jawab{i}")
    assert [m["content"] for m in s.history] == ["tanya1", "jawab1", "tanya2", "jawab2"]
    assert s.history[0]["role"] == "user"  # selalu diawali pesan user


def test_zero_history_turns_stores_nothing():
    s = SessionStore(history_turns=0).get("a")
    s.add_turn("x", "y")
    assert list(s.history) == []


def test_session_expires_after_ttl():
    clock = Clock()
    store = SessionStore(ttl_s=100, clock=clock)
    store.get("a").add_turn("x", "y")
    clock.now += 99
    assert len(store.get("a").history) == 2  # masih hidup (dan diperpanjang)
    clock.now += 101
    assert len(store) == 0
    assert len(store.get("a").history) == 0


def test_lru_eviction_drops_least_recently_used():
    store = SessionStore(max_sessions=2)
    store.get("a")
    store.get("b")
    store.get("a")  # a jadi yang terbaru
    store.get("c")  # b yang paling lama tak dipakai -> dibuang
    assert len(store) == 2
    store.get("a").add_turn("x", "y")
    assert len(store.get("a").history) == 2
    assert store.reset("b") is False


def test_reset():
    store = SessionStore()
    store.get("a").add_turn("x", "y")
    assert store.reset("a") is True
    assert store.reset("a") is False
    assert len(store.get("a").history) == 0


def test_rate_limiter_sliding_window():
    clock = Clock()
    limiter = RateLimiter(3, window_s=60, clock=clock)
    assert [limiter.hit("k")[0] for _ in range(3)] == [True, True, True]
    allowed, wait = limiter.hit("k")
    assert allowed is False and 59 <= wait <= 60
    clock.now += 61
    assert limiter.hit("k")[0] is True


def test_rejected_hits_do_not_extend_the_ban():
    clock = Clock()
    limiter = RateLimiter(1, window_s=60, clock=clock)
    assert limiter.hit("k")[0]
    for _ in range(10):
        clock.now += 5
        assert limiter.hit("k")[0] is False
    clock.now += 11  # total 61 detik sejak hit pertama
    assert limiter.hit("k")[0] is True


def test_rate_limiter_keys_are_independent_and_zero_disables():
    limiter = RateLimiter(1)
    assert limiter.hit("a")[0] and limiter.hit("b")[0]
    assert limiter.hit("a")[0] is False
    off = RateLimiter(0)
    assert all(off.hit("a")[0] for _ in range(100))


def test_rate_limiter_sweeps_idle_keys():
    clock = Clock()
    limiter = RateLimiter(5, window_s=60, clock=clock)
    for i in range(255):
        limiter.hit(f"k{i}")
    clock.now += 120
    limiter.hit("baru")  # panggilan ke-256 memicu sweep
    assert set(limiter._hits) == {"baru"}
