"""Tes client LLM pakai httpx.MockTransport: tanpa internet, tanpa API key asli."""
import asyncio
import logging

import httpx
import pytest

from conftest import run
from llm_chat import client as client_module
from llm_chat.client import LLMError, MockLLM, OpenAICompatLLM, make_llm
from llm_chat.config import load_settings
from llm_chat.prompts import build_messages
from llm_chat.schemas import DriverState

MESSAGES = [{"role": "system", "content": "sys"}, {"role": "user", "content": "halo"}]


@pytest.fixture(autouse=True)
def no_backoff(monkeypatch):
    monkeypatch.setattr(client_module, "BACKOFF_S", 0.0)


def ok(text="Halo!", **extra):
    body = {
        "model": "model-balasan",
        "choices": [{"message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 3},
    }
    body.update(extra)
    return httpx.Response(200, json=body)


def error(status, message, headers=None):
    return httpx.Response(status, json={"error": {"message": message}}, headers=headers or {})


def make(handler, **env):
    base = {"LLM_PROVIDER": "groq", "LLM_API_KEY": "gsk_test_key", "LLM_TIMEOUT_S": "1"}
    settings = load_settings({**base, **env})
    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return OpenAICompatLLM(settings, http)


def complete(llm):
    return run(llm.complete(MESSAGES))


class Calls:
    """Handler yang mencatat request dan membalas sesuai urutan `responses`."""

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
        import json
        return json.loads(self.requests[i].content)


# ------------------------------------------------------------------ sukses
def test_success_builds_a_correct_request():
    calls = Calls(ok("Halo juga!"))
    result = complete(make(calls))
    assert result.text == "Halo juga!"
    assert result.model == "model-balasan"
    assert result.finish_reason == "stop"
    assert result.usage["completion_tokens"] == 3

    req = calls.requests[0]
    assert str(req.url) == "https://api.groq.com/openai/v1/chat/completions"
    assert req.headers["authorization"] == "Bearer gsk_test_key"
    body = calls.body()
    assert body["model"] == "openai/gpt-oss-120b"
    assert body["messages"] == MESSAGES
    assert body["max_completion_tokens"] == 512 and "max_tokens" not in body
    assert body["temperature"] == 0.7
    assert body["reasoning_effort"] == "low"


def test_reasoning_effort_is_sent_only_when_configured():
    calls = Calls(ok())
    complete(make(calls, LLM_PROVIDER="custom", LLM_BASE_URL="http://localhost:11434/v1", LLM_MODEL="m"))
    assert "reasoning_effort" not in calls.body()
    calls = Calls(ok())
    complete(make(calls, LLM_PROVIDER="custom", LLM_BASE_URL="http://localhost:11434/v1", LLM_MODEL="m",
                  LLM_REASONING_EFFORT="medium"))
    assert calls.body()["reasoning_effort"] == "medium"


def test_no_authorization_header_without_key():
    calls = Calls(ok())
    complete(make(calls, LLM_PROVIDER="custom", LLM_API_KEY="", LLM_BASE_URL="http://localhost:11434/v1", LLM_MODEL="m"))
    assert "authorization" not in calls.requests[0].headers
    assert str(calls.requests[0].url) == "http://localhost:11434/v1/chat/completions"


def test_content_given_as_parts_is_joined():
    body = {"choices": [{"message": {"content": [{"type": "text", "text": "Ha"}, {"type": "text", "text": "lo"}]}}]}
    assert complete(make(Calls(httpx.Response(200, json=body)))).text == "Halo"


# ------------------------------------------------------------------ retry
def test_retries_5xx_once_then_succeeds():
    calls = Calls(error(503, "overloaded"), ok())
    assert complete(make(calls)).text == "Halo!"
    assert len(calls.requests) == 2


def test_gives_up_after_max_retries():
    calls = Calls(error(500, "boom"))
    with pytest.raises(LLMError) as exc:
        complete(make(calls))
    assert exc.value.kind == "upstream" and exc.value.status == 500
    assert len(calls.requests) == 2  # 1 percobaan + 1 retry


def test_max_retries_zero_means_single_attempt():
    calls = Calls(error(500, "boom"))
    with pytest.raises(LLMError):
        complete(make(calls, LLM_MAX_RETRIES="0"))
    assert len(calls.requests) == 1


def test_429_with_short_retry_after_is_retried():
    calls = Calls(error(429, "rate limit", {"retry-after": "0"}), ok())
    assert complete(make(calls)).text == "Halo!"
    assert len(calls.requests) == 2


def test_429_with_long_or_missing_retry_after_fails_fast():
    for headers in ({"retry-after": "30"}, {}):
        calls = Calls(error(429, "rate limit", headers))
        with pytest.raises(LLMError) as exc:
            complete(make(calls))
        assert exc.value.kind == "rate_limited"
        assert len(calls.requests) == 1  # sopir tidak boleh menunggu lama


def test_auth_error_is_not_retried():
    calls = Calls(error(401, "Invalid API Key"))
    with pytest.raises(LLMError) as exc:
        complete(make(calls))
    assert exc.value.kind == "auth" and len(calls.requests) == 1


def test_unknown_model_is_not_found():
    with pytest.raises(LLMError) as exc:
        complete(make(Calls(error(404, "model not found"))))
    assert exc.value.kind == "not_found"


def test_timeout_is_reported_without_retry():
    calls = Calls(httpx.ReadTimeout("lambat"))
    with pytest.raises(LLMError) as exc:
        complete(make(calls))
    assert exc.value.kind == "timeout" and len(calls.requests) == 1


def test_connection_error_is_retried_then_reported_as_network():
    calls = Calls(httpx.ConnectError("tidak bisa konek"))
    with pytest.raises(LLMError) as exc:
        complete(make(calls))
    assert exc.value.kind == "network" and len(calls.requests) == 2


def test_hard_deadline_even_if_server_trickles(monkeypatch):
    async def slow(request):
        await asyncio.sleep(2)
        return ok()

    llm = make(slow, LLM_TIMEOUT_S="0.2")
    with pytest.raises(LLMError) as exc:
        complete(llm)
    assert exc.value.kind == "timeout"


# ------------------------------------------------------------ bad response
def test_empty_content_is_an_error():
    body = {"choices": [{"message": {"content": ""}, "finish_reason": "length"}]}
    with pytest.raises(LLMError) as exc:
        complete(make(Calls(httpx.Response(200, json=body))))
    assert exc.value.kind == "empty" and "length" in exc.value.detail


def test_malformed_responses_are_bad_response():
    for response in (
        httpx.Response(200, text="<html>bad gateway</html>"),
        httpx.Response(200, json={"choices": []}),
        httpx.Response(200, json=["bukan", "objek"]),
    ):
        calls = Calls(response)
        with pytest.raises(LLMError) as exc:
            complete(make(calls))
        assert exc.value.kind == "bad_response"
        assert len(calls.requests) == 2  # dianggap gangguan sesaat -> dicoba sekali lagi


def test_error_message_parsed_from_openai_and_gemini_shapes():
    gemini_style = httpx.Response(400, json=[{"error": {"code": 400, "message": "gemini bilang tidak"}}])
    with pytest.raises(LLMError) as exc:
        complete(make(Calls(gemini_style)))
    assert exc.value.kind == "bad_request" and exc.value.detail == "gemini bilang tidak"


# ------------------------------------------------------ adaptasi parameter
def test_swaps_token_parameter_name_when_provider_rejects_it():
    def handler(request):
        import json
        if "max_tokens" in json.loads(request.content):
            return error(400, "Unsupported parameter: 'max_tokens' is not supported with this model. "
                              "Use 'max_completion_tokens' instead.")
        return ok()

    llm = make(handler, LLM_MAX_TOKENS_PARAM="max_tokens")
    assert complete(llm).text == "Halo!"
    # permintaan berikutnya langsung memakai nama yang benar (tidak ditolak lagi)
    seen = []
    llm._http = httpx.AsyncClient(transport=httpx.MockTransport(lambda r: (seen.append(r), ok())[1]))
    complete(llm)
    assert len(seen) == 1
    import json
    assert "max_completion_tokens" in json.loads(seen[0].content)


def test_drops_temperature_when_model_only_supports_default():
    def handler(request):
        import json
        if "temperature" in json.loads(request.content):
            return error(400, "Unsupported value: 'temperature' does not support 0.7 with this model. "
                              "Only the default (1) value is supported.")
        return ok()

    llm = make(handler)
    assert complete(llm).text == "Halo!"
    assert "temperature" in llm._dropped


def test_drops_reasoning_effort_when_model_does_not_know_it():
    def handler(request):
        import json
        if "reasoning_effort" in json.loads(request.content):
            return error(400, "reasoning_effort is not supported with this model")
        return ok()

    assert complete(make(handler, LLM_REASONING_EFFORT="low")).text == "Halo!"


def test_adaptation_loop_is_bounded():
    flip = {"n": 0}

    def handler(request):
        import json
        body = json.loads(request.content)
        flip["n"] += 1
        name = "max_tokens" if "max_tokens" in body else "max_completion_tokens"
        return error(400, f"parameter {name} invalid")

    with pytest.raises(LLMError) as exc:
        complete(make(handler))
    assert exc.value.kind == "bad_request"
    assert flip["n"] == 4  # 1 percobaan awal + 3 perbaikan, lalu berhenti


def test_unrelated_400_is_not_adapted():
    calls = Calls(error(400, "messages must not be empty"))
    with pytest.raises(LLMError):
        complete(make(calls))
    assert len(calls.requests) == 1


# ------------------------------------------------------------- list_models
def test_list_models_strips_gemini_prefix_only():
    body = {"data": [{"id": "models/gemini-3.1-flash-lite"}, {"id": "openai/gpt-oss-20b"}]}
    llm = make(Calls(httpx.Response(200, json=body)))
    assert run(llm.list_models()) == ["gemini-3.1-flash-lite", "openai/gpt-oss-20b"]


def test_list_models_error_is_llm_error():
    with pytest.raises(LLMError) as exc:
        run(make(Calls(error(401, "nope"))).list_models())
    assert exc.value.kind == "auth"


# ------------------------------------------------------------------ rahasia
def test_api_key_is_never_logged():
    records = []

    class Collect(logging.Handler):
        def emit(self, record):
            records.append(record.getMessage())

    logger = logging.getLogger("driving_buddy.llm")
    handler = Collect()
    old_level = logger.level
    logger.addHandler(handler)
    logger.setLevel(logging.DEBUG)
    try:
        complete(make(Calls(ok())))
        with pytest.raises(LLMError):
            complete(make(Calls(error(401, "Invalid API Key"))))
    finally:
        logger.removeHandler(handler)
        logger.setLevel(old_level)
    assert records, "harusnya ada log"
    assert not any("gsk_test_key" in r for r in records)


def test_api_key_echoed_by_provider_is_redacted():
    llm = make(Calls(error(401, "Incorrect API key provided: gsk_test_key")))
    with pytest.raises(LLMError) as exc:
        complete(llm)
    assert "gsk_test_key" not in exc.value.detail and "***" in exc.value.detail


# ------------------------------------------------------------------ mock
def test_make_llm_picks_mock_provider():
    llm = make_llm(load_settings({}))
    assert isinstance(llm, MockLLM)


def test_mock_reacts_to_sensor_state_and_message():
    llm = MockLLM()
    sleepy = build_messages([], "halo", DriverState(status="sleep"))
    assert "menepi" in run(llm.complete(sleepy)).text.lower()
    tired = build_messages([], "aku capek", None)
    assert "capek" in run(llm.complete(tired)).text
    chat = build_messages([], "apa kabar?", None)
    assert run(llm.complete(chat)).text
