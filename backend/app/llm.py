"""Text and vision calls: Read this (letters) and Scam check.

Uses the Claude Messages API over plain HTTPS. Scam check also has an offline,
rule-based fallback so the demo works without a key. Neither feature ever
declares a message safe.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass

import httpx

from .lang import name as lang_name, tr

from .config import settings

class LLMUnavailable(RuntimeError):
    pass


# --------------------------------------------------------------------------- vision/language model chain
#
# One entry point, several providers, tried in order:
#   1. Claude (Anthropic SDK) - best quality. Refusals fall back server-side to a suitable model.
#   2. Gemini (REST) - when only a Gemini key is configured.
# Without any key the caller gets LLMUnavailable and uses its own offline fallback
# (rule-based scam check, on-device text reading in the app).

# Effort per task: reading a letter is worth more thought than "what's in front of me?" while walking.
EFFORT = {"read": "medium", "scam": "medium", "describe": "low", "magnify": "low"}

_client = None


def _anthropic():
    global _client
    if _client is None:
        import anthropic
        _client = anthropic.Anthropic(api_key=settings.anthropic_api_key, timeout=60, max_retries=2)
    return _client


def _ask_claude(system: str, content: list[dict], max_tokens: int, task: str) -> str:
    import anthropic
    try:
        r = _anthropic().beta.messages.create(
            model=settings.anthropic_model,
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": content}],
            output_config={"effort": EFFORT.get(task, "medium")},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
    except (anthropic.APIConnectionError, anthropic.RateLimitError, anthropic.APIStatusError) as exc:
        raise LLMUnavailable(f"Claude: {exc}") from exc
    if r.stop_reason == "refusal":
        raise LLMUnavailable("Claude declined this request")
    return "".join(b.text for b in r.content if b.type == "text")


def _ask_gemini(system: str, content: list[dict], max_tokens: int) -> str:
    parts: list[dict] = []
    for block in content:
        if block.get("type") == "image":
            src = block["source"]
            parts.append({"inline_data": {"mime_type": src["media_type"], "data": src["data"]}})
        elif block.get("type") == "text":
            parts.append({"text": block["text"]})
    try:
        r = httpx.post(
            f"https://generativelanguage.googleapis.com/v1beta/models/{settings.gemini_vision_model}:generateContent",
            headers={"x-goog-api-key": settings.gemini_api_key},
            json={"system_instruction": {"parts": [{"text": system}]},
                  "contents": [{"role": "user", "parts": parts}],
                  "generationConfig": {"maxOutputTokens": max_tokens}},
            timeout=60,
        )
        r.raise_for_status()
        cands = r.json().get("candidates") or []
        return "".join(p.get("text", "") for p in (cands[0]["content"].get("parts", []) if cands else []))
    except (httpx.HTTPError, KeyError) as exc:
        raise LLMUnavailable(f"Gemini: {exc}") from exc


def providers() -> list[str]:
    """Which models answer, in order. Shown in the app's Diagnostics screen."""
    out = []
    if settings.anthropic_api_key:
        out.append(f"claude:{settings.anthropic_model}")
    if settings.gemini_api_key:
        out.append(f"gemini:{settings.gemini_vision_model}")
    return out


def ask(system: str, content: list[dict], max_tokens: int = 1500, task: str = "read") -> str:
    errors = []
    if settings.anthropic_api_key:
        try:
            return _ask_claude(system, content, max_tokens, task)
        except LLMUnavailable as exc:
            errors.append(str(exc))
    if settings.gemini_api_key:
        try:
            return _ask_gemini(system, content, max_tokens)
        except LLMUnavailable as exc:
            errors.append(str(exc))
    raise LLMUnavailable("; ".join(errors) or "no vision model configured (ANTHROPIC_API_KEY or GEMINI_API_KEY)")


# Older name, kept for callers.
_claude = ask


def _json_from(text: str) -> dict:
    match = re.search(r"\{.*\}", text, re.S)
    if not match:
        raise ValueError("model did not return JSON")
    return json.loads(match.group(0))


# --------------------------------------------------------------------------- Read this

