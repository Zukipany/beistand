"""Beistand backend: API keys, data cache and the safety service.

Run:  uvicorn app.main:app --reload   (from the backend folder)
"""
from __future__ import annotations

import asyncio
import contextlib
from datetime import datetime, timedelta, timezone
from html import escape

import httpx
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from . import crossings, data, guide, llm, orient
from .config import settings
from .lang import norm, tr
from .ladder import Contact, Incident, Ladder, Location, State, Trigger
from .notifier import make_notifier

notifier = make_notifier()
ladder = Ladder(notifier)


@contextlib.asynccontextmanager
async def lifespan(_: FastAPI):
    async def loop() -> None:
        while True:
            ladder.tick()
            await asyncio.sleep(1)

    task = asyncio.create_task(loop())
    yield
    task.cancel()


app = FastAPI(title="Beistand", version="0.1.0", lifespan=lifespan)


# =========================================================================== models

class ContactIn(BaseModel):
    name: str
    phone: str = Field(pattern=r"^\+[1-9]\d{6,14}$", description="E.164, e.g. +4915112345678")


class Profile(BaseModel):
    name: str
    language: str = "en"
    modes: list[str] = []
    contacts: list[ContactIn] = []


class LocationIn(BaseModel):
    lat: float
    lon: float
    accuracy_m: float | None = None


class IncidentStart(BaseModel):
    user_id: str
    trigger: Trigger
    location: LocationIn | None = None


class Ack(BaseModel):
    contact_name: str


class Confirm(BaseModel):
    confirmed_by: str


class ReadIn(BaseModel):
    image_b64: str
    media_type: str = "image/jpeg"
    lang: str = "en"


class ScamIn(BaseModel):
    text: str = Field(min_length=1, max_length=8000)
    lang: str = "en"


# Profiles live in memory until Supabase is wired in (see supabase/schema.sql).
profiles: dict[str, Profile] = {}


def incident_out(inc: Incident) -> dict:
    return {
        "id": inc.id, "user_id": inc.user_id, "trigger": inc.trigger, "state": inc.state,
        "deadline": inc.deadline, "contact_round": inc.contact_round, "acked_by": inc.acked_by,
        "show_bystander_card": inc.show_bystander_card,
        "offer_emergency_call": inc.state == State.emergency_confirmed,
        "location": inc.location.__dict__ if inc.location else None,
        "events": [e.__dict__ for e in inc.events],
    }


# =========================================================================== basics

@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "twilio": settings.twilio_enabled,
        "llm": bool(settings.anthropic_api_key),
        "gemini": bool(settings.gemini_api_key),
        "gemini_model": settings.gemini_live_model,
        "routes": "openrouteservice" if settings.ors_api_key else "valhalla",
        "vision": llm.providers() or ["offline"],
        "lifts": bool(settings.db_client_id and settings.db_api_key),
    }


@app.put("/users/{user_id}/profile")
def put_profile(user_id: str, p: Profile) -> Profile:
    profiles[user_id] = p
    return p


@app.get("/users/{user_id}/profile")
def get_profile(user_id: str) -> Profile:
    if user_id not in profiles:
        raise HTTPException(404, "no profile")
    return profiles[user_id]


# =========================================================================== safety ladder

def _inc(incident_id: str) -> Incident:
    if incident_id not in ladder.incidents:
        raise HTTPException(404, "unknown incident")
    return ladder.incidents[incident_id]


@app.post("/incidents")
def start_incident(body: IncidentStart) -> dict:
    p = profiles.get(body.user_id)
    if p is None:
        raise HTTPException(404, "register a profile first")
    loc = Location(**body.location.model_dump(), at=datetime.now(timezone.utc)) if body.location else None
    inc = ladder.start(user_id=body.user_id, person_name=p.name, trigger=body.trigger,
                       contacts=[Contact(c.name, c.phone) for c in p.contacts], location=loc,
                       lang=p.language)
    return incident_out(inc)


