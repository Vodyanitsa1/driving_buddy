from llm_chat.config import load_settings, parse_env_file


def test_empty_env_falls_back_to_mock():
    s = load_settings({})
    assert s.provider == "mock"
    assert s.configured


def test_groq_defaults():
    s = load_settings({"LLM_PROVIDER": "groq", "LLM_API_KEY": "gsk_abc"})
    assert s.configured
    assert s.base_url == "https://api.groq.com/openai/v1"
    assert s.model == "openai/gpt-oss-120b"
    assert s.max_tokens_param == "max_completion_tokens"
    assert s.base_url_host == "api.groq.com"
    # gpt-oss = model reasoning: jatah token lebih besar + reasoning rendah
    assert s.max_tokens == 512 and s.reasoning_effort == "low"


def test_gemini_defaults():
    s = load_settings({"LLM_PROVIDER": "gemini", "LLM_API_KEY": "AIzaXYZ"})
    assert s.configured
    assert s.base_url == "https://generativelanguage.googleapis.com/v1beta/openai"
    assert s.model == "gemini-3.1-flash-lite"
    # model thinking: jatah token lebih besar + reasoning rendah supaya cepat dan jawaban tidak kosong
    assert s.max_tokens == 1024 and s.reasoning_effort == "low"
    override = load_settings({"LLM_PROVIDER": "gemini", "LLM_API_KEY": "AIzaXYZ",
                              "LLM_REASONING_EFFORT": "medium", "LLM_MAX_TOKENS": "2048"})
    assert override.reasoning_effort == "medium" and override.max_tokens == 2048


def test_provider_guessed_from_key_prefix():
    assert load_settings({"LLM_API_KEY": "gsk_abc"}).provider == "groq"
    assert load_settings({"LLM_API_KEY": "AIzaabc"}).provider == "gemini"
    s = load_settings({"LLM_API_KEY": "sk-abc"})
    assert s.provider == "openai"
    assert not s.configured  # openai wajib LLM_MODEL


def test_provider_guessed_from_provider_specific_env_var():
    s = load_settings({"GEMINI_API_KEY": "whatever"})
    assert s.provider == "gemini" and s.configured and s.api_key == "whatever"


def test_provider_specific_key_used_when_llm_api_key_empty():
    s = load_settings({"LLM_PROVIDER": "groq", "GROQ_API_KEY": "gsk_from_alt"})
    assert s.configured and s.api_key == "gsk_from_alt"


def test_missing_key_is_a_problem_not_an_exception():
    s = load_settings({"LLM_PROVIDER": "groq"})
    assert not s.configured
    assert "API key" in s.problem


def test_placeholder_key_from_env_example_is_a_problem():
    s = load_settings({"LLM_PROVIDER": "groq", "LLM_API_KEY": "YOUR_LLM_API_KEY"})
    assert not s.configured and ".env.example" in s.problem


def test_openai_requires_model():
    s = load_settings({"LLM_PROVIDER": "openai", "LLM_API_KEY": "sk-x"})
    assert not s.configured and "LLM_MODEL" in s.problem
    s = load_settings({"LLM_PROVIDER": "openai", "LLM_API_KEY": "sk-x", "LLM_MODEL": "some-model"})
    assert s.configured and s.base_url == "https://api.openai.com/v1"


def test_custom_requires_base_url_and_model_but_not_key():
    s = load_settings({"LLM_PROVIDER": "custom", "LLM_MODEL": "llama3"})
    assert not s.configured and "LLM_BASE_URL" in s.problem
    s = load_settings({"LLM_PROVIDER": "custom", "LLM_MODEL": "llama3", "LLM_BASE_URL": "http://localhost:11434/v1/"})
    assert s.configured
    assert s.api_key == ""
    assert s.base_url == "http://localhost:11434/v1"  # garis miring di ujung dibuang


def test_unknown_provider_is_reported():
    s = load_settings({"LLM_PROVIDER": "grok", "LLM_API_KEY": "x"})
    assert not s.configured and "tidak dikenal" in s.problem


def test_bad_base_url_is_reported():
    s = load_settings({"LLM_PROVIDER": "groq", "LLM_API_KEY": "gsk_x", "LLM_BASE_URL": "api.groq.com/openai/v1"})
    assert not s.configured and "LLM_BASE_URL" in s.problem


def test_invalid_numbers_fall_back_or_clamp():
    s = load_settings({
        "LLM_TIMEOUT_S": "abc",
        "LLM_MAX_RETRIES": "99",
        "LLM_TEMPERATURE": "nan",
        "LLM_MAX_TOKENS": "1",
    })
    assert s.timeout_s == 8.0
    assert s.max_retries == 3
    assert s.temperature == 0.7
    assert s.max_tokens == 16
    assert s.configured  # salah ketik angka tidak boleh mematikan fitur


def test_overrides():
    s = load_settings({
        "LLM_PROVIDER": "groq", "LLM_API_KEY": "gsk_x", "LLM_MODEL": "openai/gpt-oss-20b",
        "LLM_MAX_TOKENS_PARAM": "max_tokens", "LLM_REASONING_EFFORT": "Low", "LLM_TIMEOUT_S": "3.5",
    })
    assert s.model == "openai/gpt-oss-20b"
    assert s.max_tokens_param == "max_tokens"
    assert s.reasoning_effort == "low"
    assert s.timeout_s == 3.5


def test_api_key_never_appears_in_repr():
    s = load_settings({"LLM_PROVIDER": "groq", "LLM_API_KEY": "gsk_supersecret"})
    assert "supersecret" not in repr(s)
    assert "supersecret" not in str(s)


def test_env_file_parsing_and_precedence(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(
        "# komentar\n"
        "LLM_PROVIDER=groq\n"
        'LLM_API_KEY="gsk_from_file"\n'
        "export LLM_MODEL=model-from-file   # catatan\n"
        "\n"
        "BUKAN_BARIS_VALID\n"
    )
    parsed = parse_env_file(env_file)
    assert parsed["LLM_API_KEY"] == "gsk_from_file"
    assert parsed["LLM_MODEL"] == "model-from-file"

    s = load_settings({"LLM_MODEL": "model-from-env"}, env_file=str(env_file))
    assert s.provider == "groq"
    assert s.api_key == "gsk_from_file"
    assert s.model == "model-from-env"  # environment asli menang atas file


def test_missing_env_file_is_ignored(tmp_path):
    assert parse_env_file(tmp_path / "tidak-ada.env") == {}
    assert load_settings({}, env_file=str(tmp_path / "tidak-ada.env")).provider == "mock"
