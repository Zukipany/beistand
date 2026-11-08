"""The help ladder: a small state machine that runs on the backend.

It lives on the server so it keeps climbing if the phone breaks or dies.
Time is passed in explicitly (`now`), so the whole machine is testable
without sleeping; a background loop in main.py calls `tick()` every second.

    ASKING ──person OK──────────────▶ RESOLVED
      │ timeout (or explicit help)
      ▼
    CONTACTING ──contact acks──▶ CONTACT_RESPONDING ──resolve──▶ RESOLVED
      │  no ack: re-alert next contact, up to MAX_CONTACT_ROUNDS
      ▼
    either side confirms ──▶ EMERGENCY_CONFIRMED  (phone then shows the 112 / nora
                                                  dialog; iOS makes the person tap)

Rule from the plan: 112 is never called automatically.
"""
from __future__ import annotations

import secrets
import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum

from .lang import norm, tr
from .config import settings
from .notifier import LogNotifier

MAX_CONTACT_ROUNDS = 3


class Trigger(str, Enum):
    fall = "fall"
    help_button = "help_button"
    spoken_help = "spoken_help"
    lost = "lost"  # guide failed three times
    no_sign_of_life = "no_sign_of_life"
    long_shaking = "long_shaking"


# Explicit requests skip "Are you OK?" — the person already told us.
# `lost` comes from the guide only after the person said yes to calling their contact.
EXPLICIT = {Trigger.help_button, Trigger.spoken_help, Trigger.lost}


class State(str, Enum):
    asking = "asking"
    contacting = "contacting"
    contact_responding = "contact_responding"
    emergency_confirmed = "emergency_confirmed"
    resolved = "resolved"


TRIGGER_TEXT_EN = {
    Trigger.fall: "has probably fallen",
    Trigger.help_button: "pressed the help button",
    Trigger.spoken_help: "called for help",
    Trigger.lost: "is lost and can't find the way",
    Trigger.no_sign_of_life: "hasn't checked in today",
    Trigger.long_shaking: "may be having a seizure",
}

TRIGGER_TEXT_DE = {
    Trigger.fall: "ist vermutlich gestürzt",
    Trigger.help_button: "hat den Hilfe-Knopf gedrückt",
    Trigger.spoken_help: "hat um Hilfe gerufen",
    Trigger.lost: "hat sich verlaufen und findet den Weg nicht",
    Trigger.no_sign_of_life: "hat sich heute noch nicht gemeldet",
    Trigger.long_shaking: "hat möglicherweise einen Krampfanfall",
}


@dataclass
class Contact:
    name: str
    phone: str


@dataclass
class Location:
    lat: float
    lon: float
    accuracy_m: float | None = None
    at: datetime | None = None


@dataclass
class LadderEvent:
    at: datetime
    step: str
    detail: str


@dataclass
class Incident:
    id: str
    user_id: str
    person_name: str
    trigger: Trigger
    contacts: list[Contact]
    created_at: datetime
    state: State
    share_token: str
    deadline: datetime | None = None  # when the current step times out
    contact_round: int = 0
    location: Location | None = None
    acked_by: str | None = None
    events: list[LadderEvent] = field(default_factory=list)
    lang: str = "en"  # the person's phone language; contacts get messages in it

    def log(self, now: datetime, step: str, detail: str) -> None:
        self.events.append(LadderEvent(now, step, detail))

    @property
    def show_bystander_card(self) -> bool:
        return self.state in (State.contacting, State.contact_responding, State.emergency_confirmed)

    @property
    def live_link(self) -> str:
        return f"{settings.public_base_url}/live/{self.id}?t={self.share_token}"