@app.get("/incidents/{incident_id}")
def get_incident(incident_id: str) -> dict:
    return incident_out(_inc(incident_id))


@app.post("/incidents/{incident_id}/ok")
def person_ok(incident_id: str) -> dict:
    _inc(incident_id)
    return incident_out(ladder.person_ok(incident_id))


@app.post("/incidents/{incident_id}/ack")
def contact_ack(incident_id: str, body: Ack) -> dict:
    _inc(incident_id)
    return incident_out(ladder.contact_ack(incident_id, body.contact_name))


@app.post("/incidents/{incident_id}/confirm-emergency")
def confirm_emergency(incident_id: str, body: Confirm) -> dict:
    _inc(incident_id)
    return incident_out(ladder.confirm_emergency(incident_id, body.confirmed_by))


@app.post("/incidents/{incident_id}/resolve")
def resolve(incident_id: str, body: Confirm) -> dict:
    _inc(incident_id)
    return incident_out(ladder.resolve(incident_id, body.confirmed_by))


@app.post("/incidents/{incident_id}/location")
def update_location(incident_id: str, body: LocationIn) -> dict:
    _inc(incident_id)
    return incident_out(ladder.update_location(
        incident_id, Location(**body.model_dump(), at=datetime.now(timezone.utc))))


@app.get("/live/{incident_id}", response_class=HTMLResponse)
def live_page(incident_id: str, t: str = Query(...)) -> str:
    """The page a contact opens from the SMS. Location is only shared during an alert."""
    inc = _inc(incident_id)
    if t != inc.share_token:
        raise HTTPException(403, "invalid link")

    def L(en: str, de: str) -> str:
        return tr(inc.lang, en, de)

    if inc.state == State.resolved:
        return _page(L("All clear", "Entwarnung"),
                     L(f"<p>{escape(inc.person_name)} is OK. The location is no longer shared.</p>",
                       f"<p>{escape(inc.person_name)} geht es gut. Der Standort wird nicht mehr geteilt.</p>"), lang=inc.lang)
    loc = inc.location
    map_link = (f'<p><a class="btn" href="https://www.openstreetmap.org/?mlat={loc.lat}&mlon={loc.lon}#map=18/{loc.lat}/{loc.lon}">'
                + L("Open location on the map", "Standort auf der Karte öffnen") + "</a></p>") if loc \
        else L("<p>No location yet.</p>", "<p>Noch kein Standort.</p>")
    log = "".join(f"<li>{e.at:%H:%M:%S} – {escape(e.detail)}</li>" for e in inc.events)
    ack = (f'<form method="get" action="/live/{inc.id}/ack"><input type="hidden" name="t" value="{inc.share_token}">'
           f'<input name="name" placeholder="{L("Your name", "Ihr Name")}" required> '
           f'<button class="btn">{L("I am taking care of it", "Ich kümmere mich")}</button></form>')
    return _page(L(f"{escape(inc.person_name)} may need help", f"{escape(inc.person_name)} braucht vielleicht Hilfe"),
                 f"<p>Status: <b>{inc.state.value}</b></p>{map_link}{ack}<h2>{L('History', 'Verlauf')}</h2><ul>{log}</ul>",
                 refresh=10, lang=inc.lang)


@app.get("/live/{incident_id}/ack", response_class=HTMLResponse)
def ack_from_link(incident_id: str, t: str, name: str) -> str:
    inc = _inc(incident_id)
    if t != inc.share_token:
        raise HTTPException(403, "invalid link")
    ladder.contact_ack(incident_id, name[:60])
    return _page(tr(inc.lang, "Thank you", "Danke"),
                 tr(inc.lang, "<p>Saved.", "<p>Gespeichert.") +
                 f' <a href="/live/{inc.id}?t={inc.share_token}">{tr(inc.lang, "Back", "Zurück")}</a></p>', lang=inc.lang)


