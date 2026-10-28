"""Bentuk request/response untuk endpoint chat (dipakai juga oleh dokumentasi /docs)."""
from __future__ import annotations

import re
from typing import Optional

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, field_validator

SESSION_ID_PATTERN = r"^[A-Za-z0-9_.:\-]+$"
MAX_MESSAGE_CHARS = 500

# Nilai "status" pengemudi setelah dinormalkan (huruf kecil, spasi/strip/camelCase -> _).
# Sumbernya DrowsinessDetector di aplikasi (enum DriverStatus) atau JSON lama dari WebSocket /ws.
KNOWN_STATUS = ("awake", "yawn", "drowsy", "sleep", "no_face")
_CAMEL_BOUNDARY = re.compile(r"(?<=[a-z])(?=[A-Z])")  # "noFace" -> "no_Face"


class DriverState(BaseModel):
    """Kondisi pengemudi terkini dari detektor kantuk di aplikasi (DetectionResult).
    Flutter cukup mengirim `status`, `yawnCount`, `blinkCount` (bentuknya sama dengan JSON lama /ws).
    Semua field opsional; nama camelCase maupun snake_case diterima."""

    model_config = ConfigDict(populate_by_name=True, extra="ignore")

    status: Optional[str] = Field(
        default=None,
        description='Status detektor: "Awake", "Yawn", "Drowsy", "Sleep", atau "No Face" (nama enum Dart seperti "noFace" juga boleh).',
    )
    yawn_count: Optional[int] = Field(
        default=None, ge=0, le=999,
        validation_alias=AliasChoices("yawn_count", "yawnCount"),
        description="Jumlah menguap dalam 5 menit terakhir.",
    )
    blink_count: Optional[int] = Field(
        default=None, ge=0, le=999,
        validation_alias=AliasChoices("blink_count", "blinkCount"),
        description="Jumlah kedipan dalam 60 detik terakhir.",
    )
    trip_minutes: Optional[int] = Field(
        default=None, ge=0, le=1440,
        validation_alias=AliasChoices("trip_minutes", "tripMinutes"),
        description="Sudah berapa menit menyetir (dari timer aplikasi).",
    )

    @field_validator("status", mode="before")
    @classmethod
    def _normalize_status(cls, value):
        # Status tak dikenal diabaikan (bukan error) supaya chat tetap jalan.
        if value is None:
            return None
        key = _CAMEL_BOUNDARY.sub("_", str(value).strip())
        key = key.lower().replace(" ", "_").replace("-", "_")
        return key if key in KNOWN_STATUS else None


class ChatRequest(BaseModel):
    model_config = ConfigDict(
        str_strip_whitespace=True,
        extra="ignore",
        json_schema_extra={
            "examples": [
                {
                    "session_id": "user-123",
                    "message": "Aku mulai ngantuk nih",
                    "driver_state": {"status": "Drowsy", "yawnCount": 3, "blinkCount": 28},
                }
            ]
        },
    )

    session_id: str = Field(
        ..., min_length=1, max_length=64, pattern=SESSION_ID_PATTERN,
        description="ID percakapan (misal uid Firebase atau UUID per perjalanan).",
    )
    message: str = Field(..., min_length=1, max_length=MAX_MESSAGE_CHARS, description="Ucapan pengemudi.")
    driver_state: Optional[DriverState] = None
    reset: bool = Field(default=False, description="true = lupakan riwayat percakapan sebelum membalas.")


class ChatResponse(BaseModel):
    reply: str = Field(..., description="Balasan singkat, teks polos, siap dibacakan (TTS).")
    session_id: str
    provider: str
    model: str
    latency_ms: int
    fallback: bool = Field(
        default=False,
        description="true = LLM gagal/timeout, `reply` adalah balasan darurat bawaan (bukan dari LLM).",
    )
    error: Optional[str] = Field(
        default=None,
        description="Jenis kegagalan kalau fallback=true: timeout, network, rate_limited, auth, upstream, ...",
    )
