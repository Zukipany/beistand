"""Data cache: weather/warnings, departures, lifts and nearby places.

Every response carries `fetched_at` and `age_s`, so the app can say how old
the data is (lift and transit feeds can be wrong or late). If a source fails,
the last good copy is returned with `stale: true` instead of an error.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Callable

import httpx

from .config import settings
from .lang import norm, tr

UA = {"User-Agent": "Beistand/0.1 (accessibility assistant; hackathon prototype)"}


@dataclass
class Entry:
    value: Any
    fetched: float


class Cache:
    def __init__(self) -> None:
        self._d: dict[str, Entry] = {}

    def get(self, key: str, ttl_s: float, fetch: Callable[[], Any]) -> dict:
        now = time.time()
        e = self._d.get(key)
        if e and now - e.fetched < ttl_s:
            return _wrap(e, now, stale=False)
        try:
            e = Entry(fetch(), now)
            self._d[key] = e
            return _wrap(e, now, stale=False)
        except (httpx.HTTPError, ValueError, KeyError) as exc:
            if e:
                return _wrap(e, now, stale=True) | {"error": str(exc)}
            raise


def _wrap(e: Entry, now: float, stale: bool) -> dict:
    return {"data": e.value, "fetched_at": int(e.fetched), "age_s": int(now - e.fetched), "stale": stale}


cache = Cache()


def _get(url: str, **kw) -> Any:
    r = httpx.get(url, headers=UA | kw.pop("headers", {}), timeout=15, **kw)
    r.raise_for_status()
    return r.json()


def _r(x: float) -> float:
    """Round coordinates to ~100 m so nearby requests share a cache entry."""
    return round(x, 3)


# --------------------------------------------------------------------------- weather guard

def weather(lat: float, lon: float, lang: str = "en") -> dict:
    lat, lon = _r(lat), _r(lon)

    def fetch() -> dict:
        cur = _get("https://api.brightsky.dev/current_weather", params={"lat": lat, "lon": lon})
        alerts = _get("https://api.brightsky.dev/alerts", params={"lat": lat, "lon": lon})
        w = cur.get("weather", {})
        al = alerts.get("alerts", [])
        return {
            "temperature_c": w.get("temperature"),
            "condition": w.get("condition"),
            "alerts": [{"event_de": a.get("event_de"), "event_en": a.get("event_en"),
                        "headline_de": a.get("headline_de"), "headline_en": a.get("headline_en"),
                        "severity": a.get("severity"), "onset": a.get("onset"), "expires": a.get("expires")}
                       for a in al],
        }

    # Cache the raw data once; word it per language on the way out.
    res = dict(cache.get(f"wx:{lat}:{lon}", 600, fetch))
    d = dict(res["data"])
    de = norm(lang) == "de"
    d["alerts"] = [{"event": a["event_de"] if de else (a["event_en"] or a["event_de"]),
                    "headline": a["headline_de"] if de else (a["headline_en"] or a["headline_de"]),
                    "severity": a["severity"], "onset": a["onset"], "expires": a["expires"]} for a in d["alerts"]]
    d["tip"] = weather_tip(d["temperature_c"], d["condition"], [a["event_de"] or "" for a in res["data"]["alerts"]], lang)
    res["data"] = d
    return res


def weather_tip(temp: float | None, condition: str | None, events: list[str], lang: str = "en") -> str:
    ev = " ".join(events).lower()   # DWD event names are German
    if "glätte" in ev or "glatteis" in ev or (temp is not None and temp <= 1 and condition in ("rain", "sleet", "snow")):
        return tr(lang, "It may be icy today. Wear sturdy shoes or wait until midday.",
                  "Heute kann es glatt sein. Ziehen Sie feste Schuhe an oder warten Sie bis Mittag.")
    if "sturm" in ev or "orkan" in ev or "gewitter" in ev:
        return tr(lang, "There's a storm or thunderstorm today. Stay inside if you can.",
                  "Heute gibt es Sturm oder Gewitter. Bleiben Sie wenn möglich drinnen.")
    if "hitze" in ev or (temp is not None and temp >= 28):
        return tr(lang, "It will be hot today. Drink a glass of water often and stay in the shade at midday.",
                  "Heute wird es heiß. Trinken Sie oft ein Glas Wasser und bleiben Sie mittags im Schatten.")
    if temp is not None and temp <= -5:
        return tr(lang, "It's very cold today. Dress warmly.", "Heute ist es sehr kalt. Ziehen Sie sich warm an.")
    if condition == "rain":
        return tr(lang, "It's raining today. Take an umbrella.", "Heute regnet es. Nehmen Sie einen Schirm mit.")
    return tr(lang, "No weather warning today.", "Heute gibt es keine Wetterwarnung.")


# --------------------------------------------------------------------------- transit (MVG, unofficial)

MVG = "https://www.mvg.de/api/bgw-pt/v3"


def nearby_stations(lat: float, lon: float) -> dict:
    lat, lon = _r(lat), _r(lon)
    return cache.get(f"st:{lat}:{lon}", 86400,
                     lambda: _get(f"{MVG}/stations/nearby", params={"latitude": lat, "longitude": lon}))


def departures(global_id: str, limit: int = 10) -> dict:
    def fetch() -> list[dict]:
        raw = _get(f"{MVG}/departures", params={"globalId": global_id, "limit": limit})
        return [{
            "line": d.get("label"), "destination": d.get("destination"),
            "platform": d.get("platform"), "planned": d.get("plannedDepartureTime"),
            "realtime": d.get("realtimeDepartureTime"), "delay_min": d.get("delayInMinutes"),
            "cancelled": d.get("cancelled", False), "type": d.get("transportType"),
            "barrier_free": d.get("barrierFree"),
        } for d in raw]

    return cache.get(f"dep:{global_id}:{limit}", 30, fetch)


# --------------------------------------------------------------------------- lifts (DB FaSta)

def lifts(station_number: int) -> dict:
    def fetch() -> list[dict]:
        if not (settings.db_client_id and settings.db_api_key):
            raise ValueError("DB_CLIENT_ID / DB_API_KEY not set")
        raw = _get(
            "https://apis.deutschebahn.com/db-api-marketplace/apis/fasta/v2/facilities",
            params={"stationnumber": station_number, "type": "ELEVATOR"},
            headers={"DB-Client-Id": settings.db_client_id, "DB-Api-Key": settings.db_api_key},
        )
        return [{"id": f.get("equipmentnumber"), "description": f.get("description"),
                 "state": f.get("state"), "reason": f.get("stateExplanation"),
                 "lat": f.get("geocoordY"), "lon": f.get("geocoordX")} for f in raw]

    return cache.get(f"lift:{station_number}", 300, fetch)


# --------------------------------------------------------------------------- places (Overpass)

PLACE_QUERIES = {
    "bench": 'node["amenity"="bench"]',
    "toilet": 'nwr["amenity"="toilets"]',
    "wheelchair_toilet": 'nwr["amenity"="toilets"]["wheelchair"="yes"]',
    "pharmacy": 'nwr["amenity"="pharmacy"]',
    "doctor": 'nwr["amenity"~"doctors|clinic"]',
    "disabled_parking": 'nwr["amenity"="parking_space"]["parking_space"="disabled"]',
}


def nearby(lat: float, lon: float, kind: str, radius_m: int = 400) -> dict:
    if kind not in PLACE_QUERIES:
        raise ValueError(f"unknown kind {kind}")
    lat, lon = _r(lat), _r(lon)
    q = f'[out:json][timeout:20];{PLACE_QUERIES[kind]}(around:{radius_m},{lat},{lon});out center 50;'

    def fetch() -> list[dict]:
        r = httpx.post("https://overpass-api.de/api/interpreter", data={"data": q}, headers=UA, timeout=30)
        r.raise_for_status()
        out = []
        for el in r.json().get("elements", []):
            c = el.get("center") or el
            out.append({"id": f'{el["type"]}/{el["id"]}', "lat": c.get("lat"), "lon": c.get("lon"),
                        "name": el.get("tags", {}).get("name"), "tags": el.get("tags", {})})
        return out

    return cache.get(f"pl:{kind}:{lat}:{lon}:{radius_m}", 86400, fetch)


# --------------------------------------------------------------------------- routes (OpenRouteService)

def route(start: tuple[float, float], end: tuple[float, float], profile: str = "foot-walking", lang: str = "en") -> dict:
    """start/end are (lat, lon). profile: foot-walking | wheelchair."""
    if profile not in ("foot-walking", "wheelchair"):
        raise ValueError("profile must be foot-walking or wheelchair")
    if not settings.ors_api_key:
        raise ValueError("ORS_API_KEY not set")
    body: dict = {"coordinates": [[start[1], start[0]], [end[1], end[0]]], "language": norm(lang), "instructions": True}
    if profile == "foot-walking":
        body["options"] = {"avoid_features": ["steps"]}
    else:
        body["options"] = {"profile_params": {"restrictions": {"maximum_incline": 6, "maximum_sloped_kerb": 0.03}}}
    r = httpx.post(f"https://api.openrouteservice.org/v2/directions/{profile}/geojson", json=body,
                   headers={"Authorization": settings.ors_api_key} | UA, timeout=30)
    r.raise_for_status()
    feat = r.json()["features"][0]
    seg = feat["properties"]["segments"][0]
    coords = feat["geometry"]["coordinates"]
    steps = [{"instruction": s["instruction"], "distance_m": round(s["distance"]),
              "lat": coords[s["way_points"][0]][1], "lon": coords[s["way_points"][0]][0]}
             for s in seg["steps"]]
    return {"distance_m": round(seg["distance"]), "duration_s": round(seg["duration"]),
            "steps": steps, "geometry": coords}


# --------------------------------------------------------------------------- Valhalla (OpenStreetMap, no key)

VALHALLA_TYPE = {"foot-walking": "foot", "wheelchair": "wheelchair", "blind": "blind"}


def decode_polyline6(encoded: str) -> list[list[float]]:
    """Valhalla shapes: Google polyline with 6 decimals. Returns [[lon, lat], ...] like GeoJSON."""
    coords, index, lat, lon = [], 0, 0, 0
    while index < len(encoded):
        for axis in (0, 1):
            shift, result = 0, 0
            while True:
                b = ord(encoded[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else result >> 1
            if axis == 0:
                lat += delta
            else:
                lon += delta
        coords.append([lon / 1e6, lat / 1e6])
    return coords


def valhalla_route(start: tuple[float, float], end: tuple[float, float], profile: str = "foot-walking",
                   lang: str = "en") -> dict:
    """Walking routes from the public OpenStreetMap Valhalla server. Profiles:
    foot-walking (avoids steps where it can), wheelchair (no steps, kerb-aware), blind (more detailed,
    landmark-style instructions). Fair use: cached, one request per route."""
    if profile not in VALHALLA_TYPE:
        raise ValueError("profile must be foot-walking, wheelchair or blind")
    pedestrian: dict = {"type": VALHALLA_TYPE[profile]}
    if profile == "foot-walking":
        pedestrian["step_penalty"] = 60   # seconds added per flight of steps: older people prefer ramps
    body = {"locations": [{"lat": start[0], "lon": start[1]}, {"lat": end[0], "lon": end[1]}],
            "costing": "pedestrian", "costing_options": {"pedestrian": pedestrian},
            "language": "de-DE" if norm(lang) == "de" else "en-US", "units": "kilometers"}
    if profile == "blind":
        body["alternates"] = 2       # pick the one with the best crossings (see crossings.best_for_blind)

    def parse(trip: dict) -> dict:
        leg = trip["legs"][0]
        coords = decode_polyline6(leg["shape"])
        steps = [{"instruction": m["instruction"], "distance_m": round(m["length"] * 1000),
                  "lat": coords[m["begin_shape_index"]][1], "lon": coords[m["begin_shape_index"]][0]}
                 for m in leg["maneuvers"]]
        summary = leg["summary"]
        return {"distance_m": round(summary["length"] * 1000), "duration_s": round(summary["time"]),
                "steps": steps, "geometry": coords, "provider": "valhalla"}

    def fetch() -> dict:
        r = httpx.post(f"{settings.valhalla_url}/route", json=body, headers=UA, timeout=30)
        r.raise_for_status()
        j = r.json()
        main = parse(j["trip"])
        main["alternatives"] = [parse(a["trip"]) for a in j.get("alternates", [])]
        return main

    key = f"vh:{profile}:{norm(lang)}:{round(start[0], 5)},{round(start[1], 5)}:{round(end[0], 5)},{round(end[1], 5)}"
    return cache.get(key, 6 * 3600, fetch)


def direct_route(start: tuple[float, float], end: tuple[float, float], lang: str = "en") -> dict:
    """Straight-line fallback: one step with distance and compass direction."""
    from math import atan2, cos, degrees, radians, sin, sqrt
    lat1, lon1, lat2, lon2 = map(radians, (*start, *end))
    dlat, dlon = lat2 - lat1, lon2 - lon1
    a = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlon / 2) ** 2
    dist = 2 * 6371000 * atan2(sqrt(a), sqrt(1 - a))
    bearing = (degrees(atan2(sin(dlon) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dlon))) + 360) % 360
    names = (["Norden", "Nordosten", "Osten", "Südosten", "Süden", "Südwesten", "Westen", "Nordwesten"] if norm(lang) == "de"
             else ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"])
    direction = names[int((bearing + 22.5) // 45) % 8]
    return {"distance_m": round(dist), "duration_s": round(dist / 1.1), "direct": True,
            "steps": [{"instruction": tr(lang,
                                         f"The destination is about {round(dist, -1):.0f} metres to the {direction}. "
                                         f"There is no planned route, so take extra care around you.",
                                         f"Das Ziel liegt etwa {round(dist, -1):.0f} Meter Richtung {direction}. "
                                         f"Es gibt keinen geplanten Weg, achten Sie besonders auf die Umgebung."),
                       "distance_m": round(dist), "lat": start[0], "lon": start[1]},
                      {"instruction": tr(lang, "You have reached your destination.", "Sie haben Ihr Ziel erreicht."), "distance_m": 0, "lat": end[0], "lon": end[1]}],
            "geometry": [[start[1], start[0]], [end[1], end[0]]]}
