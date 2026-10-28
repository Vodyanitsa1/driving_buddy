"""Konfigurasi modul LLM.

Semua pengaturan dibaca dari environment variable. Kalau ada file `.env`
(di folder kerja atau di root repo), isinya ikut dibaca; environment variable
yang sudah ada selalu menang atas isi file.

Modul ini TIDAK PERNAH melempar error karena salah konfigurasi. Masalahnya
dicatat di `Settings.problem` supaya deteksi kantuk (server.py) tetap jalan
walaupun fitur chat belum siap.
"""
from __future__ import annotations

import logging
import math
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple
from urllib.parse import urlparse

log = logging.getLogger("driving_buddy.llm")

PROVIDERS = ("groq", "gemini", "openai", "custom", "mock")

# Semua provider di bawah memakai format OpenAI: POST {base_url}/chat/completions
# max_tokens: batas panjang jawaban. Model "thinking" (Gemini 3.x, gpt-oss, o-series) ikut menghitung
# token berpikirnya di batas ini, jadi nilainya dibuat lebih besar supaya jawaban tidak kepotong/kosong.
_PRESETS: Dict[str, Dict[str, Any]] = {
    # Llama 3.3 70B sudah dipensiunkan Groq (16 Agu 2026); pengganti yang disarankan Groq: gpt-oss-120b.
    # gpt-oss = model reasoning, jadi jatah token dibuat lebih besar dan reasoning "low" supaya cepat.
    "groq": {
        "base_url": "https://api.groq.com/openai/v1",
        "model": "openai/gpt-oss-120b",
        "max_tokens_param": "max_completion_tokens",
        "max_tokens": 512,
        "reasoning_effort": "low",
    },
    "gemini": {
        "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
        "model": "gemini-3.1-flash-lite",
        "max_tokens_param": "max_tokens",
        "max_tokens": 1024,
        "reasoning_effort": "low",  # Gemini 3.x tidak bisa mematikan thinking; "low" = lebih cepat & hemat
    },
    # Nama model OpenAI sering berganti, jadi wajib diisi lewat LLM_MODEL.
    "openai": {
        "base_url": "https://api.openai.com/v1",
        "model": "",
        "max_tokens_param": "max_completion_tokens",
        "max_tokens": 1024,
        "reasoning_effort": "",
    },
    # Server OpenAI-compatible lain (OpenRouter, Ollama, LM Studio, ...).
    "custom": {
        "base_url": "", "model": "", "max_tokens_param": "max_tokens", "max_tokens": 256, "reasoning_effort": "",
    },
    "mock": {
        "base_url": "", "model": "mock-buddy", "max_tokens_param": "max_tokens", "max_tokens": 256,
        "reasoning_effort": "",
    },
}

# Env var bawaan tiap provider, dipakai kalau LLM_API_KEY kosong.
_ALT_KEY_VARS: Dict[str, Tuple[str, ...]] = {
    "groq": ("GROQ_API_KEY",),
    "gemini": ("GEMINI_API_KEY", "GOOGLE_API_KEY"),
    "openai": ("OPENAI_API_KEY",),
}

# Awalan API key -> provider, dipakai kalau LLM_PROVIDER tidak diisi.
_KEY_PREFIXES = (("gsk_", "groq"), ("AIza", "gemini"), ("sk-", "openai"))

_REPO_ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Settings:
    provider: str = "mock"
    api_key: str = field(default="", repr=False)  # jangan pernah tampil di log/repr
    model: str = "mock-buddy"
    base_url: str = ""
    max_tokens_param: str = "max_tokens"
    max_tokens: int = 256
    temperature: float = 0.7
    reasoning_effort: Optional[str] = None
    timeout_s: float = 8.0
    max_retries: int = 1
    history_turns: int = 6  # jumlah pasangan tanya-jawab terakhir yang dikirim ke LLM
    session_ttl_s: int = 1800
    max_sessions: int = 500
    rate_per_session_per_min: int = 12
    rate_global_per_min: int = 120
    max_reply_chars: int = 280
    problem: Optional[str] = None  # None = siap dipakai

    @property
    def configured(self) -> bool:
        return self.problem is None

    @property
    def base_url_host(self) -> str:
        return urlparse(self.base_url).netloc if self.base_url else ""


# ---------------------------------------------------------------------------
# Membaca environment
# ---------------------------------------------------------------------------
def parse_env_file(path: Path) -> Dict[str, str]:
    """Parser .env sederhana: KEY=VALUE, komentar '#', tanda kutip opsional."""
    values: Dict[str, str] = {}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return values
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        elif " #" in val:
            val = val.split(" #", 1)[0].rstrip()
        if key:
            values[key] = val
    return values


def _collect_env(environ: Optional[Mapping[str, str]], env_file: Optional[str]) -> Dict[str, str]:
    base = dict(os.environ) if environ is None else dict(environ)
    explicit = env_file or base.get("LLM_ENV_FILE")
    if explicit:
        candidates = [Path(explicit)]
    elif environ is None:
        candidates = [Path.cwd() / ".env", _REPO_ROOT / ".env"]
    else:
        candidates = []  # environ disuntik manual (tes) -> jangan baca file apa pun
    merged: Dict[str, str] = {}
    for candidate in candidates:
        if candidate.is_file():
            merged.update(parse_env_file(candidate))
            break
    merged.update(base)  # environment asli menang atas isi file
    return {k: str(v).strip() for k, v in merged.items() if v is not None and str(v).strip() != ""}


