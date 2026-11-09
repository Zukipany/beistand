"""Named things around the person, for camera orientation: "what is in the direction I'm pointing?".

The phone fetches this list once per place and does the direction maths itself, so turning around
gets an answer instantly, even without an AI key. Data: OpenStreetMap via Overpass.
"""
from __future__ import annotations

import math

import httpx

from . import data
from .lang import norm

R_EARTH = 6_371_000.0

# (tag, value or None) → (English, German) label. First match wins.
KINDS: list[tuple[str, str | None, str, str]] = [
    ("railway", "subway_entrance", "U-Bahn entrance", "U-Bahn-Eingang"),
    ("railway", "station", "station", "Bahnhof"),
    ("public_transport", "platform", "stop", "Haltestelle"),
    ("highway", "bus_stop", "bus stop", "Bushaltestelle"),
    ("railway", "tram_stop", "tram stop", "Tramhaltestelle"),
    ("amenity", "pharmacy", "pharmacy", "Apotheke"),
    ("amenity", "bank", "bank", "Bank"),
    ("amenity", "cafe", "café", "Café"),
    ("amenity", "restaurant", "restaurant", "Restaurant"),
    ("amenity", "fast_food", "fast food", "Imbiss"),
    ("amenity", "place_of_worship", "church", "Kirche"),
    ("amenity", "toilets", "toilets", "Toilette"),
    ("amenity", "post_office", "post office", "Post"),
    ("amenity", "hospital", "hospital", "Krankenhaus"),
    ("amenity", "doctors", "doctor", "Arztpraxis"),
    ("shop", "bakery", "bakery", "Bäckerei"),
    ("shop", "supermarket", "supermarket", "Supermarkt"),
    ("shop", "chemist", "drugstore", "Drogerie"),
    ("shop", None, "shop", "Geschäft"),
    ("tourism", None, "sight", "Sehenswürdigkeit"),
    ("historic", None, "landmark", "Denkmal"),
    ("amenity", None, "place", "Ort"),
    ("highway", None, "street", "Straße"),
]

STREET_TYPES = "primary|secondary|tertiary|residential|living_street|pedestrian|unclassified|service|footway"


OVERPASS = "https://overpass-api.de/api/interpreter"
OSM_MAP = "https://api.openstreetmap.org/api/0.6/map.json"


def overpass(q: str) -> list[dict]:
    res = httpx.post(OVERPASS, data={"data": q}, headers=data.UA, timeout=8)
    res.raise_for_status()
    return res.json().get("elements", [])


def osm_area(lat: float, lon: float, radius_m: int) -> list[dict]:
    """Everything tagged in a small box, straight from openstreetmap.org, shaped like Overpass `out tags geom`.

    The public Overpass server often refuses or times out for apps; the map API answers a few hundred
    metres in under a second. Only for small areas (the API allows 0.25 square degrees).
    """
    dlat = radius_m / 111_320
    dlon = radius_m / (111_320 * math.cos(math.radians(lat)))
    bbox = f"{lon - dlon:.5f},{lat - dlat:.5f},{lon + dlon:.5f},{lat + dlat:.5f}"
    res = httpx.get(OSM_MAP, params={"bbox": bbox}, headers=data.UA, timeout=20)
    res.raise_for_status()
    return osm_to_elements(res.json().get("elements", []))


def osm_to_elements(raw: list[dict]) -> list[dict]:
    nodes = {e["id"]: (e["lat"], e["lon"]) for e in raw if e.get("type") == "node" and "lat" in e}
    out = []
    for e in raw:
        if not e.get("tags"):
            continue
        if e["type"] == "node":
            out.append({"type": "node", "id": e["id"], "lat": e["lat"], "lon": e["lon"], "tags": e["tags"]})
        elif e["type"] == "way":
            geom = [{"lat": nodes[n][0], "lon": nodes[n][1]} for n in e.get("nodes", []) if n in nodes]
            if geom:
                out.append({"type": "way", "id": e["id"], "tags": e["tags"], "geometry": geom})
    return out


def area(q: str, lat: float, lon: float, radius_m: int) -> list[dict]:
    """Overpass first (quick timeout), the map API if Overpass is busy or refuses."""
    try:
        return overpass(q)
    except (httpx.HTTPError, ValueError):
        return osm_area(lat, lon, radius_m)


