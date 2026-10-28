"""Tes endpoint /chat lewat FastAPI TestClient, dengan LLM tiruan (stub)."""
import asyncio

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from conftest import run
from llm_chat import build_router, load_settings
from llm_chat.client import BaseLLM, LLMError, LLMResult, OpenAICompatLLM
from llm_chat.prompts import FALLBACK_REPLIES


class StubLLM(BaseLLM):
    provider = "stub"
    model = "stub-1"

    def __init__(self, reply="Halo juga!", error=None, delay=0.0):
        self.reply, self.error, self.delay = reply, error, delay
        self.calls = []
        self.events = []
        self.models_calls = 0
        self.models_error = None

    async def complete(self, messages):
        self.calls.append(messages)
        self.events.append("start")
        if self.delay:
            await asyncio.sleep(self.delay)
        self.events.append("end")
        if self.error:
            raise self.error
        return LLMResult(text=self.reply, model="stub-1")

    async def list_models(self):
        self.models_calls += 1
        if self.models_error:
            raise self.models_error
        return ["stub-1"]


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


ENV = {"LLM_PROVIDER": "custom", "LLM_BASE_URL": "http://stub.local/v1", "LLM_MODEL": "stub-1"}


def make_app(llm=None, clock=None, **env):
    settings = load_settings({**ENV, **env})
    app = FastAPI()
    kwargs = {"clock": clock} if clock else {}
    app.include_router(build_router(settings, llm=llm, **kwargs))
    return app


def make_client(llm=None, clock=None, **env):
    return TestClient(make_app(llm, clock, **env))


def post(client, message="Halo", session_id="s1", **extra):
    return client.post("/chat", json={"session_id": session_id, "message": message, **extra})


# ----------------------------------------------------------------- jalur normal
def test_happy_path_returns_cleaned_reply():
    llm = StubLLM(reply="**Halo** \U0001F600 apa kabar?")
    r = post(make_client(llm))
    assert r.status_code == 200
    body = r.json()
    assert body["reply"] == "Halo apa kabar?"
    assert body["fallback"] is False and body["error"] is None
    assert body["provider"] == "custom" and body["model"] == "stub-1"
    assert body["session_id"] == "s1"
    assert body["latency_ms"] >= 0


def test_history_is_remembered_per_session_and_reset_works():
    llm = StubLLM()
    c = make_client(llm)
    post(c, "pertama")
    post(c, "kedua")
    roles = [m["role"] for m in llm.calls[1]]
    assert roles == ["system", "user", "assistant", "user"]
    assert llm.calls[1][1]["content"] == "pertama"
    assert llm.calls[1][2]["content"] == "Halo juga!"  # yang disimpan = balasan yang sudah dibersihkan

    post(c, "sesi lain", session_id="s2")
    assert [m["role"] for m in llm.calls[2]] == ["system", "user"]  # sesi lain tidak bocor

    post(c, "ketiga", reset=True)
    assert [m["role"] for m in llm.calls[3]] == ["system", "user"]


def test_delete_clears_history():
    llm = StubLLM()
    c = make_client(llm)
    post(c, "satu")
    assert c.delete("/chat/s1").json() == {"session_id": "s1", "cleared": True}
    assert c.delete("/chat/s1").json()["cleared"] is False
    post(c, "dua")
    assert len(llm.calls[1]) == 2
    assert c.delete("/chat/id%20salah!").status_code == 422


def test_sensor_data_reaches_the_prompt_in_camel_case():
    llm = StubLLM()
    r = post(make_client(llm), driver_state={"status": "Drowsy", "yawnCount": 3, "blinkCount": 28})
    assert r.status_code == 200
    system = llm.calls[0][0]["content"]
    assert "menguap 3x" in system and "mengantuk" in system
    assert sum(m["role"] == "system" for m in llm.calls[0]) == 1


def test_history_is_trimmed_to_configured_turns():
    llm = StubLLM()
    c = make_client(llm, LLM_HISTORY_TURNS="2")
    for i in range(5):
        post(c, f"pesan {i}")
    sent = [m["content"] for m in llm.calls[-1] if m["role"] == "user"]
    assert sent == ["pesan 2", "pesan 3", "pesan 4"]  # 2 giliran terakhir + pesan baru


# -------------------------------------------------------------------- gagal
def test_llm_failure_returns_200_with_fallback_and_does_not_store_turn():
    llm = StubLLM(error=LLMError("timeout", "lambat"))
    c = make_client(llm)
    r = post(c, "halo")
    assert r.status_code == 200
    body = r.json()
    assert body["fallback"] is True and body["error"] == "timeout"
    assert body["reply"] == FALLBACK_REPLIES[0]

    llm.error = None
    post(c, "coba lagi")
    assert [m["role"] for m in llm.calls[1]] == ["system", "user"]  # giliran yang gagal tidak tersimpan


def test_fallback_still_carries_the_safety_message():
    llm = StubLLM(error=LLMError("rate_limited"))
    r = post(make_client(llm), driver_state={"status": "Sleep"})
    assert r.json()["reply"] == FALLBACK_REPLIES[2]
    assert "menepi" in r.json()["reply"]


def test_unexpected_exception_is_contained():
    r = post(make_client(StubLLM(error=RuntimeError("bug"))))
    assert r.status_code == 200
    assert r.json()["fallback"] is True and r.json()["error"] == "internal"


def test_reply_that_is_empty_after_cleaning_triggers_fallback():
    r = post(make_client(StubLLM(reply="\U0001F600\U0001F600")))
    assert r.json()["fallback"] is True and r.json()["error"] == "empty"


