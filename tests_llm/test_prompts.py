from llm_chat.prompts import (
    FALLBACK_REPLIES,
    SYSTEM_PROMPT,
    build_driver_context,
    build_messages,
    clean_reply,
    pick_fallback,
    severity,
)
from llm_chat.schemas import DriverState


# ---------------------------------------------------------------- clean_reply
def test_clean_reply_strips_markdown_emoji_and_urls():
    raw = "**Halo!** \U0001F600 Ini [tautan](http://x.com) dan https://a.b/c `kode`\n- poin satu\n- poin dua"
    out = clean_reply(raw)
    for bad in ("*", "`", "http", "\U0001F600", "](", "- "):
        assert bad not in out
    assert out.startswith("Halo!")
    assert "tautan" in out
    assert "poin satu." in out and "poin dua." in out


def test_clean_reply_removes_think_blocks():
    assert clean_reply("<think>mikir dulu...</think>Halo kamu.") == "Halo kamu."
    assert clean_reply("<think>kepotong tanpa penutup") == ""
    assert clean_reply("sisa pikiran</think>Halo lagi.") == "Halo lagi."


def test_clean_reply_joins_lines_into_speakable_sentences():
    assert clean_reply("Baris satu\nBaris dua.") == "Baris satu. Baris dua."


def test_clean_reply_truncates_at_sentence_boundary():
    text = "Kalimat pertama itu. Kalimat kedua juga. Kalimat ketiga yang panjang sekali."
    out = clean_reply(text, max_chars=45)
    assert out == "Kalimat pertama itu. Kalimat kedua juga."
    assert len(out) <= 45


def test_clean_reply_truncates_without_sentence_end():
    out = clean_reply("kata " * 50, max_chars=40)
    assert len(out) <= 41 and out.endswith(".")


def test_clean_reply_empty_cases():
    assert clean_reply("") == ""
    assert clean_reply("\U0001F600\U0001F600") == ""
    assert clean_reply("<think>x</think>") == ""


def test_clean_reply_keeps_snake_case_and_numbers():
    assert clean_reply("Pakai nama_variabel_ini selama 15 menit.") == "Pakai nama_variabel_ini selama 15 menit."
    assert clean_reply("1. Minum air\n2. Buka jendela") == "Minum air. Buka jendela."


# ------------------------------------------------------------- driver state
def test_driver_state_accepts_camel_and_snake_case():
    a = DriverState.model_validate({"status": "Drowsy", "yawnCount": 3, "blinkCount": 28, "tripMinutes": 90})
    b = DriverState.model_validate({"status": "drowsy", "yawn_count": 3, "blink_count": 28, "trip_minutes": 90})
    assert a == b
    assert (a.status, a.yawn_count, a.blink_count, a.trip_minutes) == ("drowsy", 3, 28, 90)


def test_driver_state_status_normalised_and_unknown_ignored():
    assert DriverState.model_validate({"status": "No Face"}).status == "no_face"
    assert DriverState.model_validate({"status": "SLEEP"}).status == "sleep"
    assert DriverState.model_validate({"status": "sesuatu-yang-baru"}).status is None


def test_driver_state_accepts_dart_enum_names():
    # DriverStatus di Flutter: awake, sleep, yawn, drowsy, noFace
    assert DriverState.model_validate({"status": "noFace"}).status == "no_face"
    assert DriverState.model_validate({"status": "drowsy"}).status == "drowsy"
    assert DriverState.model_validate({"status": "NO_FACE"}).status == "no_face"


def test_driver_state_ignores_extra_websocket_fields():
    state = DriverState.model_validate({"status": "Awake", "ear": 0.3, "eyePoints": [[1, 2]], "subStatus": "x"})
    assert state.status == "awake"


# ------------------------------------------------------------ build_messages
def test_build_messages_merges_sensor_context_into_one_system_message():
    state = DriverState(status="drowsy", yawn_count=3, blink_count=30, trip_minutes=90)
    history = [{"role": "user", "content": "a"}, {"role": "assistant", "content": "b"}]
    msgs = build_messages(history, "c", state)
    assert [m["role"] for m in msgs] == ["system", "user", "assistant", "user"]
    assert msgs[0]["content"].startswith(SYSTEM_PROMPT)
    assert "menguap 3x" in msgs[0]["content"]
    assert "90 menit" in msgs[0]["content"]
    assert msgs[-1] == {"role": "user", "content": "c"}


def test_build_messages_without_sensor_data_uses_plain_prompt():
    for state in (None, DriverState(), DriverState(status="no_face")):
        assert build_messages([], "hai", state)[0]["content"] == SYSTEM_PROMPT
    assert build_driver_context(None) is None


# --------------------------------------------------------- severity/fallback
def test_severity_levels():
    assert severity(DriverState(status="sleep")) == 2
    assert severity(DriverState(status="drowsy")) == 1
    assert severity(DriverState(status="yawn")) == 1
    assert severity(DriverState(status="awake")) == 0
    assert severity(None, "aku capek banget nih") == 1
    assert severity(None, "halo") == 0


def test_fallback_keeps_the_safety_message():
    assert pick_fallback(DriverState(status="sleep"), "halo") == FALLBACK_REPLIES[2]
    assert "menepi" in pick_fallback(DriverState(status="sleep"))
    assert "berhenti" in pick_fallback(None, "aku ngantuk")
    assert pick_fallback(None, "halo") == FALLBACK_REPLIES[0]
