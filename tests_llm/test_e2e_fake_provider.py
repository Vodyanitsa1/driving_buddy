"""Tes end-to-end lewat jaringan sungguhan (localhost):

    Flutter (httpx)  ->  API Driving Buddy (uvicorn + router /chat)  ->  fake provider OpenAI-compatible

Tidak butuh internet atau API key asli.
"""
import contextlib
import socket
import threading
import time

import httpx
import pytest
import uvicorn
from fastapi import FastAPI

from fake_openai import API_KEY, create_fake_provider
from llm_chat import build_router, load_settings
from llm_chat.prompts import FALLBACK_REPLIES


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def serve(app: FastAPI):
    port = free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.time() + 10
    while not server.started:
        assert time.time() < deadline, "server tidak mau start"
        time.sleep(0.02)
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.should_exit = True
        thread.join(10)


@pytest.fixture(scope="module")
def provider():
    with serve(create_fake_provider()) as url:
        yield url


@contextlib.contextmanager
def chat_api(provider_url, **env):
    """Jalankan API Driving Buddy yang diarahkan ke fake provider."""
    settings = load_settings({
        "LLM_PROVIDER": "custom",
        "LLM_BASE_URL": f"{provider_url}/v1",
        "LLM_MODEL": "fake-model",
        "LLM_API_KEY": API_KEY,
        "LLM_TIMEOUT_S": "0.5",
        **env,
    })
    app = FastAPI()
    app.include_router(build_router(settings))
    with serve(app) as url:
        yield httpx.Client(base_url=url, timeout=10)


def set_mode(provider_url, mode):
    httpx.post(f"{provider_url}/_mode", json={"mode": mode}).raise_for_status()


def provider_state(provider_url):
    return httpx.get(f"{provider_url}/_state").json()


def say(api, message="Halo", session_id="s1", **extra):
    return api.post("/chat", json={"session_id": session_id, "message": message, **extra})


def test_normal_conversation_end_to_end(provider):
    set_mode(provider, "ok")
    with chat_api(provider) as api:
        r = say(api, "Aku mulai ngantuk", driver_state={"status": "Drowsy", "yawnCount": 4})
        assert r.status_code == 200
        body = r.json()
        assert body["reply"] == "Halo dari fake provider! Kamu lagi di mana sekarang?"  # markdown + emoji dibersihkan
        assert body["fallback"] is False and body["model"] == "fake-model"

        sent = provider_state(provider)["requests"][0]
        assert sent["authorization"] == f"Bearer {API_KEY}"
        assert sent["body"]["model"] == "fake-model"
        assert sent["body"]["messages"][0]["role"] == "system"
        assert "menguap 4x" in sent["body"]["messages"][0]["content"]
        assert sent["body"]["messages"][-1] == {"role": "user", "content": "Aku mulai ngantuk"}

        say(api, "Lanjut dong")  # giliran kedua membawa riwayat giliran pertama
        roles = [m["role"] for m in provider_state(provider)["requests"][1]["body"]["messages"]]
        assert roles == ["system", "user", "assistant", "user"]

        assert api.get("/chat/health").json()["status"] == "ok"
        deep = api.get("/chat/health", params={"deep": "true"}).json()
        assert deep["reachable"] is True and deep["model_available"] is True


def test_slow_provider_gives_fast_fallback(provider):
    set_mode(provider, "slow")
    with chat_api(provider) as api:  # timeout 0.5 detik
        started = time.time()
        r = say(api, driver_state={"status": "Sleep"})
        elapsed = time.time() - started
        body = r.json()
        assert r.status_code == 200
        assert body["fallback"] is True and body["error"] == "timeout"
        assert body["reply"] == FALLBACK_REPLIES[2]  # pesan keselamatan tetap sampai
        assert elapsed < 1.5  # tidak ada retry: pengemudi tidak menunggu 2x batas waktu
        assert provider_state(provider)["calls"] == 1


def test_short_429_is_retried_transparently(provider):
    set_mode(provider, "429_then_ok")
    with chat_api(provider) as api:
        body = say(api).json()
        assert body["fallback"] is False
        assert provider_state(provider)["calls"] == 2


def test_long_429_does_not_make_the_driver_wait(provider):
    set_mode(provider, "429_long")
    with chat_api(provider) as api:
        started = time.time()
        body = say(api).json()
        assert body["fallback"] is True and body["error"] == "rate_limited"
        assert time.time() - started < 1.0
        assert provider_state(provider)["calls"] == 1


def test_provider_500_is_retried_then_falls_back(provider):
    set_mode(provider, "500")
    with chat_api(provider) as api:
        body = say(api).json()
        assert body["fallback"] is True and body["error"] == "upstream"
        assert provider_state(provider)["calls"] == 2


def test_wrong_api_key_falls_back_and_is_visible_in_deep_health(provider):
    set_mode(provider, "ok")
    with chat_api(provider, LLM_API_KEY="key-yang-salah") as api:
        body = say(api).json()
        assert body["fallback"] is True and body["error"] == "auth"
        assert provider_state(provider)["calls"] == 1  # key salah tidak di-retry
        deep = api.get("/chat/health", params={"deep": "true"}).json()
        assert deep["reachable"] is False and deep["error"] == "auth"
        assert "key-yang-salah" not in str(deep)


@pytest.mark.parametrize("mode,expected_error", [("html", "bad_response"), ("empty", "empty")])
def test_garbage_from_provider_falls_back(provider, mode, expected_error):
    set_mode(provider, mode)
    with chat_api(provider) as api:
        body = say(api).json()
        assert body["fallback"] is True and body["error"] == expected_error


def test_strict_reasoning_model_is_handled_by_auto_adaptation(provider):
    set_mode(provider, "strict")
    with chat_api(provider, LLM_MAX_TOKENS_PARAM="max_tokens") as api:
        body = say(api).json()
        assert body["fallback"] is False  # sukses walau parameter awal ditolak dua kali
        assert provider_state(provider)["calls"] == 3

        say(api, "lagi")  # pelajarannya diingat: tidak ditolak lagi
        assert provider_state(provider)["calls"] == 4
        final = provider_state(provider)["requests"][-1]["body"]
        assert "max_completion_tokens" in final and "max_tokens" not in final and "temperature" not in final


def test_unreachable_provider_falls_back_quickly():
    dead_url = f"http://127.0.0.1:{free_port()}"  # tidak ada yang mendengarkan
    with chat_api(dead_url) as api:
        started = time.time()
        body = say(api).json()
        assert body["fallback"] is True and body["error"] == "network"
        assert time.time() - started < 3.0


def test_unconfigured_server_still_boots_and_explains(provider):
    settings = load_settings({"LLM_PROVIDER": "groq"})  # lupa isi API key
    app = FastAPI()
    app.include_router(build_router(settings))
    with serve(app) as url:
        with httpx.Client(base_url=url) as api:
            r = say(api)
            assert r.status_code == 503
            assert "API key" in r.json()["detail"]["message"]
            assert api.get("/chat/health").json()["status"] == "not_configured"
