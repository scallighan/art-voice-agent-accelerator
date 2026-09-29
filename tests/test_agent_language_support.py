"""Tests for agent language support."""

import sys
import types
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
import yaml
from apps.artagent.backend.config.constants import (
    ARABIC_DIALECTS,
    ARABIC_TTS_VOICES,
    SUPPORTED_LANGUAGES,
    ArabicLocale,
    resolve_tts_voice,
)
from apps.artagent.backend.config.settings import RECOGNIZED_LANGUAGE
from apps.artagent.backend.registries.agentstore.base import SpeechConfig, UnifiedAgent
from pydantic import TypeAdapter, ValidationError

AGENTSTORE_DIR = (
    Path(__file__).parents[1] / "apps" / "artagent" / "backend" / "registries" / "agentstore"
)


def test_selected_arabic_dialects_are_supported():
    """The UI dialect choices should be accepted by the backend."""
    expected_locales = {"ar-AE", "ar-SA", "ar-EG", "ar-JO"}

    assert set(ARABIC_DIALECTS) == expected_locales
    assert expected_locales.issubset(SUPPORTED_LANGUAGES)
    assert "ar-AE" in RECOGNIZED_LANGUAGE
    assert "ar-AE" in SpeechConfig().candidate_languages
    assert "ar-AE" in SpeechConfig.from_dict({}).candidate_languages


@pytest.mark.parametrize("locale", ARABIC_DIALECTS)
def test_call_request_accepts_selected_arabic_dialects(locale):
    """The API locale type should accept every dialect exposed by the UI."""
    validated_locale = TypeAdapter(ArabicLocale).validate_python(locale)

    assert validated_locale == locale


def test_call_request_rejects_unsupported_locale():
    """The API locale type should reject locales not exposed by the selector."""
    with pytest.raises(ValidationError):
        TypeAdapter(ArabicLocale).validate_python("ar-KW")


@pytest.mark.parametrize(
    ("locale", "expected_voice"),
    ARABIC_TTS_VOICES.items(),
)
def test_selected_arabic_dialect_uses_native_regional_voice(locale, expected_voice):
    """Each exposed Arabic dialect should use a matching Azure neural voice."""
    assert resolve_tts_voice(locale, "en-US-AvaMultilingualNeural") == expected_voice


def test_non_arabic_language_preserves_configured_voice():
    """Non-Arabic sessions should continue using the agent's configured voice."""
    configured_voice = "en-US-AvaMultilingualNeural"

    assert resolve_tts_voice("en-US", configured_voice) == configured_voice


@pytest.mark.parametrize("locale", ARABIC_DIALECTS)
def test_rendered_prompt_preserves_selected_colloquial_dialect(locale):
    """Prompt refreshes should continue enforcing the selected dialect."""
    agent = UnifiedAgent(name="TestAgent", prompt_template="You are a helpful assistant.")

    rendered = agent.render_prompt({"transcription_language": locale})

    assert ARABIC_DIALECTS[locale] in rendered
    assert "natural colloquial dialect" in rendered
    assert "Modern Standard Arabic" in rendered
    assert "الفصحى" in rendered


def test_bundled_voicelive_agents_do_not_force_english_transcription():
    """Bundled agents should allow Voice Live to detect the caller's language."""
    yaml_paths = [AGENTSTORE_DIR / "_defaults.yaml", *AGENTSTORE_DIR.glob("*/agent.yaml")]

    for yaml_path in yaml_paths:
        config = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
        transcription = config.get("session", {}).get("input_audio_transcription_settings", {})
        assert "language" not in transcription, f"{yaml_path} forces {transcription['language']}"


@pytest.mark.asyncio
async def test_selected_arabic_locale_does_not_lock_voicelive_transcription(monkeypatch):
    """Arabic output selection must still allow callers to switch to English."""

    class FakeAudioInputTranscriptionOptions:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    class FakeRequestSession:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    fake_models = types.ModuleType("azure.ai.voicelive.models")
    fake_models.AudioInputTranscriptionOptions = FakeAudioInputTranscriptionOptions
    fake_models.RequestSession = FakeRequestSession
    monkeypatch.setitem(sys.modules, "azure.ai.voicelive.models", fake_models)

    agent = UnifiedAgent(
        name="TestAgent",
        prompt_template="You are a helpful assistant.",
        session={"input_audio_transcription_settings": {"model": "gpt-4o-transcribe"}},
    )
    monkeypatch.setattr(agent, "build_voicelive_voice", lambda **_: None)
    monkeypatch.setattr(agent, "build_voicelive_vad", lambda: None)
    monkeypatch.setattr(agent, "get_voicelive_modalities", lambda: ["audio", "text"])
    monkeypatch.setattr(agent, "get_voicelive_audio_formats", lambda: ("pcm16", "pcm16"))
    monkeypatch.setattr(agent, "_build_voicelive_tools_with_handoffs", lambda _: [])

    update = AsyncMock()
    connection = SimpleNamespace(session=SimpleNamespace(update=update))

    await agent.apply_voicelive_session(
        connection,
        system_vars={"transcription_language": "ar-AE"},
    )

    session_payload = update.await_args.kwargs["session"]
    transcription = session_payload.kwargs["input_audio_transcription"]
    assert transcription.kwargs == {"model": "gpt-4o-transcribe"}