def is_landmark(tags: dict) -> bool:
    if tags.get("railway") in ("subway_entrance", "station", "tram_stop"):
        return True
    if not tags.get("name"):
        return False
    if tags.get("highway") == "bus_stop" or any(k in tags for k in ("shop", "amenity", "tourism", "historic")):
        return True
    return tags.get("highway") in STREET_TYPES.split("|")


def bearing(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Initial compass bearing from a to b, (lat, lon) in degrees, 0 = north, clockwise."""
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    y = math.sin(dl) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def distance(a: tuple[float, float], b: tuple[float, float]) -> float:
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(math.radians(b[1] - a[1]) / 2) ** 2
    return 2 * R_EARTH * math.asin(math.sqrt(h))


def nearest_on_line(p: tuple[float, float], line: list[tuple[float, float]]) -> tuple[tuple[float, float], float]:
    """Nearest point on a polyline (local flat projection, fine for < 1 km) and the line's bearing there."""
    k = math.cos(math.radians(p[0]))
    def xy(q):
        return ((q[1] - p[1]) * k * 111_320, (q[0] - p[0]) * 110_540)
    best, best_d, best_b = line[0], float("inf"), 0.0
    for a, b in zip(line, line[1:]):
        (ax, ay), (bx, by) = xy(a), xy(b)
        dx, dy = bx - ax, by - ay
        L = dx * dx + dy * dy
        t = 0.0 if L == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / L))
        cx, cy = ax + t * dx, ay + t * dy
        d = math.hypot(cx, cy)
        if d < best_d:
            best_d = d
            best = (p[0] + cy / 110_540, p[1] + cx / (k * 111_320))
            best_b = bearing(a, b) % 180
    return best, best_b


def kind_of(tags: dict, lang: str) -> str | None:
    de = norm(lang) == "de"
    for key, value, en, ge in KINDS:
        if key in tags and (value is None or tags[key] == value):
            return ge if de else en
    return None


def parse(elements: list[dict], here: tuple[float, float], lang: str = "en", limit: int = 60) -> list[dict]:
    """Overpass elements → [{name, kind, lat, lon, distance_m, street_bearing?}], nearest first, one per name."""
    best: dict[tuple[str, str], dict] = {}
    for el in elements:
        tags = el.get("tags", {})
        kind = kind_of(tags, lang)
        if not kind:
            continue
        name = tags.get("name") or (kind if tags.get("railway") == "subway_entrance" else None)
        if not name:
            continue
        street_bearing = None
        geom = [(g["lat"], g["lon"]) for g in el.get("geometry") or [] if g]
        if "highway" in tags and len(geom) >= 2:
            pt, street_bearing = nearest_on_line(here, geom)
        elif geom:
            pt = (sum(g[0] for g in geom) / len(geom), sum(g[1] for g in geom) / len(geom))
        elif "lat" in el:
            pt = (el["lat"], el["lon"])
        elif "center" in el:
            pt = (el["center"]["lat"], el["center"]["lon"])
        else:
            continue
        item = {"name": name, "kind": kind, "lat": round(pt[0], 6), "lon": round(pt[1], 6),
                "distance_m": round(distance(here, pt))}
        if street_bearing is not None:
            item["street_bearing"] = round(street_bearing)
        key = (name.lower(), kind)
        if key not in best or item["distance_m"] < best[key]["distance_m"]:
            best[key] = item
    return sorted(best.values(), key=lambda i: i["distance_m"])[:limit]


