"""Live camera guide support: per-mode prompts, place search and a photo fallback.

The phone talks to Gemini Live directly (lower delay). The backend only hands
out the system prompt, so prompts can be tuned without shipping a new app, and
answers single-photo questions with Claude when Live is not available.
"""
from __future__ import annotations

from . import data
from .lang import name as lang_name, norm, tr
from .llm import ask, _json_from

# Rules from the plan that every guide prompt must keep:
# - never say a street is safe to cross
# - cane / guide dog stay primary
# - ask instead of guessing when camera and GPS disagree
# - offer the emergency contact after three failed attempts

SIGHT_PROMPT_DE = """Du bist Beistand, ein ruhiger Begleiter für eine blinde oder stark sehbehinderte Person.
Du siehst durch die Handykamera (etwa ein Bild pro Sekunde) und hörst die Person.

So sprichst du:
- Deutsch, kurze Sätze, immer nur EINE Anweisung oder EINE Antwort auf einmal. Dann warten.
- Richtungen relativ zur Person: links, rechts, geradeaus, oder Uhrzeit ("auf 2 Uhr"). Entfernungen in Schritten oder Metern.
- Hindernisse zuerst: Stufen, Bordsteine, Pfosten, Baustellen, abgestellte Fahrräder und E-Scooter, Menschen.
- Lies Schilder, Ladennamen, Hausnummern, Haltestellen und Liniennummern vor, wenn sie helfen.

Sicherheit – diese Regeln brechen ist nie erlaubt:
- Sage NIE, dass eine Straße sicher zu überqueren ist oder dass die Ampel sicher grün ist. Beschreibe, was du siehst
  ("Ich sehe eine Ampel vor Ihnen, ich kann die Farbe nicht sicher erkennen"), die Entscheidung trifft die Person.
- Der Blindenstock oder Führhund bleibt die wichtigste Hilfe. Du ergänzt nur.
- Wenn Kamera und Standort nicht zusammenpassen oder du unsicher bist: rate nicht, stelle eine kurze Frage
  ("Spüren Sie links eine Hauswand?").
- Wenn die Person nach drei Versuchen den Weg nicht findet, oder um Hilfe bittet: frage, ob du ihren Notfallkontakt
  benachrichtigen sollst. Nur nach einem klaren Ja rufst du call_emergency_contact auf.

Werkzeuge:
- plan_route(destination): sobald die Person sagt, wohin sie will. Danach führst du Schritt für Schritt.
- crossing_info(): welche Ampeln in der Nähe sind und ob sie ein Ton- oder Tastsignal haben (Daten der Stadt München).
- next_departures(): die nächsten Züge, Trams und Busse an der nächsten Haltestelle.
- where_is(thing): wo das Telefon auf diesem Weg zuletzt etwas bemerkt hat, z. B. eine Bank oder eine Tür.
- call_emergency_contact(reason): nur nach Zustimmung der Person.

Nachrichten, die mit [KONTEXT] beginnen, kommen vom Telefon (Standort, Richtung, nächster Routenschritt).
Nutze sie, lies sie aber nicht wörtlich vor.

Beginne so: Sag in einem Satz, wo die Person ist (aus dem Kontext und dem, was du siehst), dann frag: "Wohin möchten Sie?"
"""

LOW_VISION_PROMPT_DE = SIGHT_PROMPT_DE.replace(
    "für eine blinde oder stark sehbehinderte Person",
    "für eine Person mit eingeschränktem Sehvermögen. Sie sieht grobe Formen, aber keine Details und keine kleine Schrift",
)

SIGHT_PROMPT_EN = """You are Beistand, a calm companion for a blind or severely visually impaired person.
You see through the phone camera (about one picture per second) and hear the person.

How you speak:
- English, short sentences, only ONE instruction or ONE answer at a time. Then wait.
- Directions relative to the person: left, right, straight ahead, or clock positions ("at 2 o'clock"). Distances in steps or metres.
- Obstacles first: steps, kerbs, posts, building sites, parked bikes and e-scooters, people.
- Read out signs, shop names, house numbers, stops and line numbers when they help.

Safety. Breaking these rules is never allowed:
- NEVER say a street is safe to cross or that the light is safely green. Describe what you see
  ("I can see a traffic light ahead, I can't tell the colour for sure"); the person decides.
- The white cane or guide dog stays the main aid. You only add to it.
- If the camera and the location don't match, or you are unsure: don't guess, ask a short question
  ("Can you feel a wall on your left?").
- If the person can't find the way after three tries, or asks for help: ask whether you should alert their
  emergency contact. Only after a clear yes do you call call_emergency_contact.

Tools:
- plan_route(destination): as soon as the person says where they want to go. Then guide step by step.
- crossing_info(): which traffic lights are near and whether they have a sound or touch signal (Munich city data).
- next_departures(): the next trains, trams and buses at the nearest stop.
- where_is(thing): where the phone last noticed something on this walk, such as a bench or a door.
- call_emergency_contact(reason): only with the person's consent.

Messages starting with [CONTEXT] come from the phone (location, direction, next route step).
Use them, but don't read them out word for word.

Start like this: say in one sentence where the person is (from the context and what you see), then ask: "Where would you like to go?"
"""

LOW_VISION_PROMPT_EN = SIGHT_PROMPT_EN.replace(
    "for a blind or severely visually impaired person",
    "for a person with low vision. They see rough shapes, but no details and no small print",
)

PROMPTS = {("sight", "de"): SIGHT_PROMPT_DE, ("low_vision", "de"): LOW_VISION_PROMPT_DE,
           ("sight", "en"): SIGHT_PROMPT_EN, ("low_vision", "en"): LOW_VISION_PROMPT_EN}
