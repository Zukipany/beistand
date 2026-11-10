"""Parked shared e-scooters and bikes nearby, from the operators' open GBFS feeds.

Blind and partially sighted people trip over scooters left on the pavement; the app vibrates when
the person walks towards one. Vehicles in an active rental are not in these feeds (privacy), so this
only covers parked ones; moving scooters are left to the camera.
Feeds: MobilityData's GBFS catalogue (github.com/MobilityData/gbfs, systems.csv), Munich entries.
"""
from __future__ import annotations

import httpx

from . import data
from .config import _env
from .orient import distance

# free_bike_status (GBFS 2.x) of operators with public Munich feeds. Override with SCOOTER_GBFS
# (comma-separated URLs) for another city.
DEFAULT_FEEDS = [
    "https://gbfs.api.ridedott.com/public/v2/munich/free_bike_status.json",
    "https://mds.bird.co/gbfs/v2/public/munich/free_bike_status.json",
]


def feeds() -> list[str]:
    custom = _env("SCOOTER_GBFS")
    return [u.strip() for u in custom.split(",") if u.strip()] if custom else DEFAULT_FEEDS


def _types(status_url: str) -> dict[str, str]:
    """vehicle_type_id → "scooter" | "bike" (from vehicle_types.json next to the status feed)."""
    url = status_url.rsplit("/", 1)[0] + "/vehicle_types.json"

    def fetch() -> dict[str, str]:
        r = httpx.get(url, headers=data.UA, timeout=15)
        r.raise_for_status()
        out = {}
        for t in r.json().get("data", {}).get("vehicle_types", []):
            ff = t.get("form_factor", "")
            out[t["vehicle_type_id"]] = "scooter" if "scooter" in ff else "bike" if ff in ("bicycle", "cargo_bicycle") else ff
        return out

    try:
        return data.cache.get(f"vt:{url}", 86400, fetch)["data"]
    except (httpx.HTTPError, ValueError, KeyError):
        return {}


def vehicles(url: str) -> list[dict]:
    """All parked vehicles of one operator, refreshed at most every 30 s."""
    operator = url.split("/")[2].replace("gbfs.api.", "").replace("mds.", "").split(".")[0]

    def fetch() -> list[dict]:
        r = httpx.get(url, headers=data.UA, timeout=15)
        r.raise_for_status()
        types = _types(url)
        out = []
        for b in r.json().get("data", {}).get("bikes", []):
            if b.get("is_disabled") or b.get("is_reserved") or b.get("lat") is None:
                continue
            out.append({"id": f"{operator}:{b.get('bike_id')}", "lat": b["lat"], "lon": b["lon"],
                        "kind": types.get(b.get("vehicle_type_id", ""), "scooter"), "operator": operator})
        return out

    return data.cache.get(f"gbfs:{url}", 30, fetch)["data"]


def near(all_vehicles: list[dict], here: tuple[float, float], radius_m: float, limit: int = 100) -> list[dict]:
    out = []
    for v in all_vehicles:
        d = distance(here, (v["lat"], v["lon"]))
        if d <= radius_m:
            out.append(v | {"distance_m": round(d, 1)})
    return sorted(out, key=lambda v: v["distance_m"])[:limit]


def nearby(lat: float, lon: float, radius_m: float = 150) -> dict:
    found, errors = [], []
    for url in feeds():
        try:
            found += vehicles(url)
        except (httpx.HTTPError, ValueError, KeyError) as exc:
            errors.append(f"{url.split('/')[2]}: {exc}")
    return {"data": near(found, (lat, lon), radius_m), "errors": errors}