# ---------------------------------------------------------------- validasi
@pytest.mark.parametrize("payload", [
    {},
    {"session_id": "s1"},
    {"message": "tanpa sesi"},
    {"session_id": "s1", "message": ""},
    {"session_id": "s1", "message": "   "},
    {"session_id": "s1", "message": "x" * 501},
    {"session_id": "id salah!", "message": "halo"},
    {"session_id": "a" * 65, "message": "halo"},
    {"session_id": "s1", "message": "halo", "driver_state": {"yawnCount": -1}},
])
def test_invalid_requests_are_rejected_with_422(payload):
    llm = StubLLM()
    r = make_client(llm).post("/chat", json=payload)
    assert r.status_code == 422
    assert llm.calls == []


def test_unknown_extra_fields_are_ignored():
    r = post(make_client(StubLLM()), driver_state={"status": "Awake", "ear": 0.3, "eyePoints": [[1, 2]]}, lang="id")
    assert r.status_code == 200


# --------------------------------------------------------- belum dikonfigurasi
def test_not_configured_returns_503_and_health_explains():
    c = make_client(None, LLM_PROVIDER="groq", LLM_BASE_URL="", LLM_MODEL="")  # groq tanpa API key
    r = post(c)
    assert r.status_code == 503
    assert r.json()["detail"]["error"] == "llm_not_configured"
    assert "API key" in r.json()["detail"]["message"]

    h = c.get("/chat/health").json()
    assert h["status"] == "not_configured" and "API key" in h["problem"]
    assert c.get("/chat/health?deep=true").status_code == 200  # tidak error walau belum siap


# ------------------------------------------------------------- rate limit
def test_per_session_rate_limit_with_retry_after_and_recovery():
    clock = Clock()
    c = make_client(StubLLM(), clock=clock, LLM_RATE_PER_SESSION_PER_MIN="2")
    assert post(c).status_code == 200
    assert post(c).status_code == 200
    r = post(c)
    assert r.status_code == 429
    assert r.json()["detail"]["error"] == "rate_limited"
    assert int(r.headers["retry-after"]) >= 1
    assert post(c, session_id="lain").status_code == 200  # sesi lain tidak terdampak
    clock.now += 61
    assert post(c).status_code == 200


def test_global_rate_limit_spans_sessions():
    c = make_client(StubLLM(), LLM_RATE_GLOBAL_PER_MIN="2")
    assert post(c, session_id="a").status_code == 200
    assert post(c, session_id="b").status_code == 200
    assert post(c, session_id="c").status_code == 429


# -------------------------------------------------------------------- health
def test_health_reports_status_without_secrets():
    c = make_client(StubLLM(), LLM_API_KEY="gsk_rahasia_banget")
    text = c.get("/chat/health").text
    assert '"status":"ok"' in text.replace(" ", "")
    assert "gsk_rahasia_banget" not in text


def test_deep_health_checks_provider_and_caches():
    llm = StubLLM()
    clock = Clock()
    c = make_client(llm, clock=clock)
    h = c.get("/chat/health?deep=true").json()
    assert h["reachable"] is True and h["model_available"] is True
    c.get("/chat/health?deep=true")
    assert llm.models_calls == 1  # hasil di-cache 30 detik
    clock.now += 31
    c.get("/chat/health?deep=true")
    assert llm.models_calls == 2


def test_deep_health_reports_provider_failure_without_leaking_detail():
    llm = StubLLM()
    llm.models_error = LLMError("auth", "Incorrect API key provided: sk-abc...XYZ", status=401)
    h = make_client(llm).get("/chat/health?deep=true").json()
    assert h["reachable"] is False and h["error"] == "auth" and h["http_status"] == 401
    assert "sk-abc" not in str(h)


def test_deep_health_flags_unknown_model():
    llm = StubLLM()
    h = make_client(llm, LLM_MODEL="model-yang-salah").get("/chat/health?deep=true").json()
    assert h["reachable"] is True and h["model_available"] is False


# ------------------------------------------------------------- konkurensi
def test_requests_in_one_session_are_serialised():
    async def scenario():
        llm = StubLLM(delay=0.05)
        app = make_app(llm)
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            payload = {"session_id": "s1", "message": "halo"}
            r1, r2 = await asyncio.gather(client.post("/chat", json=payload), client.post("/chat", json=payload))
        assert r1.status_code == r2.status_code == 200
        return llm

    llm = run(scenario())
    assert llm.events == ["start", "end", "start", "end"]  # tidak tumpang tindih
    assert [m["role"] for m in llm.calls[1]] == ["system", "user", "assistant", "user"]  # urutan percakapan terjaga


def test_different_sessions_run_in_parallel():
    async def scenario():
        llm = StubLLM(delay=0.05)
        app = make_app(llm)
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            await asyncio.gather(
                client.post("/chat", json={"session_id": "a", "message": "halo"}),
                client.post("/chat", json={"session_id": "b", "message": "halo"}),
            )
        return llm

    assert run(scenario()).events == ["start", "start", "end", "end"]


# ---------------------------------------------- client asli + router bersama
def test_router_with_real_client_over_mock_transport():
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(200, json={
            "model": "llama-x",
            "choices": [{"message": {"content": "Siap, aku temenin ya."}, "finish_reason": "stop"}],
        })

    settings = load_settings({"LLM_PROVIDER": "groq", "LLM_API_KEY": "gsk_x"})
    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    app = FastAPI()
    app.include_router(build_router(settings, llm=OpenAICompatLLM(settings, http)))
    r = post(TestClient(app), "temenin dong")
    assert r.json()["reply"] == "Siap, aku temenin ya."
    assert r.json()["model"] == "llama-x" and r.json()["provider"] == "groq"
    assert len(seen) == 1
