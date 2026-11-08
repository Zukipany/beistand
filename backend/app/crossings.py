"""Munich traffic lights with signals for blind people, and which of them lie on a route.

Source: Landeshauptstadt München, Mobilitätsreferat, open data "Lichtsignalanlagen" (dl-de/by-2.0).
Field `zeb`: "TA" = tactile and acoustic signal, "T" = tactile only, empty = none.
"""
from __future__ import annotations

from math import cos, radians, sqrt

from . import data
from .lang import tr

WFS = ("https://geoportal.muenchen.de/geoserver/mor_wfs/ows?service=WFS&version=1.0.0&request=GetFeature"
       "&typeName=mor_wfs:lsa_opendata&outputFormat=application/json")
SIGNAL = {"TA": "sound", "T": "tactile"}
NEAR_ROUTE_M = 15


def signals() -> dict:
    """All traffic lights, cached for a day (the data changes rarely)."""
    def fetch() -> list[dict]:
        out = []
        for f in data._get(WFS).get("features", []):
            p = f.get("properties", {})
            if p.get("abbau") or p.get("lat") is None:   # removed installations
                continue
            out.append({"name": p.get("standort"), "lat": float(p["lat"]), "lon": float(p["lon"]),
                        "signal": SIGNAL.get(p.get("zeb") or "", "none")})
        return out
    return data.cache.get("lsa", 86400, fetch)


# ---------------------------------------------------------------- geometry (metres, local flat projection)

def _xy(lat: float, lon: float, lat0: float) -> tuple[float, float]:
    return lon * 111320 * cos(radians(lat0)), lat * 110540


def distance_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    ax, ay = _xy(*a, a[0])
    bx, by = _xy(*b, a[0])
    return sqrt((ax - bx) ** 2 + (ay - by) ** 2)


def project(point: tuple[float, float], line: list[list[float]]) -> tuple[float, float]:
    """(distance from the line in m, distance along the line to the closest point in m).
    `line` is [[lon, lat], ...] as in GeoJSON."""
    lat0 = point[0]
    px, py = _xy(point[0], point[1], lat0)
    best, along, walked = float("inf"), 0.0, 0.0
    for (lon1, lat1), (lon2, lat2) in zip(line, line[1:]):
        x1, y1 = _xy(lat1, lon1, lat0)
        x2, y2 = _xy(lat2, lon2, lat0)
        dx, dy = x2 - x1, y2 - y1
        seg = sqrt(dx * dx + dy * dy)
        t = 0.0 if seg == 0 else max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / (seg * seg)))
        cx, cy = x1 + t * dx, y1 + t * dy
        d = sqrt((px - cx) ** 2 + (py - cy) ** 2)
        if d < best:
            best, along = d, walked + t * seg
        walked += seg
    return best, along


def along_route(line: list[list[float]], lang: str = "en", lights: list[dict] | None = None) -> list[dict]:
    """Traffic-light crossings within 15 m of the route, in walking order."""
    if len(line) < 2:
        return []
    lights = lights if lights is not None else signals()["data"]
    lons = [p[0] for p in line]
    lats = [p[1] for p in line]
    pad = 0.0003   # ~30 m: cheap box filter before exact distances
    box = (min(lats) - pad, max(lats) + pad, min(lons) - pad, max(lons) + pad)
    out = []
    for s in lights:
        if not (box[0] <= s["lat"] <= box[1] and box[2] <= s["lon"] <= box[3]):
            continue
        off, along = project((s["lat"], s["lon"]), line)
        if off <= NEAR_ROUTE_M:
            out.append({"type": "crossing", "signal": s["signal"], "name": s["name"],
                        "lat": s["lat"], "lon": s["lon"], "along_m": round(along),
                        "say": say(s["signal"], lang)})
    return sorted(out, key=lambda c: c["along_m"])


def say(signal: str, lang: str = "en") -> str:
    if signal == "sound":
        return tr(lang, "Traffic light crossing ahead, with a sound and touch signal.",
                  "Ampel voraus, mit Ton- und Tastsignal.")
    if signal == "tactile":
        return tr(lang, "Traffic light crossing ahead, with a touch signal, no sound.",
                  "Ampel voraus, mit Tastsignal, ohne Ton.")
    return tr(lang, "Traffic light crossing ahead, without a signal for blind people.",
              "Ampel voraus, ohne Signal für Blinde.")


def best_for_blind(routes: list[dict], max_detour: float = 1.15) -> dict:
    """Among alternatives, prefer the most crossings with a sound signal and the fewest without any,
    as long as the route is at most 15 % longer than the shortest."""
    shortest = min(r["distance_m"] for r in routes)
    ok = [r for r in routes if r["distance_m"] <= shortest * max_detour]

    def score(r: dict) -> tuple:
        cs = r.get("crossings", [])
        return (sum(c["signal"] == "sound" for c in cs) - 2 * sum(c["signal"] == "none" for c in cs),
                -r["distance_m"])
    return max(ok, key=score)