def _number(env: Mapping[str, str], name: str, default, lo, hi, cast: Callable, notes: List[str]):
    raw = env.get(name)
    if raw is None:
        return default
    try:
        value = cast(raw)
    except ValueError:
        notes.append(f"{name}='{raw}' bukan angka valid, dipakai default {default}")
        return default
    if isinstance(value, float) and not math.isfinite(value):
        notes.append(f"{name}='{raw}' tidak valid, dipakai default {default}")
        return default
    if not lo <= value <= hi:
        clamped = min(max(value, lo), hi)
        notes.append(f"{name}={value} di luar batas [{lo}, {hi}], dipakai {clamped}")
        return clamped
    return value


def _guess_provider(env: Mapping[str, str], api_key: str) -> Tuple[str, str]:
    for prefix, name in _KEY_PREFIXES:
        if api_key.startswith(prefix):
            return name, f"LLM_PROVIDER kosong, terdeteksi '{name}' dari awalan API key"
    for name, variables in _ALT_KEY_VARS.items():
        if any(env.get(v) for v in variables):
            return name, f"LLM_PROVIDER kosong, terdeteksi '{name}' dari {variables[0]}"
    return "mock", "LLM_PROVIDER dan API key belum diisi, jalan di mode MOCK (balasan palsu)"


def load_settings(environ: Optional[Mapping[str, str]] = None, env_file: Optional[str] = None) -> Settings:
    """Bangun Settings dari environment. `environ` hanya dipakai untuk tes."""
    env = _collect_env(environ, env_file)
    notes: List[str] = []
    problems: List[str] = []

    provider = env.get("LLM_PROVIDER", "").lower()
    api_key = env.get("LLM_API_KEY", "")

    if not provider:
        provider, why = _guess_provider(env, api_key)
        (log.warning if provider == "mock" else log.info)("[LLM] %s", why)

    if provider in _PRESETS:
        preset = _PRESETS[provider]
    else:
        problems.append(f"LLM_PROVIDER='{provider}' tidak dikenal (pilih: {', '.join(PROVIDERS)})")
        preset = _PRESETS["custom"]

    if not api_key:
        for var in _ALT_KEY_VARS.get(provider, ()):
            if env.get(var):
                api_key = env[var]
                break
    if provider in ("groq", "gemini", "openai") and not api_key:
        problems.append(f"API key untuk '{provider}' belum diisi (set LLM_API_KEY di file .env)")
    elif api_key.startswith("YOUR_"):
        problems.append("LLM_API_KEY masih berisi contoh dari .env.example, ganti dengan API key asli")

    base_url = env.get("LLM_BASE_URL", "") or preset["base_url"]
    if provider != "mock":
        parsed = urlparse(base_url)
        if not base_url:
            problems.append("LLM_BASE_URL wajib diisi untuk provider ini")
        elif parsed.scheme not in ("http", "https") or not parsed.netloc:
            problems.append(f"LLM_BASE_URL='{base_url}' tidak valid (harus diawali http:// atau https://)")
    base_url = base_url.rstrip("/")

    model = env.get("LLM_MODEL", "") or preset["model"]
    if not model:
        problems.append(f"LLM_MODEL wajib diisi untuk provider '{provider}'")

    token_param = env.get("LLM_MAX_TOKENS_PARAM", "") or preset["max_tokens_param"]
    if token_param not in ("max_tokens", "max_completion_tokens"):
        notes.append(f"LLM_MAX_TOKENS_PARAM='{token_param}' tidak valid, dipakai {preset['max_tokens_param']}")
        token_param = preset["max_tokens_param"]

    effort: Optional[str] = (env.get("LLM_REASONING_EFFORT", "") or preset["reasoning_effort"]).lower() or None
    if effort and not re.fullmatch(r"[a-z]{3,10}", effort):
        notes.append(f"LLM_REASONING_EFFORT='{effort}' tidak valid, diabaikan")
        effort = None

    settings = Settings(
        provider=provider,
        api_key=api_key,
        model=model,
        base_url=base_url,
        max_tokens_param=token_param,
        max_tokens=_number(env, "LLM_MAX_TOKENS", preset["max_tokens"], 16, 8192, int, notes),
        temperature=_number(env, "LLM_TEMPERATURE", 0.7, 0.0, 2.0, float, notes),
        reasoning_effort=effort,
        timeout_s=_number(env, "LLM_TIMEOUT_S", 8.0, 0.2, 60.0, float, notes),
        max_retries=_number(env, "LLM_MAX_RETRIES", 1, 0, 3, int, notes),
        history_turns=_number(env, "LLM_HISTORY_TURNS", 6, 0, 30, int, notes),
        session_ttl_s=_number(env, "LLM_SESSION_TTL_S", 1800, 30, 86400, int, notes),
        max_sessions=_number(env, "LLM_MAX_SESSIONS", 500, 1, 100000, int, notes),
        rate_per_session_per_min=_number(env, "LLM_RATE_PER_SESSION_PER_MIN", 12, 0, 10000, int, notes),
        rate_global_per_min=_number(env, "LLM_RATE_GLOBAL_PER_MIN", 120, 0, 100000, int, notes),
        max_reply_chars=_number(env, "LLM_MAX_REPLY_CHARS", 280, 40, 2000, int, notes),
        problem="; ".join(problems) if problems else None,
    )

    for note in notes:
        log.warning("[LLM] %s", note)
    return settings