READ_SYSTEM = """You help older people understand letters and packaging.
Read the photo. Reply ONLY with JSON:
{"readable": bool,              // false if blurry, cut off or no text
 "retake_hint": str|null,       // short tip for a new photo, e.g. "Please move closer."
 "sender": str|null,
 "wants": str|null,             // what the sender wants, one short sentence
 "amount": str|null,            // amount with currency, if any
 "deadline": str|null,          // deadline written out plainly, e.g. "3 December 2026", if any
 "spoken": str}                 // 2-4 sentences in Easy Language (in German: Leichte Sprache).
                                // First what to do and by when.
Rules: short sentences, no jargon, no legal or medical advice.
If it looks like a scam (pressure, unusual ways to pay), say so in "spoken".
Write every text field in {lang}, whatever language the letter is in."""


@dataclass
class LetterReading:
    readable: bool
    retake_hint: str | None
    sender: str | None
    wants: str | None
    amount: str | None
    deadline: str | None
    spoken: str


def read_letter(image_b64: str, media_type: str = "image/jpeg", lang: str = "en") -> LetterReading:
    text = _claude(
        READ_SYSTEM.replace("{lang}", lang_name(lang)),
        [
            {"type": "image", "source": {"type": "base64", "media_type": media_type, "data": image_b64}},
            {"type": "text", "text": "What does this say?"},
        ],
        max_tokens=4000, task="read",
    )
    d = _json_from(text)
    return LetterReading(
        readable=bool(d.get("readable", True)),
        retake_hint=d.get("retake_hint"),
        sender=d.get("sender"), wants=d.get("wants"), amount=d.get("amount"),
        deadline=d.get("deadline"), spoken=d.get("spoken") or "",
    )


# --------------------------------------------------------------------------- Scam check

# Known scam patterns, German and English wording. Each: (id, regex, explanation EN, explanation DE).
SCAM_PATTERNS: list[tuple[str, str, str, str]] = [
    ("new_number",
     r"(neue[rn]? (handy)?nummer|mein (altes )?handy (ist )?kaputt|hallo (mama|papa|oma|opa)"
     r"|new (phone )?number|my (old )?phone (is )?broken|hi (mum|mom|dad|grandma|grandpa|nan))",
     "Someone is pretending to be your child or grandchild with a new number.",
     "Jemand gibt sich als Ihr Kind oder Enkel mit neuer Nummer aus."),
    ("fake_police",
     r"(polizei|kriminalpolizei|staatsanwalt|police|detective|prosecutor).{0,80}"
     r"(geld|wertsachen|schmuck|abholen|sicher|money|valuables|jewel|collect|safe)",
     "Real police never collect money or jewellery from your home.",
     "Echte Polizei holt niemals Geld oder Schmuck bei Ihnen ab."),
    ("fake_bank",
     r"(konto (wurde )?gesperrt|sparkasse|volksbank|bank|account (has been |was )?(locked|suspended|blocked)).{0,80}"
     r"(pin|tan|bestätig|link|verifizier|confirm|verify|click|password)",
     "Your bank never asks for your PIN, a code or a click on a link by message.",
     "Ihre Bank fragt nie per Nachricht nach PIN, TAN oder einem Klick auf einen Link."),
    ("fake_parcel",
     r"(paket|sendung|zustellung|dhl|hermes|parcel|package|delivery|royal mail|ups|fedex).{0,80}"
     r"(gebühr|zoll|link|klicken|bestätigen|fee|customs|click|confirm|pay)",
     "Delivery companies don't ask for a fee through a link in a text message.",
     "Paketdienste verlangen keine Gebühr über einen Link in einer SMS."),
    ("urgent_payment",
     r"(sofort|dringend|heute noch|innerhalb von \d+ stunden|immediately|urgent|today|within \d+ hours).{0,80}"
     r"(überweis|zahl|gutschein|bitcoin|transfer|pay|gift card|crypto)",
     "Strong time pressure to pay is a typical sign of a scam.",
     "Großer Zeitdruck beim Bezahlen ist ein typisches Betrugszeichen."),
    ("gift_cards",
     r"(google play|itunes|apple|paysafe|amazon|steam).{0,30}(karte|gutschein|code|card|voucher)",
     "No honest person or company wants to be paid with gift cards.",
     "Niemand Seriöses möchte mit Gutscheinkarten bezahlt werden."),
    ("prize",
     r"(gewonnen|gewinn|lotterie|preis|you('ve| have)? won|winner|lottery|prize).{0,80}"
     r"(gebühr|zahlen|überweis|anrufen|fee|pay|transfer|call)",
     "You never have to pay anything to receive a real prize.",
     "Für einen echten Gewinn muss man nichts bezahlen."),
    ("shock_call",
     r"(unfall|krankenhaus|kaution|verhaftet|accident|hospital|bail|arrested).{0,80}"
     r"(geld|zahlen|überweis|bar|money|pay|transfer|cash)",
     "With shock calls like this: hang up and call the person on the number you already know.",
     "Bei solchen Schockanrufen: auflegen und die Person unter der bekannten Nummer anrufen."),
]


