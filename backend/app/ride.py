"""Public transport trips for the ride helper: which line, every stop with its time, where to get off.

Data: MVG (Munich). Underground there is no GPS, so the phone follows the trip by the timetable,
by the stops it feels, and by station signs it reads; this module gives it the plan.
"""
from __future__ import annotations

import time
from datetime import datetime

from . import data

MVG = data.MVG


def _t(iso: str | None) -> float | None:
    return datetime.fromisoformat(iso).timestamp() if iso else None


def _stop(s: dict, time_key: str = "plannedDeparture", delay_key: str = "departureDelayInMinutes") -> dict:
    planned = _t(s.get(time_key))
    delay = s.get(delay_key) or 0
    return {"name": s.get("name"), "id": s.get("stationGlobalId"), "lat": s.get("latitude"), "lon": s.get("longitude"),
            "platform": s.get("platform"), "time": planned + 60 * delay if planned else None, "delay_min": delay}


def parse_trip(connection: dict) -> dict:
    """One MVG connection → legs with all stops and expected times (planned + delay, epoch seconds)."""
    legs = []
    for p in connection.get("parts", []):
        line = p.get("line", {})
        if line.get("transportType") in (None, "PEDESTRIAN", "FOOTWAY"):
            continue
        to = _stop(p["to"], "plannedDeparture", "arrivalDelayInMinutes")
        to |= {"exit": p.get("exitLetter") or None, "lift_out_of_order": bool(p["to"].get("hasOutOfOrderElevator")),
               "escalator_out_of_order": bool(p["to"].get("hasOutOfOrderEscalator"))}
        legs.append({
            "line": line.get("label"), "type": line.get("transportType"), "direction": line.get("destination"),
            "realtime": bool(p.get("realTime")),
            "from": _stop(p["from"]),
            "stops": [_stop(s, "plannedDeparture", "arrivalDelayInMinutes") for s in p.get("intermediateStops", [])],
            "to": to,
        })
    return {"legs": legs}


def search(query: str) -> dict:
    def fetch() -> list[dict]:
        raw = data._get(f"{MVG}/locations", params={"query": query, "locationTypes": "STATION"})
        return [{"id": s["globalId"], "name": s["name"], "place": s.get("place"), "lat": s.get("latitude"),
                 "lon": s.get("longitude"), "types": s.get("transportTypes", [])} for s in raw[:8]]
    return data.cache.get(f"loc:{query.strip().lower()}", 86400, fetch)


def trip(to_id: str, from_id: str | None = None, lat: float | None = None, lon: float | None = None) -> dict:
    """The next connection from a station (or the nearest one to lat/lon) to `to_id`."""
    if not from_id:
        if lat is None or lon is None:
            raise ValueError("give from_id or lat/lon")
        near = data.nearby_stations(lat, lon)["data"]
        if not near:
            raise ValueError("no station nearby")
        from_id = near[0]["globalId"]
    when = datetime.utcfromtimestamp(time.time()).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    raw = data._get(f"{MVG}/routes", params={"originStationGlobalId": from_id, "destinationStationGlobalId": to_id,
                                             "routingDateTime": when, "transportTypes": "UBAHN,SBAHN,TRAM,BUS"})
    if not raw:
        raise ValueError("no connection found")
    return {"data": parse_trip(raw[0]), "fetched_at": int(time.time())}
