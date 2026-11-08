"""Outgoing calls and texts. Twilio when configured, otherwise an in-memory log.

The in-memory notifier is what tests and the offline demo use: every message
is recorded so the family view and the demo can show what *would* have gone out.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Protocol
from xml.sax.saxutils import escape

import httpx

from .config import settings

log = logging.getLogger("beistand.notifier")


@dataclass
class Outgoing:
    kind: str  # "sms" | "call"
    to: str
    body: str
    at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    provider_id: str | None = None


class Notifier(Protocol):
    sent: list[Outgoing]

    def sms(self, to: str, body: str) -> Outgoing: ...
    def call(self, to: str, spoken_text: str, lang: str = "en") -> Outgoing: ...


class LogNotifier:
    """Records messages instead of sending them."""

    def __init__(self) -> None:
        self.sent: list[Outgoing] = []

    def sms(self, to: str, body: str) -> Outgoing:
        msg = Outgoing("sms", to, body)
        self.sent.append(msg)
        log.warning("[dry-run SMS to %s] %s", to, body)
        return msg

    def call(self, to: str, spoken_text: str, lang: str = "en") -> Outgoing:
        msg = Outgoing("call", to, spoken_text)
        self.sent.append(msg)
        log.warning("[dry-run CALL to %s] %s", to, spoken_text)
        return msg


class TwilioNotifier(LogNotifier):
    """Sends through Twilio's REST API. Keeps the same log for the family view."""

    def __init__(self) -> None:
        super().__init__()
        sid = settings.twilio_account_sid
        self._base = f"https://api.twilio.com/2010-04-01/Accounts/{sid}"
        self._auth = (sid, settings.twilio_auth_token)

    def _post(self, path: str, data: dict) -> str | None:
        try:
            r = httpx.post(f"{self._base}/{path}", data=data, auth=self._auth, timeout=15)
            r.raise_for_status()
            return r.json().get("sid")
        except httpx.HTTPError as exc:  # never let a provider error stop the ladder
            log.error("Twilio %s failed: %s", path, exc)
            return None

    def sms(self, to: str, body: str) -> Outgoing:
        msg = Outgoing("sms", to, body)
        msg.provider_id = self._post("Messages.json", {"To": to, "From": settings.twilio_from_number, "Body": body})
        self.sent.append(msg)
        return msg

    def call(self, to: str, spoken_text: str, lang: str = "en") -> Outgoing:
        # Say the message twice, slowly enough to follow, in the person's language.
        say = escape(spoken_text)
        voice = "de-DE" if lang == "de" else "en-GB"
        twiml = (
            "<Response>"
            f'<Say language="{voice}">{say}</Say><Pause length="1"/>'
            f'<Say language="{voice}">{say}</Say>'
            "</Response>"
        )
        msg = Outgoing("call", to, spoken_text)
        msg.provider_id = self._post("Calls.json", {"To": to, "From": settings.twilio_from_number, "Twiml": twiml})
        self.sent.append(msg)
        return msg


def make_notifier() -> LogNotifier:
    return TwilioNotifier() if settings.twilio_enabled else LogNotifier()