def _page(title: str, body: str, refresh: int | None = None, lang: str = "en") -> str:
    meta = f'<meta http-equiv="refresh" content="{refresh}">' if refresh else ""
    return f"""<!doctype html><html lang="{norm(lang)}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">{meta}<title>{title}</title>
<style>body{{font:20px/1.5 system-ui;margin:0 auto;max-width:640px;padding:16px;background:#fff;color:#111}}
.btn{{display:inline-block;padding:14px 20px;background:#0a5;color:#fff;border:0;border-radius:10px;font-size:20px;text-decoration:none}}
input{{font-size:20px;padding:12px}}@media (prefers-color-scheme:dark){{body{{background:#111;color:#eee}}}}</style></head>
<body><h1>{title}</h1>{body}</body></html>"""


# =========================================================================== notifications log (demo + family view)

@app.get("/outbox")
def outbox(limit: int = 50) -> list[dict]:
    return [m.__dict__ for m in notifier.sent[-limit:]]


# =========================================================================== Read this / Scam check

@app.post("/read")
def read_this(body: ReadIn) -> dict:
    try:
        return llm.read_letter(body.image_b64, body.media_type, body.lang).__dict__
    except llm.LLMUnavailable as exc:
        raise HTTPException(503, str(exc)) from exc
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(502, f"reading failed: {exc}") from exc


@app.post("/scam-check")
def scam_check(body: ScamIn) -> dict:
    return llm.check_scam(body.text, body.lang).__dict__


# =========================================================================== Gemini Live token

@app.post("/gemini/token")
def gemini_token() -> dict:
    """Short-lived token so the phone can open the Live WebSocket directly. One use starts one
    session; session resumption may reconnect with the same token until `expireTime`."""
    if not settings.gemini_api_key:
        raise HTTPException(503, "GEMINI_API_KEY is not set")
    now = datetime.now(timezone.utc)
    body = {
        "uses": 1,
        "expireTime": (now + timedelta(minutes=30)).isoformat().replace("+00:00", "Z"),
        "newSessionExpireTime": (now + timedelta(minutes=1)).isoformat().replace("+00:00", "Z"),
    }
    try:
        r = httpx.post("https://generativelanguage.googleapis.com/v1beta/auth_tokens",
                       headers={"x-goog-api-key": settings.gemini_api_key}, json=body, timeout=15)
        r.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"token request failed: {exc}") from exc
    return {"token": r.json().get("name"), "model": settings.gemini_live_model, "expires": body["expireTime"]}


# =========================================================================== data cache

def _data(fn, *args, **kw) -> dict:
    try:
        return fn(*args, **kw)
    except ValueError as exc:
        raise HTTPException(400 if "unknown" in str(exc) or "profile" in str(exc) else 503, str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"source failed: {exc}") from exc


@app.get("/warnings")
def warnings(lat: float, lon: float, lang: str = "en") -> dict:
    return _data(data.weather, lat, lon, lang)


@app.get("/landmarks")
def landmarks(lat: float, lon: float, radius_m: int = Query(150, ge=30, le=400), lang: str = "en") -> dict:
    """Named streets, shops, stops and entrances around the person, for camera orientation."""
    return _data(orient.landmarks, lat, lon, radius_m, lang)


@app.get("/access")
def place_access(lat: float, lon: float, lang: str = "en", name: str | None = None,
                 radius_m: int = Query(120, ge=30, le=300)) -> dict:
    """Accessibility at a destination: step-free, lifts, entrances, toilets, steps (OpenStreetMap)."""
    return _data(orient.access, lat, lon, lang, name, radius_m)


@app.get("/stations")
def stations(lat: float, lon: float) -> dict:
    return _data(data.nearby_stations, lat, lon)


@app.get("/departures")
def departures(global_id: str, limit: int = 10) -> dict:
    return _data(data.departures, global_id, limit)


@app.get("/lifts")
def lifts(station_number: int) -> dict:
    return _data(data.lifts, station_number)