class Ladder:
    def __init__(self, notifier: LogNotifier, ask_timeout_s: int | None = None,
                 contact_retry_s: int | None = None) -> None:
        self.notifier = notifier
        self.ask_timeout = timedelta(seconds=ask_timeout_s or settings.ask_timeout_s)
        self.contact_retry = timedelta(seconds=contact_retry_s or settings.contact_retry_s)
        self.incidents: dict[str, Incident] = {}
        self._lock = threading.RLock()

    # ---- starting -------------------------------------------------------
    def start(self, *, user_id: str, person_name: str, trigger: Trigger, contacts: list[Contact],
              location: Location | None = None, now: datetime | None = None, lang: str = "en") -> Incident:
        now = now or _now()
        with self._lock:
            # One open incident per person: a second trigger joins the first.
            for inc in self.incidents.values():
                if inc.user_id == user_id and inc.state != State.resolved:
                    inc.log(now, "trigger", f"Weiterer Auslöser: {trigger.value}")
                    if location:
                        inc.location = location
                    if trigger in EXPLICIT and inc.state == State.asking:
                        self._contact(inc, now)
                    return inc

            inc = Incident(
                id=secrets.token_urlsafe(8), user_id=user_id, person_name=person_name,
                trigger=trigger, contacts=contacts, created_at=now, state=State.asking,
                share_token=secrets.token_urlsafe(16), location=location, lang=norm(lang),
            )
            self.incidents[inc.id] = inc
            inc.log(now, "trigger", trigger.value)
            if trigger in EXPLICIT:
                self._contact(inc, now)
            else:
                inc.deadline = now + self.ask_timeout
                inc.log(now, "ask", f"„Alles in Ordnung?“ – {int(self.ask_timeout.total_seconds())} s Countdown")
            return inc

    # ---- answers --------------------------------------------------------
    def person_ok(self, incident_id: str, now: datetime | None = None) -> Incident:
        now = now or _now()
        with self._lock:
            inc = self._get(incident_id)
            if inc.state == State.resolved:
                return inc
            was_contacting = inc.state != State.asking
            inc.state, inc.deadline = State.resolved, None
            inc.log(now, "resolved", "Person hat bestätigt: alles in Ordnung")
            if was_contacting:
                for c in inc.contacts:
                    self.notifier.sms(c.phone, tr(inc.lang, f"All clear: {inc.person_name} confirmed that everything is OK.",
                                                     f"Entwarnung: {inc.person_name} hat bestätigt, dass alles in Ordnung ist."))
            return inc

    def contact_ack(self, incident_id: str, contact_name: str, now: datetime | None = None) -> Incident:
        now = now or _now()
        with self._lock:
            inc = self._get(incident_id)
            if inc.state in (State.contacting, State.asking):
                inc.state, inc.deadline, inc.acked_by = State.contact_responding, None, contact_name
                inc.log(now, "contact_ack", f"{contact_name} kümmert sich")
            return inc

    def confirm_emergency(self, incident_id: str, confirmed_by: str, now: datetime | None = None) -> Incident:
        """A clear yes from the person or a contact. The phone then offers 112 / nora."""
        now = now or _now()
        with self._lock:
            inc = self._get(incident_id)
            if inc.state != State.resolved:
                inc.state, inc.deadline = State.emergency_confirmed, None
                inc.log(now, "emergency", f"Notruf bestätigt von {confirmed_by}; Telefon bietet 112 an")
            return inc

    def resolve(self, incident_id: str, by: str, now: datetime | None = None) -> Incident:
        now = now or _now()
        with self._lock:
            inc = self._get(incident_id)
            inc.state, inc.deadline = State.resolved, None
            inc.log(now, "resolved", f"Beendet von {by}")
            return inc

    def update_location(self, incident_id: str, loc: Location) -> Incident:
        with self._lock:
            inc = self._get(incident_id)
            inc.location = loc
            return inc

    # ---- time -----------------------------------------------------------
    def tick(self, now: datetime | None = None) -> None:
        now = now or _now()
        with self._lock:
            for inc in list(self.incidents.values()):
                if inc.deadline is None or now < inc.deadline:
                    continue
                if inc.state == State.asking:
                    inc.log(now, "ask_timeout", "Keine Antwort")
                    self._contact(inc, now)
                elif inc.state == State.contacting:
                    if inc.contact_round >= MAX_CONTACT_ROUNDS:
                        inc.deadline = None
                        inc.log(now, "contact_exhausted", "Kein Kontakt erreicht; Hinweiskarte bleibt sichtbar")
                    else:
                        self._contact(inc, now)

    # ---- internals ------------------------------------------------------
    def _contact(self, inc: Incident, now: datetime) -> None:
        inc.state = State.contacting
        inc.deadline = now + self.contact_retry
        if not inc.contacts:
            inc.log(now, "contact", "Kein Notfallkontakt hinterlegt")
            inc.contact_round += 1
            return
        # Round 1 alerts the first contact; later rounds alert everyone.
        targets = inc.contacts[:1] if inc.contact_round == 0 else inc.contacts
        inc.contact_round += 1
        what = (TRIGGER_TEXT_DE if inc.lang == "de" else TRIGGER_TEXT_EN)[inc.trigger]
        for c in targets:
            self.notifier.sms(c.phone, tr(
                inc.lang,
                f"Beistand: {inc.person_name} {what}. Live location: {inc.live_link} "
                f"Please answer on the page or call.",
                f"Beistand: {inc.person_name} {what}. Live-Standort: {inc.live_link} "
                f"Bitte antworten Sie in der App oder rufen Sie an."))
            self.notifier.call(c.phone, tr(
                inc.lang,
                f"Hello {c.name}. This is Beistand. {inc.person_name} {what}. "
                f"We have sent you a text message with the location.",
                f"Hallo {c.name}. Hier ist Beistand. {inc.person_name} {what}. "
                f"Wir haben Ihnen eine SMS mit dem Standort geschickt."), lang=inc.lang)
            inc.log(now, "contact", f"Anruf und SMS an {c.name} (Runde {inc.contact_round})")

    def _get(self, incident_id: str) -> Incident:
        try:
            return self.incidents[incident_id]
        except KeyError as exc:
            raise KeyError(f"unknown incident {incident_id}") from exc


def _now() -> datetime:
    return datetime.now(timezone.utc)
