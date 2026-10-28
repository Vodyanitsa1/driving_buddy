"""Server palsu yang meniru API OpenAI-compatible (Groq/Gemini/OpenAI).

Dipakai tes end-to-end supaya bisa menguji jaringan sungguhan (timeout, 429, key salah, dll.)
tanpa internet dan tanpa API key. Bisa juga dijalankan manual:

    python tests_llm/fake_openai.py 9100
    # lalu di .env:  LLM_PROVIDER=custom  LLM_BASE_URL=http://127.0.0.1:9100/v1
    #                LLM_MODEL=fake-model  LLM_API_KEY=test-key

Mode perilaku diatur lewat  POST /_mode  {"mode": "..."}:
  ok           balasan normal (ada markdown + emoji untuk menguji pembersih)
  slow         menunggu 1.5 detik sebelum membalas
  429_then_ok  permintaan pertama 429 (retry-after: 0), sesudahnya normal
  429_long     selalu 429 dengan retry-after: 30
  500          selalu error 500
  401          selalu "API key salah"
  html         200 tapi isinya HTML (bukan JSON)
  empty        200 tapi content kosong
  strict       meniru model reasoning OpenAI: menolak max_tokens dan temperature != 1
"""
import asyncio
import sys
from typing import Any, Dict

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse

API_KEY = "test-key"
REPLY = "**Halo** \U0001F44B dari fake provider! Kamu lagi di mana sekarang?"


def completion(text: str) -> Dict[str, Any]:
    return {
        "id": "chatcmpl-fake",
        "object": "chat.completion",
        "model": "fake-model",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 42, "completion_tokens": 12, "total_tokens": 54},
    }


def err(status: int, message: str, headers: Dict[str, str] = None) -> JSONResponse:
    return JSONResponse({"error": {"message": message, "type": "fake_error"}}, status_code=status, headers=headers)


def create_fake_provider() -> FastAPI:
    app = FastAPI()
    state: Dict[str, Any] = {"mode": "ok", "calls": 0, "requests": []}

    @app.post("/_mode")
    async def set_mode(body: Dict[str, Any]):
        state.update(mode=body.get("mode", "ok"), calls=0, requests=[])
        return {"ok": True}

    @app.get("/_state")
    async def get_state():
        return state

    @app.get("/v1/models")
    async def models(request: Request):
        if request.headers.get("authorization") != f"Bearer {API_KEY}":
            return err(401, "Invalid API Key")
        return {"object": "list", "data": [{"id": "fake-model"}, {"id": "other-model"}]}

    @app.post("/v1/chat/completions")
    async def chat(request: Request):
        body = await request.json()
        state["calls"] += 1
        state["requests"].append({"authorization": request.headers.get("authorization"), "body": body})
        mode, n = state["mode"], state["calls"]

        if request.headers.get("authorization") != f"Bearer {API_KEY}" or mode == "401":
            return err(401, "Invalid API Key")
        if mode == "slow":
            await asyncio.sleep(1.5)
        elif mode == "429_then_ok" and n == 1:
            return err(429, "Rate limit reached", {"retry-after": "0"})
        elif mode == "429_long":
            return err(429, "Rate limit reached", {"retry-after": "30"})
        elif mode == "500":
            return err(500, "internal boom")
        elif mode == "html":
            return PlainTextResponse("<html>502 bad gateway</html>", media_type="text/html")
        elif mode == "empty":
            return completion("")
        elif mode == "strict":
            if "max_tokens" in body:
                return err(400, "Unsupported parameter: 'max_tokens' is not supported with this model. "
                                "Use 'max_completion_tokens' instead.")
            if body.get("temperature", 1) != 1:
                return err(400, "Unsupported value: 'temperature' does not support 0.7 with this model. "
                                "Only the default (1) value is supported.")
        return completion(REPLY)

    return app


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(create_fake_provider(), host="127.0.0.1", port=int(sys.argv[1]) if len(sys.argv) > 1 else 9100)
