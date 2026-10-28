"""Client LLM.

Satu implementasi (`OpenAICompatLLM`) untuk semua API berformat OpenAI:
Groq, Gemini, OpenAI, OpenRouter, Ollama, LM Studio, dst. Ganti provider
cukup lewat environment variable, tanpa mengubah kode.

`MockLLM` dipakai untuk pengembangan frontend dan tes (tanpa API key).
"""
from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Set, Tuple

import httpx

from .config import Settings
from .prompts import STATUS_DESC

log = logging.getLogger("driving_buddy.llm")

MAX_RETRY_AFTER_S = 2.0  # provider minta tunggu lebih lama dari ini -> jangan menunggu, langsung fallback
BACKOFF_S = 0.4
MAX_ADAPTATIONS = 3  # berapa kali parameter ditolak provider boleh diperbaiki otomatis per permintaan


class LLMError(Exception):
    """Kegagalan saat memanggil LLM. `kind` dipakai frontend/log, bukan teks error mentah provider."""

    def __init__(self, kind: str, detail: str = "", status: Optional[int] = None,
                 retry_after: Optional[float] = None):
        super().__init__(f"{kind}: {detail}" if detail else kind)
        self.kind = kind  # timeout | network | rate_limited | auth | not_found | bad_request | upstream | bad_response | empty
        self.detail = detail
        self.status = status
        self.retry_after = retry_after


@dataclass
class LLMResult:
    text: str
    model: str
    finish_reason: Optional[str] = None
    usage: Optional[Dict[str, Any]] = None
    latency_ms: int = 0


class BaseLLM:
    provider: str = ""
    model: str = ""

    async def complete(self, messages: List[Dict[str, str]]) -> LLMResult:
        raise NotImplementedError

    async def list_models(self) -> List[str]:
        raise NotImplementedError

    async def aclose(self) -> None:
        return None


