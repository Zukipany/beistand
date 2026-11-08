"""Settings read from environment variables (or a .env file next to the backend).

Every key is optional: without it the matching feature falls back to a safe
offline mode (log-only notifier, rule-based scam check, 503 for VLM calls).
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _load_dotenv() -> None:
    env = Path(__file__).resolve().parent.parent / ".env"
    if not env.exists():
        return
    for line in env.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"'))


_load_dotenv()


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


@dataclass(frozen=True)
class Settings:
    anthropic_api_key: str = field(default_factory=lambda: _env("ANTHROPIC_API_KEY"))
    anthropic_model: str = field(default_factory=lambda: _env("ANTHROPIC_MODEL", "claude-opus-5-5"))
    gemini_api_key: str = field(default_factory=lambda: _env("GEMINI_API_KEY"))
    # Public OpenStreetMap router, no key. Point at your own Valhalla for heavy use.
    valhalla_url: str = field(default_factory=lambda: _env("VALHALLA_URL", "https://valhalla1.openstreetmap.de"))
    # Used for photos when there is no Anthropic key. Model names change often: check ai.google.dev.
    gemini_vision_model: str = field(default_factory=lambda: _env("GEMINI_VISION_MODEL", "gemini-2.5-flash"))
    gemini_live_model: str = field(
        default_factory=lambda: _env("GEMINI_LIVE_MODEL", "gemini-3.8-live")
    )
    twilio_account_sid: str = field(default_factory=lambda: _env("TWILIO_ACCOUNT_SID"))
    twilio_auth_token: str = field(default_factory=lambda: _env("TWILIO_AUTH_TOKEN"))
    twilio_from_number: str = field(default_factory=lambda: _env("TWILIO_FROM_NUMBER"))
    ors_api_key: str = field(default_factory=lambda: _env("ORS_API_KEY"))
    db_client_id: str = field(default_factory=lambda: _env("DB_CLIENT_ID"))
    db_api_key: str = field(default_factory=lambda: _env("DB_API_KEY"))
    public_base_url: str = field(default_factory=lambda: _env("PUBLIC_BASE_URL", "http://localhost:8000"))
    # Seconds the person has to answer "Are you OK?" before the contact is called.
    ask_timeout_s: int = field(default_factory=lambda: int(_env("ASK_TIMEOUT_S", "30")))
    # Seconds the contact has to acknowledge before the ladder re-alerts them.
    contact_retry_s: int = field(default_factory=lambda: int(_env("CONTACT_RETRY_S", "120")))

    @property
    def twilio_enabled(self) -> bool:
        return bool(self.twilio_account_sid and self.twilio_auth_token and self.twilio_from_number)


settings = Settings()