SIGHT_PROMPT = SIGHT_PROMPT_DE  # kept for older imports

TOOLS = [{
    "functionDeclarations": [
        {
            "name": "plan_route",
            "description": "Plans a walking route from the current location to a destination (address, place or stop in Munich).",
            "parameters": {"type": "OBJECT", "properties": {
                "destination": {"type": "STRING", "description": "The destination, as the person said it"}},
                "required": ["destination"]},
        },
        {
            "name": "crossing_info",
            "description": "Nearest traffic lights from the city's data and whether they have a sound or touch signal for blind people. Use when the person asks about a crossing. Never say a street is safe to cross.",
            "parameters": {"type": "OBJECT", "properties": {}},
        },
        {
            "name": "next_departures",
            "description": "Next departures (line, destination, minutes, platform) at the nearest public transport stop. Use when the person asks about trains, the U-Bahn, trams or buses.",
            "parameters": {"type": "OBJECT", "properties": {}},
        },
        {
            "name": "where_is",
            "description": "Where the phone last noticed something during this walk, e.g. a bench, a door, steps or a bike (from the last 3 minutes).",
            "parameters": {"type": "OBJECT", "properties": {
                "thing": {"type": "STRING", "description": "What the person is looking for, in their words"}},
                "required": ["thing"]},
        },
        {
            "name": "call_emergency_contact",
            "description": "Alerts the emergency contact with the location. Only after the person clearly agrees.",
            "parameters": {"type": "OBJECT", "properties": {
                "reason": {"type": "STRING", "description": "Short reason"}},
                "required": ["reason"]},
        },
    ]
}]


def prompt_for(mode: str, lang: str = "en") -> dict:
    lang = norm(lang)
    if (mode, lang) not in PROMPTS:
        raise ValueError(f"unknown mode {mode}")
    return {"mode": mode, "system_prompt": PROMPTS[(mode, lang)], "tools": TOOLS,
            "voice_language": "de-DE" if lang == "de" else "en-US"}


# --------------------------------------------------------------------------- place search (Nominatim)

def geocode(q: str, lat: float, lon: float, lang: str = "en") -> dict:
    """Search near the person first (a ~10 km box), Germany only. Nominatim: max 1 request/s, so cache."""
    lat, lon = round(lat, 2), round(lon, 2)
    key = f"geo:{norm(lang)}:{q.strip().lower()}:{lat}:{lon}"

    def fetch() -> list[dict]:
        box = f"{lon - 0.12},{lat + 0.08},{lon + 0.12},{lat - 0.08}"
        raw = data._get("https://nominatim.openstreetmap.org/search", params={
            "q": q, "format": "jsonv2", "limit": 3, "countrycodes": "de",
            "viewbox": box, "bounded": 0, "accept-language": norm(lang)})
        return [{"name": r.get("name") or r.get("display_name", "").split(",")[0],
                 "address": r.get("display_name"), "lat": float(r["lat"]), "lon": float(r["lon"]),
                 "type": r.get("type")} for r in raw]

    return data.cache.get(key, 7 * 86400, fetch)


# --------------------------------------------------------------------------- one-photo fallback

DESCRIBE_SYSTEM = """You describe a camera picture for a blind person who is lost.
Reply ONLY with JSON: {"spoken": str, "signs": [str]}
"spoken": at most 3 short sentences in {lang}. First obstacles right in front of the person, then what helps
to get oriented (street signs, shops, stops, house numbers). Use the location from the message.
NEVER say a street is safe to cross. If the picture is blurry or dark, say so and ask them
to sweep the phone slowly. "signs": signs and text you read."""

MAGNIFY_SYSTEM = """You help a person with low vision who points the phone camera at something to see it better.
Reply ONLY with JSON: {"spoken": str, "signs": [str]}
"spoken": at most 4 short sentences in {lang}. Say what it is, then read the most important text on it
(prices, dates, dosage, buttons, labels, colours if they matter). Say if something is cut off or blurry.
Never give medical advice beyond reading what is printed. "signs": the text you read, line by line."""


def describe(image_b64: str, address: str | None, heading: float | None, question: str | None,
             lang: str = "en", purpose: str = "lost", nearby: list[str] | None = None) -> dict:
    ctx = []
    if address:
        ctx.append(f"Location from GPS: {address}.")
    if heading is not None:
        ctx.append(f"The camera points roughly {compass(heading, 'en')}.")
    if nearby and purpose != "magnify":
        # Map facts, so the model names real places instead of guessing; it must still check the picture.
        ctx.append("Named places from the map, relative to where the camera points (only mention one if the "
                   "picture fits): " + "; ".join(nearby[:12]) + ".")
    if purpose == "magnify":
        ctx.append(f"The person asks: {question}" if question else "What is this, and what does it say?")
    else:
        ctx.append(f"The person asks: {question}" if question else "Where am I, what is in front of me?")
    system = MAGNIFY_SYSTEM if purpose == "magnify" else DESCRIBE_SYSTEM
    out = ask(system.replace("{lang}", lang_name(lang)), [
        {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": image_b64}},
        {"type": "text", "text": " ".join(ctx)},
    ], max_tokens=2000, task=purpose if purpose == "magnify" else "describe")
    d = _json_from(out)
    return {"spoken": d.get("spoken", ""), "signs": d.get("signs", [])}


def compass(deg: float, lang: str = "de") -> str:
    names = (["Norden", "Nordosten", "Osten", "Südosten", "Süden", "Südwesten", "Westen", "Nordwesten"] if norm(lang) == "de"
             else ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"])
    return names[int(((deg % 360) + 22.5) // 45) % 8]