# ---------------------------------------------------------------------------
# Provider asli (format OpenAI)
# ---------------------------------------------------------------------------
class OpenAICompatLLM(BaseLLM):
    def __init__(self, settings: Settings, http: Optional[httpx.AsyncClient] = None):
        self.settings = settings
        self.provider = settings.provider
        self.model = settings.model
        self._http = http
        self._owns_http = http is None
        # Hasil "belajar" dari penolakan provider; dipakai ulang di permintaan berikutnya.
        self._token_param = settings.max_tokens_param
        self._dropped: Set[str] = set()

    # -- API publik ---------------------------------------------------------
    async def complete(self, messages: List[Dict[str, str]]) -> LLMResult:
        payload = self._build_payload(messages)
        retries = 0
        adaptations = 0
        while True:
            try:
                return await self._chat_once(payload)
            except LLMError as err:
                if err.kind == "bad_request" and adaptations < MAX_ADAPTATIONS and self._adapt(payload, err.detail):
                    adaptations += 1
                    log.warning("[LLM] %s menolak sebagian parameter, diulang tanpa itu: %s",
                                self.provider, err.detail[:160])
                    continue
                if retries < self.settings.max_retries and self._retryable(err):
                    retries += 1
                    await asyncio.sleep(self._delay(err))
                    continue
                raise

    async def list_models(self) -> List[str]:
        url = f"{self.settings.base_url}/models"
        resp = await self._send("GET", url, timeout=min(self.settings.timeout_s, 5.0))
        if resp.status_code != 200:
            raise self._http_error(resp)
        try:
            data = resp.json()
        except ValueError:
            raise LLMError("bad_response", "daftar model bukan JSON", status=resp.status_code) from None
        items = data.get("data") if isinstance(data, dict) else data
        ids = [str(m.get("id") or m.get("name") or "") for m in (items or []) if isinstance(m, dict)]
        # Gemini mengawali id dengan "models/"
        return [i[len("models/"):] if i.startswith("models/") else i for i in ids if i]

    async def aclose(self) -> None:
        if self._http is not None and self._owns_http:
            await self._http.aclose()
            self._http = None

    # -- internal -----------------------------------------------------------
    def _client(self) -> httpx.AsyncClient:
        if self._http is None:
            self._http = httpx.AsyncClient(
                timeout=httpx.Timeout(self.settings.timeout_s, connect=min(5.0, self.settings.timeout_s)),
                limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
            )
        return self._http

    def _headers(self) -> Dict[str, str]:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "driving-buddy-llm/1.0",
        }
        if self.settings.api_key:
            headers["Authorization"] = f"Bearer {self.settings.api_key}"
        return headers

    def _build_payload(self, messages: List[Dict[str, str]]) -> Dict[str, Any]:
        s = self.settings
        payload: Dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "temperature": s.temperature,
            self._token_param: s.max_tokens,
        }
        if s.reasoning_effort:
            payload["reasoning_effort"] = s.reasoning_effort
        for name in self._dropped:
            payload.pop(name, None)
        return payload

    async def _send(self, method: str, url: str, timeout: float,
                    json_body: Optional[Dict[str, Any]] = None) -> httpx.Response:
        try:
            return await asyncio.wait_for(
                self._client().request(method, url, json=json_body, headers=self._headers()),
                timeout=timeout,
            )
        except (asyncio.TimeoutError, httpx.TimeoutException):
            raise LLMError("timeout", f"tidak ada balasan dalam {timeout:g} detik") from None
        except httpx.HTTPError as exc:
            raise LLMError("network", f"{type(exc).__name__}: {exc}"[:200]) from None

    async def _chat_once(self, payload: Dict[str, Any]) -> LLMResult:
        started = time.perf_counter()
        url = f"{self.settings.base_url}/chat/completions"
        resp = await self._send("POST", url, timeout=self.settings.timeout_s, json_body=payload)
        latency_ms = int((time.perf_counter() - started) * 1000)
        if resp.status_code != 200:
            raise self._http_error(resp)
        try:
            data = resp.json()
        except ValueError:
            raise LLMError("bad_response", "balasan bukan JSON", status=resp.status_code) from None
        if not isinstance(data, dict):
            raise LLMError("bad_response", "format balasan tidak dikenal", status=resp.status_code)

        text, finish = _extract_text(data)
        usage = data.get("usage") if isinstance(data.get("usage"), dict) else None
        log.info("[LLM] %s/%s ok %dms finish=%s tokens=%s/%s", self.provider, self.model, latency_ms, finish,
                 (usage or {}).get("prompt_tokens", "?"), (usage or {}).get("completion_tokens", "?"))
        if not text.strip():
            raise LLMError("empty", f"balasan kosong (finish_reason={finish})", status=200)
        return LLMResult(text=text, model=str(data.get("model") or self.model), finish_reason=finish,
                         usage=usage, latency_ms=latency_ms)

    def _http_error(self, resp: httpx.Response) -> LLMError:
        detail = _error_text(resp)
        if self.settings.api_key:  # sebagian provider mengulang key di pesan error
            detail = detail.replace(self.settings.api_key, "***")
        return LLMError(_classify(resp.status_code), detail, status=resp.status_code,
                        retry_after=_retry_after(resp))

    @staticmethod
    def _retryable(err: LLMError) -> bool:
        # Timeout sengaja tidak diulang: pengemudi tidak boleh menunggu 2x batas waktu.
        if err.kind in ("network", "upstream", "bad_response"):
            return True
        if err.kind == "rate_limited":
            return err.retry_after is not None and err.retry_after <= MAX_RETRY_AFTER_S
        return False

    @staticmethod
    def _delay(err: LLMError) -> float:
        if err.retry_after is not None:
            return min(max(err.retry_after, 0.0), MAX_RETRY_AFTER_S)
        return BACKOFF_S

    def _adapt(self, payload: Dict[str, Any], detail: str) -> bool:
        """Provider menolak parameter tertentu (400)? Perbaiki payload-nya dan ingat untuk permintaan berikutnya.

        Contoh nyata: model reasoning OpenAI menolak `max_tokens` (harus `max_completion_tokens`) dan
        `temperature` selain default; sebagian model tidak mengenal `reasoning_effort`."""
        low = detail.lower()
        for name, other in (("max_completion_tokens", "max_tokens"), ("max_tokens", "max_completion_tokens")):
            if name in payload and name in low:
                payload[other] = payload.pop(name)
                self._token_param = other
                return True
        for name in ("reasoning_effort", "temperature"):
            if name in payload and name in low:
                payload.pop(name)
                self._dropped.add(name)
                return True
        return False