@dataclass
class ScamVerdict:
    level: str  # "likely_scam" | "suspicious" | "unclear"  (never "safe")
    patterns: list[str]
    spoken: str
    source: str  # "llm" | "rules"


def _rule_check(text: str, lang: str = "en") -> ScamVerdict:
    low = text.lower()
    hits = [(pid, tr(lang, en, de)) for pid, rx, en, de in SCAM_PATTERNS if re.search(rx, low, re.S)]
    if len(hits) >= 1 and (len(hits) >= 2 or hits[0][0] in {"new_number", "fake_police", "gift_cards", "shock_call"}):
        level = "likely_scam"
    elif hits:
        level = "suspicious"
    else:
        level = "unclear"
    if level == "unclear":
        spoken = tr(lang,
                    "I don't recognise a known trick. That does not mean the message is safe. "
                    "Don't pay anything or give out any details before you've asked someone you trust.",
                    "Ich erkenne keinen bekannten Trick. Das heißt aber nicht, dass die Nachricht sicher ist. "
                    "Zahlen Sie nichts und geben Sie keine Daten heraus, bevor Sie jemanden gefragt haben, dem Sie vertrauen.")
    else:
        head = (tr(lang, "This looks like a scam.", "Das sieht nach Betrug aus.") if level == "likely_scam"
                else tr(lang, "Careful, this is suspicious.", "Vorsicht, das ist verdächtig."))
        spoken = f"{head} {hits[0][1]} " + tr(lang,
            "Don't pay anything. Call the person or company on the number you already know.",
            "Zahlen Sie nichts. Rufen Sie die Person oder Firma unter der Nummer an, die Sie schon kennen.")
    return ScamVerdict(level, [h[0] for h in hits], spoken, "rules")


SCAM_SYSTEM = """You check messages and descriptions of phone calls for older people for scams.
Known patterns: {patterns}.
Reply ONLY with JSON: {"level": "likely_scam"|"suspicious"|"unclear", "patterns": [ids], "spoken": str}
"spoken": 2-3 short sentences in plain language, the warning first, then one concrete action
(e.g. "Call your son on the number you already know.").
NEVER say that a message is safe or genuine. If no pattern fits: level "unclear", and still
advise caution. Write "spoken" in {lang}."""


def check_scam(text: str, lang: str = "en") -> ScamVerdict:
    rules = _rule_check(text, lang)
    try:
        patterns = ", ".join(f"{pid} ({en})" for pid, _, en, _ in SCAM_PATTERNS)
        out = _claude(
            SCAM_SYSTEM.replace("{patterns}", patterns).replace("{lang}", lang_name(lang)),
            [{"type": "text", "text": text[:4000]}], max_tokens=2000, task="scam",
        )
        d = _json_from(out)
        level = d.get("level")
        if level not in ("likely_scam", "suspicious", "unclear"):
            level = "unclear"
        # The rules can only raise the warning level, never lower it.
        order = ["unclear", "suspicious", "likely_scam"]
        if order.index(rules.level) > order.index(level):
            return rules
        return ScamVerdict(level, list(d.get("patterns") or rules.patterns), d.get("spoken") or rules.spoken, "llm")
    except (LLMUnavailable, httpx.HTTPError, ValueError, json.JSONDecodeError):
        return rules