def landmarks(lat: float, lon: float, radius_m: int = 150, lang: str = "en") -> dict:
    """Cached per ~100 m cell; the phone refetches after walking about 60 m."""
    clat, clon = round(lat, 3), round(lon, 3)
    r = int(radius_m)
    q = (f'[out:json][timeout:20];('
         f'nw["name"]["shop"](around:{r},{clat},{clon});'
         f'nw["name"]["amenity"](around:{r},{clat},{clon});'
         f'nw["name"]["tourism"](around:{r},{clat},{clon});'
         f'nw["name"]["historic"](around:{r},{clat},{clon});'
         f'node["railway"~"subway_entrance|station|tram_stop"](around:{r},{clat},{clon});'
         f'node["highway"="bus_stop"]["name"](around:{r},{clat},{clon});'
         f'way["highway"~"{STREET_TYPES}"]["name"](around:{r},{clat},{clon});'
         f');out tags geom 400;')

    raw = data.cache.get(f"lm:{clat}:{clon}:{r}", 86400, lambda: area(q, clat, clon, r))
    out = dict(raw)
    out["data"] = parse([e for e in raw["data"] if is_landmark(e.get("tags", {}))], (lat, lon), lang)
    return out


# --------------------------------------------------------------------------- accessibility at a destination

def _point(el: dict) -> tuple[float, float] | None:
    geom = [(g["lat"], g["lon"]) for g in el.get("geometry") or [] if g]
    if geom:
        return (sum(g[0] for g in geom) / len(geom), sum(g[1] for g in geom) / len(geom))
    if "lat" in el:
        return (el["lat"], el["lon"])
    if "center" in el:
        return (el["center"]["lat"], el["center"]["lon"])
    return None


WHEEL = {"yes": ("step-free", "stufenlos"), "limited": ("partly step-free", "teilweise stufenlos"),
         "no": ("not step-free", "nicht stufenlos")}


