"""Integrasi LLM untuk Driving Buddy (kartu Trello: [BE] Integration API LLM).

Pemasangan di server.py (2 baris):

    from llm_chat import build_router
    app.include_router(build_router())

Konfigurasi lewat environment variable / file .env, lihat README_LLM.md.
"""
import logging
import os

from .config import Settings, load_settings
from .router import build_router

__all__ = ["Settings", "build_router", "load_settings"]


def _setup_logging() -> None:
    """Supaya log [LLM] terlihat di terminal walau aplikasi belum mengatur logging."""
    logger = logging.getLogger("driving_buddy.llm")
    if logger.handlers or logging.getLogger().handlers:
        return
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(os.environ.get("LLM_LOG_LEVEL", "INFO").upper())
    logger.propagate = False


_setup_logging()