@app.get("/nearby")
def nearby(lat: float, lon: float, kind: str, radius_m: int = Query(400, le=2000)) -> dict:
    return _data(data.nearby, lat, lon, kind, radius_m)


@app.get("/route")
def route(from_lat: float, from_lon: float, to_lat: float, to_lon: float, profile: str = "foot-walking",
          lang: str = "en") -> dict:
    """Best available walking route: OpenRouteService (with key), else the free Valhalla server,
    else a straight line with distance and direction, so the guide never has nothing.
    Every route lists the traffic-light crossings on it, with their signal for blind people;
    for blind users the route with the best crossings is chosen."""
    start, end = (from_lat, from_lon), (to_lat, to_lon)
    route = None
    if settings.ors_api_key and profile in ("foot-walking", "wheelchair"):
        try:
            route = data.route(start, end, profile, lang) | {"provider": "openrouteservice"}
        except (httpx.HTTPError, ValueError, KeyError, IndexError):
            route = None
    if route is None:
        try:
            res = data.valhalla_route(start, end, profile, lang)
            route = res["data"] | {"age_s": res["age_s"], "stale": res["stale"]}
        except (httpx.HTTPError, ValueError, KeyError, IndexError):
            return data.direct_route(start, end, lang) | {"provider": "straight-line", "crossings": []}
    return _with_crossings(route, profile, lang)


def _with_crossings(route: dict, profile: str, lang: str) -> dict:
    """Adds crossings; picks the best alternative for blind users. Without the city data, routes still work."""
    try:
        lights = crossings.signals()["data"]
    except (httpx.HTTPError, ValueError, KeyError):
        return route | {"crossings": []}
    options = [route] + route.pop("alternatives", [])
    for r in options:
        r["crossings"] = crossings.along_route(r["geometry"], lang, lights)
    chosen = crossings.best_for_blind(options) if profile == "blind" and len(options) > 1 else options[0]
    chosen["alternatives_checked"] = len(options)
    return chosen


@app.get("/crossings")
def nearby_crossings(lat: float, lon: float, radius_m: int = Query(150, le=1000), lang: str = "en") -> dict:
    """Traffic lights near a point with their signal for blind people (for the guide's crossing_info tool)."""
    lights = _data(crossings.signals)["data"]
    near = sorted(({**s, "distance_m": round(crossings.distance_m((lat, lon), (s["lat"], s["lon"]))),
                    "say": crossings.say(s["signal"], lang)} for s in lights), key=lambda s: s["distance_m"])
    return {"crossings": [s for s in near if s["distance_m"] <= radius_m][:5], "total_in_city": len(lights)}


# =========================================================================== live camera guide

class DescribeIn(BaseModel):
    image_b64: str
    address: str | None = None
    heading: float | None = None
    question: str | None = None
    lang: str = "en"
    purpose: str = "lost"   # "lost" (where am I, what's ahead) | "magnify" (what is this, read it)
    nearby: list[str] = Field(default_factory=list, max_length=12)   # "Rossmann (drugstore), 20 m slightly right"


@app.get("/guide/prompt")
def guide_prompt(mode: str = "sight", lang: str = "en") -> dict:
    return _data(guide.prompt_for, mode, lang)


@app.get("/geocode")
def geocode(q: str = Query(..., min_length=2, max_length=200), lat: float = 48.137, lon: float = 11.575,
            lang: str = "en") -> dict:
    return _data(guide.geocode, q, lat, lon, lang)


@app.post("/describe")
def describe(body: DescribeIn) -> dict:
    """One-photo fallback when Gemini Live is not available."""
    try:
        return guide.describe(body.image_b64, body.address, body.heading, body.question, body.lang, body.purpose,
                              nearby=body.nearby)
    except llm.LLMUnavailable as exc:
        raise HTTPException(503, str(exc)) from exc
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(502, f"describe failed: {exc}") from exc
