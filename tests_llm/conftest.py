"""Supaya `import llm_chat` jalan walau pytest dipanggil dari folder mana pun."""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))


def run(coro):
    """Jalankan coroutine di tes sinkron (tanpa perlu plugin pytest-asyncio)."""
    return asyncio.run(coro)
