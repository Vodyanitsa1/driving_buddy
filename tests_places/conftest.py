"""Supaya `import nearby_places` jalan walau pytest dipanggil dari folder mana pun."""
import asyncio
import logging
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))


def run(coro):
    """Jalankan coroutine di tes sinkron (tanpa perlu plugin pytest-asyncio)."""
    return asyncio.run(coro)


@pytest.fixture(autouse=True)
def _let_pytest_see_module_logs():
    """Modul memasang handler sendiri dan mematikan propagate; di tes, biarkan caplog ikut menangkap log-nya."""
    logger = logging.getLogger("driving_buddy.places")
    old = logger.propagate
    logger.propagate = True
    yield
    logger.propagate = old