def summarize_access(elements: list[dict], here: tuple[float, float], lang: str = "en", name: str | None = None) -> dict:
    """What a person in a wheelchair, with a walker or blind needs to know about the place at `here`.

    OpenStreetMap: a missing tag means "unknown", never "accessible" – the sentences say so.
    """
    de = norm(lang) == "de"
    t = (lambda en, ge: ge if de else en)
    place, place_d = None, 1e9
    elevators, entrances, toilets, steps, kerbs, tactile, parking = [], [], [], [], 0, 0, 0
    for el in elements:
        tags = el.get("tags", {})
        pt = _point(el)
        if not pt:
            continue
        d = distance(here, pt)
        if tags.get("highway") == "elevator" or tags.get("railway") == "elevator":
            elevators.append({"lat": pt[0], "lon": pt[1], "distance_m": round(d),
                              "direction": round(bearing(here, pt)), "name": tags.get("name") or tags.get("description"),
                              "level": tags.get("level"), "wheelchair": tags.get("wheelchair")})
        elif "entrance" in tags:
            entrances.append({"distance_m": round(d), "direction": round(bearing(here, pt)),
                              "wheelchair": tags.get("wheelchair"), "automatic_door": tags.get("automatic_door"),
                              "main": tags.get("entrance") == "main"})
        elif tags.get("amenity") == "toilets":
            if tags.get("wheelchair") in ("yes", "limited") or tags.get("toilets:wheelchair") == "yes":
                toilets.append({"distance_m": round(d), "direction": round(bearing(here, pt)),
                                "eurokey": tags.get("centralkey") == "eurokey"})
        elif tags.get("highway") == "steps":
            steps.append({"distance_m": round(d), "ramp": tags.get("ramp") == "yes" or tags.get("ramp:wheelchair") == "yes",
                          "count": tags.get("step_count")})
        elif tags.get("kerb") in ("lowered", "flush"):
            kerbs += 1
        elif tags.get("tactile_paving") == "yes":
            tactile += 1
        elif tags.get("parking_space") == "disabled" or tags.get("capacity:disabled") not in (None, "no", "0"):
            parking += 1
        if tags.get("name") and kind_of(tags, lang) and "highway" not in tags:
            # Exact name first, then a partial name match close by, then simply the nearest thing within 40 m.
            n, want = tags["name"].lower(), (name or "").lower()
            score = d - (1000 if want and n == want else 100 if want and want in n and d < 60 else 0)
            if score < place_d and (d < 40 or (want and n == want)):
                place_d = score
                place = {"name": tags["name"], "kind": kind_of(tags, lang), "distance_m": round(d),
                         "wheelchair": tags.get("wheelchair"), "toilets_wheelchair": tags.get("toilets:wheelchair"),
                         "wheelchair_description": tags.get(f"wheelchair:description:{norm(lang)}") or tags.get("wheelchair:description"),
                         "level": tags.get("level")}
    for lst in (elevators, entrances, toilets, steps):
        lst.sort(key=lambda x: x["distance_m"])

    says: list[str] = []
    if place:
        w = place["wheelchair"]
        if w in WHEEL:
            says.append(t(f"{place['name']} is marked {WHEEL[w][0]}.", f"{place['name']} ist als {WHEEL[w][1]} eingetragen."))
        else:
            says.append(t(f"For {place['name']} nobody has entered whether it is step-free.",
                          f"Für {place['name']} ist nicht eingetragen, ob es stufenlos ist."))
        if place["wheelchair_description"]:
            says.append(place["wheelchair_description"])
        if place["toilets_wheelchair"] == "yes":
            says.append(t("It has a wheelchair toilet.", "Es gibt dort eine rollstuhlgerechte Toilette."))
    if elevators:
        e = elevators[0]
        says.append(t(f"{len(elevators)} lift{'s' if len(elevators) > 1 else ''} nearby, the closest {e['distance_m']} m away.",
                      f"{len(elevators)} Aufzug{'' if len(elevators) == 1 else 'e'} in der Nähe, der nächste {e['distance_m']} m entfernt."))
    sf = [e for e in entrances if e["wheelchair"] == "yes"]
    if sf:
        says.append(t(f"Step-free entrance {sf[0]['distance_m']} m away" + (", automatic door." if sf[0]["automatic_door"] not in (None, "no") else "."),
                      f"Stufenloser Eingang {sf[0]['distance_m']} m entfernt" + (", automatische Tür." if sf[0]["automatic_door"] not in (None, "no") else ".")))
    if toilets:
        says.append(t(f"Accessible toilet {toilets[0]['distance_m']} m away" + (" (Euro key)." if toilets[0]["eurokey"] else "."),
                      f"Barrierefreie Toilette {toilets[0]['distance_m']} m entfernt" + (" (Euroschlüssel)." if toilets[0]["eurokey"] else ".")))
    no_ramp = [s for s in steps if not s["ramp"] and s["distance_m"] < 60]
    if no_ramp:
        says.append(t(f"Careful: steps without a ramp {no_ramp[0]['distance_m']} m away.",
                      f"Achtung: Stufen ohne Rampe {no_ramp[0]['distance_m']} m entfernt."))
    if tactile:
        says.append(t("There are tactile paving strips nearby.", "In der Nähe gibt es Blindenleitstreifen."))
    if not says:
        says.append(t("There is no accessibility information for this spot yet.",
                      "Für diesen Ort gibt es noch keine Angaben zur Barrierefreiheit."))
    return {"place": place, "elevators": elevators[:5], "entrances": entrances[:5], "toilets": toilets[:3],
            "steps": steps[:5], "lowered_kerbs": kerbs, "tactile_paving": tactile, "disabled_parking": parking,
            "spoken": " ".join(says)}


def access(lat: float, lon: float, lang: str = "en", name: str | None = None, radius_m: int = 120) -> dict:
    clat, clon, r = round(lat, 4), round(lon, 4), int(radius_m)
    a = f"(around:{r},{clat},{clon})"
    q = (f'[out:json][timeout:20];('
         f'nwr["wheelchair"]{a};'
         f'node["highway"="elevator"]{a};way["highway"="elevator"]{a};'
         f'node["entrance"]{a};'
         f'nwr["amenity"="toilets"]{a};'
         f'way["highway"="steps"]{a};'
         f'node["kerb"~"lowered|flush"]{a};'
         f'nw["tactile_paving"="yes"]{a};'
         f'nwr["parking_space"="disabled"]{a};'
         f'nw["name"]["shop"]{a};nw["name"]["amenity"]{a};nw["name"]["tourism"]{a};'
         f');out tags geom 500;')
    raw = data.cache.get(f"acc:{clat}:{clon}:{r}", 6 * 3600, lambda: area(q, clat, clon, r))
    near = [e for e in raw["data"] if (pt := _point(e)) and distance((lat, lon), pt) <= r]
    out = dict(raw)
    out["data"] = summarize_access(near, (lat, lon), lang, name)
    return out