def _classify(status: int) -> str:
    if status in (401, 403):
        return "auth"
    if status == 404:
        return "not_found"
    if status == 408:
        return "timeout"
    if status == 429:
        return "rate_limited"
    if status >= 500:
        return "upstream"
    return "bad_request"


def _error_text(resp: httpx.Response) -> str:
    """Ambil pesan error dari body (bentuk OpenAI/Groq: {error:{message}}, Gemini kadang berupa list)."""
    try:
        body: Any = resp.json()
    except ValueError:
        return resp.text[:300]
    if isinstance(body, list) and body:
        body = body[0]
    if isinstance(body, dict):
        err = body.get("error", body)
        if isinstance(err, dict):
            return str(err.get("message") or err)[:300]
        return str(err)[:300]
    return str(body)[:300]


def _retry_after(resp: httpx.Response) -> Optional[float]:
    for header, scale in (("retry-after-ms", 0.001), ("retry-after", 1.0)):
        raw = resp.headers.get(header)
        if raw:
            try:
                return max(0.0, float(raw) * scale)
            except ValueError:
                continue
    return None


def _extract_text(data: Dict[str, Any]) -> Tuple[str, Optional[str]]:
    choices = data.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise LLMError("bad_response", "balasan tidak punya 'choices'", status=200)
    choice = choices[0]
    message = choice.get("message") or {}
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, list):  # sebagian provider mengirim potongan-potongan teks
        content = "".join(str(p.get("text", "")) for p in content if isinstance(p, dict))
    return (content if isinstance(content, str) else ""), choice.get("finish_reason")


# ---------------------------------------------------------------------------
# Mock (tanpa API key)
# ---------------------------------------------------------------------------
class MockLLM(BaseLLM):
    """Balasan palsu tapi masuk akal. Untuk pengembangan frontend/tes; tidak memanggil internet."""

    provider = "mock"

    def __init__(self, settings: Optional[Settings] = None):
        self.model = settings.model if settings else "mock-buddy"

    async def complete(self, messages: List[Dict[str, str]]) -> LLMResult:
        system = messages[0]["content"] if messages and messages[0].get("role") == "system" else ""
        last_user = next((m["content"] for m in reversed(messages) if m.get("role") == "user"), "").lower()
        if STATUS_DESC["sleep"] in system:
            text = "Kamu kelihatan sangat ngantuk. Menepi dulu di tempat yang aman dan istirahat ya."
        elif any(w in last_user for w in ("ngantuk", "capek", "lelah", "kantuk")) or STATUS_DESC["drowsy"] in system:
            text = "Kedengarannya kamu mulai capek. Cari tempat aman buat berhenti sebentar ya, aku tungguin."
        elif "?" in last_user:
            text = "Pertanyaan menarik! Menurut kamu sendiri gimana?"
        else:
            text = "Oke, aku dengerin. Cerita dong, gimana perjalanan kamu sejauh ini?"
        return LLMResult(text=text, model=self.model, finish_reason="stop", usage=None, latency_ms=0)

    async def list_models(self) -> List[str]:
        return [self.model]


def make_llm(settings: Settings, http: Optional[httpx.AsyncClient] = None) -> BaseLLM:
    if settings.provider == "mock":
        return MockLLM(settings)
    return OpenAICompatLLM(settings, http)
