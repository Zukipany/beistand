"""Street-level pictures for the app's test drive: walk around a real street from a desk.

Providers (keys stay on the server):
- Google Street View Static API (GOOGLE_MAPS_API_KEY): exact position, heading and pitch.
  Google's terms limit Street View imagery to display; recognition on it is for local testing only.
- Mapillary (MAPILLARY_TOKEN): open street photos (CC BY-SA) that may be used for computer vision.
  Panoramas are cut to the direction the walker looks.
"""
from __future__ import annotations

import io
import json
from collections import OrderedDict
from dataclasses import dataclass

import httpx

from . import data
from .config import settings
from .orient import distance, distance_to_lines, walkways


class NoImagery(RuntimeError):
    """No provider configured, or no picture near this spot."""


@dataclass
class Picture:
    jpeg: bytes
    provider: str
    lat: float
    lon: float
    captured: str | None = None


def providers() -> list[str]:
    out = []
    if settings.google_maps_api_key:
        out.append("google")
    if settings.mapillary_token:
        out.append("mapillary")
    return out


_cache: OrderedDict[tuple, Picture] = OrderedDict()


def picture(lat: float, lon: float, heading: float, pitch: float = 0, fov: float = 80) -> Picture:
    """The street seen from (lat, lon) looking towards `heading`. Cached by ~1 m and 10°."""
    key = (round(lat, 5), round(lon, 5), int(round(heading / 10)) % 36, int(round(pitch / 10)), int(fov))
    if key in _cache:
        _cache.move_to_end(key)
        return _cache[key]
    errors = []
    for p in providers():
        try:
            pic = _google(lat, lon, heading, pitch, fov) if p == "google" else _mapillary(lat, lon, heading, fov)
            _cache[key] = pic
            if len(_cache) > 300:
                _cache.popitem(last=False)
            return pic
        except (NoImagery, httpx.HTTPError, ValueError, KeyError) as exc:
            errors.append(f"{p}: {exc}")
    if not errors:
        raise NoImagery("no street imagery key: set GOOGLE_MAPS_API_KEY or MAPILLARY_TOKEN in backend/.env")
    raise NoImagery("; ".join(errors))


# --------------------------------------------------------------------------- Google Street View Static

GOOGLE = "https://maps.googleapis.com/maps/api/streetview"


def _google(lat: float, lon: float, heading: float, pitch: float, fov: float) -> Picture:
    key = settings.google_maps_api_key
    # Metadata requests are free; they find the nearest outdoor panorama.
    meta = httpx.get(f"{GOOGLE}/metadata", params={"location": f"{lat},{lon}", "radius": 40, "source": "outdoor",
                                                  "key": key}, timeout=10).json()
    if meta.get("status") != "OK":
        raise NoImagery(f"google: {meta.get('status')}")
    r = httpx.get(GOOGLE, params={"size": "480x640", "pano": meta["pano_id"], "heading": round(heading, 1),
                                  "pitch": round(pitch, 1), "fov": fov, "key": key, "return_error_code": "true"},
                  timeout=15)
    r.raise_for_status()
    loc = meta.get("location", {})
    return Picture(r.content, "google", loc.get("lat", lat), loc.get("lng", lon), meta.get("date"))


# --------------------------------------------------------------------------- Mapillary

MAPILLARY = "https://graph.mapillary.com/images"


def position(im: dict) -> tuple[float, float] | None:
    """Where a photo really is: Mapillary's corrected position (from matching photos), else its GPS.

    None when the two disagree by more than 15 m: the photo's place is not trustworthy.
    """
    g = (im.get("geometry") or {}).get("coordinates")
    c = (im.get("computed_geometry") or {}).get("coordinates")
    if c and g and distance((g[1], g[0]), (c[1], c[0])) > 15:
        return None
    p = c or g
    return (p[1], p[0]) if p else None


def sequence_speeds(images: list[dict]) -> dict[str, float]:
    """Median speed (m/s) of each photo sequence: about 1-2 for someone walking, 5+ for a car."""
    by_seq: dict[str, list[dict]] = {}
    for im in images:
        if im.get("sequence") and im.get("captured_at") is not None:
            by_seq.setdefault(im["sequence"], []).append(im)
    out = {}
    for seq, ims in by_seq.items():
        ims.sort(key=lambda i: i["captured_at"])
        v = []
        for a, b in zip(ims, ims[1:]):
            dt = (b["captured_at"] - a["captured_at"]) / 1000
            pa, pb = position(a), position(b)
            if 0 < dt < 30 and pa and pb:
                v.append(distance(pa, pb) / dt)
        if v:
            v.sort()
            out[seq] = v[len(v) // 2]
    return out


DRIVING = 4.0          # m/s: faster than this, the photos were taken from a car or bike on the road


def pick(images: list[dict], here: tuple[float, float], heading: float,
         walk: list | None = None, speeds: dict[str, float] | None = None) -> dict | None:
    """Nearest picture that looks the right way, taken where a pedestrian walks.

    Panoramas look every way; 30° off counts like 10 m. A photo away from footpaths and sidewalks costs
    2 m per metre (up to 20), one from a sequence driven by car 15 m: a walker sees the street from the
    pavement, not from the middle of the road.
    """
    best, best_score = None, float("inf")
    for im in images:
        pos = position(im)
        if not pos:
            continue
        d = distance(here, pos)
        if im.get("is_pano"):
            score = d
        else:
            angle = im.get("computed_compass_angle", im.get("compass_angle"))
            if angle is None:
                continue
            off = abs((heading - angle + 180) % 360 - 180)
            if off > 60:
                continue
            score = d + off / 3
        if walk:
            off_path = distance_to_lines(pos, walk)
            if off_path > 3:
                score += min(20.0, 2 * off_path)
        if speeds and speeds.get(im.get("sequence", ""), 0) > DRIVING:
            score += 15
        if score < best_score:
            best, best_score = im, score
    return best


def pano_crop(width: int, height: int, heading: float, pano_angle: float, fov: float = 80) -> tuple[int, int, int, int]:
    """Equirectangular panorama → (x0, y0, w, h) of the slice towards `heading`. x0 may wrap past the edge.

    The panorama's centre column looks towards `pano_angle` (Mapillary's compass angle).
    """
    w = int(width * fov / 360)
    h = min(height, int(w * 4 / 3))                      # portrait, like the phone
    centre = ((heading - pano_angle) / 360 + 0.5) % 1 * width
    x0 = int(centre - w / 2) % width
    y0 = max(0, int(height / 2 - h * 0.45))              # a little above the horizon
    return x0, y0, w, h


def _crop(jpeg: bytes, box: tuple[int, int, int, int]) -> bytes:
    from PIL import Image

    img = Image.open(io.BytesIO(jpeg)).convert("RGB")
    x0, y0, w, h = box
    out = Image.new("RGB", (w, h))
    first = min(w, img.width - x0)
    out.paste(img.crop((x0, y0, x0 + first, y0 + h)), (0, 0))
    if first < w:                                          # wrap around the panorama's seam
        out.paste(img.crop((0, y0, w - first, y0 + h)), (first, 0))
    buf = io.BytesIO()
    out.save(buf, "JPEG", quality=80)
    return buf.getvalue()


FIELDS = ("id,thumb_2048_url,thumb_1024_url,computed_compass_angle,compass_angle,geometry,computed_geometry,"
          "is_pano,captured_at,sequence")


def nearest(lat: float, lon: float, heading: float, exclude: str | None = None) -> dict:
    """The Mapillary picture to start the walking viewer from."""
    if not settings.mapillary_token:
        raise NoImagery("no MAPILLARY_TOKEN in backend/.env")
    # Small boxes first, with a high limit so they hold every photo there: a big box only returns a
    # sample in busy streets, and the "nearest" of a sample can be far away.
    for d in (0.0005, 0.0008, 0.002):                      # ~50 m, ~80 m, ~200 m
        r = httpx.get(MAPILLARY, params={"access_token": settings.mapillary_token, "limit": 1000, "fields": FIELDS,
                                         "bbox": f"{lon - d},{lat - d},{lon + d},{lat + d}"}, headers=data.UA, timeout=15)
        r.raise_for_status()
        images = [i for i in r.json().get("data", []) if i.get("id") != exclude]
        im = pick(images, (lat, lon), heading, walk=_walk_near(lat, lon), speeds=sequence_speeds(images))
        if im:
            lat2, lon2 = position(im)
            return {"id": im["id"], "lat": lat2, "lon": lon2, "is_pano": bool(im.get("is_pano"))}
    raise NoImagery("mapillary: no picture within 200 m")


def _walk_near(lat: float, lon: float) -> list:
    """Walkway lines around (cached per ~100 m); none if OpenStreetMap is not reachable."""
    try:
        return [[tuple(p) for p in line] for line in walkways(lat, lon, 250)["data"]]
    except (httpx.HTTPError, ValueError, KeyError):
        return []


def by_id(image_id: str, heading: float, fov: float = 80) -> Picture:
    """The picture the walking viewer shows, cut to where the walker looks, for recognition on the phone."""
    if not settings.mapillary_token:
        raise NoImagery("no MAPILLARY_TOKEN in backend/.env")
    r = httpx.get(f"https://graph.mapillary.com/{image_id}", params={"access_token": settings.mapillary_token,
                                                                    "fields": FIELDS}, headers=data.UA, timeout=15)
    r.raise_for_status()
    return _download(r.json(), heading, fov)


def _mapillary(lat: float, lon: float, heading: float, fov: float) -> Picture:
    d = 0.0005                                             # ~50 m box
    r = httpx.get(MAPILLARY, params={
        "access_token": settings.mapillary_token, "limit": 1000, "fields": FIELDS,
        "bbox": f"{lon - d},{lat - d},{lon + d},{lat + d}"}, headers=data.UA, timeout=15)
    r.raise_for_status()
    im = pick(r.json().get("data", []), (lat, lon), heading)
    if not im:
        raise NoImagery("mapillary: no picture within 50 m")
    return _download(im, heading, fov)


def _download(im: dict, heading: float, fov: float) -> Picture:
    url = im.get("thumb_2048_url") if im.get("is_pano") else im.get("thumb_1024_url")
    raw = httpx.get(url, timeout=20)
    raw.raise_for_status()
    jpeg = raw.content
    if im.get("is_pano"):
        from PIL import Image
        size = Image.open(io.BytesIO(jpeg)).size
        angle = im.get("computed_compass_angle", im.get("compass_angle")) or 0
        jpeg = _crop(jpeg, pano_crop(size[0], size[1], heading, angle, fov))
    pos = position(im) or (im["geometry"]["coordinates"][1], im["geometry"]["coordinates"][0])
    captured = None
    if im.get("captured_at"):
        import datetime
        captured = datetime.datetime.fromtimestamp(im["captured_at"] / 1000, datetime.timezone.utc).strftime("%Y-%m")
    return Picture(jpeg, "mapillary", pos[0], pos[1], captured)


# --------------------------------------------------------------------------- walking viewer page

def viewer_page(lat: float, lon: float, heading: float) -> str:
    """MapillaryJS in the app's web view: animated steps between street photos (a 3D glide, not a jump).

    The app drives it with `drive.step(...)`, `drive.turn(deg)`, `drive.look(dy)` and hears back where the
    walker is and looks (`image`, `position`, `bearing` messages), which feed GPS, compass and camera.
    The client token is public by design (it is meant for browsers).
    """
    token = json.dumps(settings.mapillary_token)
    return VIEWER_HTML.replace("__TOKEN__", token).replace("__START__", json.dumps([lat, lon, heading]))


VIEWER_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<link rel="stylesheet" href="https://unpkg.com/mapillary-js@4.1.2/dist/mapillary.css">
<script src="https://unpkg.com/mapillary-js@4.1.2/dist/mapillary.js"></script>
<style>html,body,#mly{margin:0;height:100%;background:#222;color:#fff;font:16px -apple-system,sans-serif}
#msg{position:absolute;top:40%;left:16px;right:16px;text-align:center}</style></head>
<body><div id="mly"></div><div id="msg"></div>
<script>
const TOKEN = __TOKEN__, START = __START__;
const post = m => { try { window.webkit.messageHandlers.drive.postMessage(m); } catch (e) { console.log(JSON.stringify(m)); } };
const msg = t => { document.getElementById('msg').textContent = t || ''; };
window.drive = { go() {}, face() {}, step() {}, turn() {}, look() {} };
if (!TOKEN) {
  msg('Add MAPILLARY_TOKEN to backend/.env for street pictures.');
  post({type: 'error', message: 'no MAPILLARY_TOKEN in backend/.env'});
} else {
  const { Viewer, NavigationDirection } = mapillary;
  const viewer = new Viewer({ accessToken: TOKEN, container: 'mly',
    component: { cover: false, sequence: false, zoom: false, bearing: false, direction: true, keyboard: true } });
  let current = null, busy = false;
  // Where the walker wants to look. Ordinary photos only look one way, so the walker keeps its own
  // direction and every step picks the best photo for it, instead of following the photographer.
  let want = START[2];
  viewer.on('image', e => {
    current = e.image; msg('');
    post({ type: 'image', id: e.image.id, lat: e.image.lngLat.lat, lon: e.image.lngLat.lng,
           pano: e.image.cameraType === 'spherical', captured: e.image.capturedAt });
  });
  viewer.on('bearing', e => post({ type: 'bearing', bearing: e.bearing }));
  // After our own glide: turn to where the walker looks (the glide's animation would override it earlier).
  // After the person drags the picture: that is where they look now.
  let ours = false;
  viewer.on('moveend', async () => {
    if (ours) { ours = false; await window.drive.face(want); }
    else if (current && current.cameraType === 'spherical') { want = norm(await viewer.getBearing()); }
  });
  viewer.on('position', async () => { const p = await viewer.getPosition(); post({ type: 'position', lat: p.lat, lon: p.lng }); });
  // Which way each step goes, relative to where the walker looks.
  const OFFSET = { StepForward: 0, StepBackward: 180, StepLeft: -90, StepRight: 90 };
  const toRad = d => d * Math.PI / 180;
  const norm = d => ((d % 360) + 360) % 360;
  // A point `m` metres from (lat, lon) towards `bearing`.
  const ahead = (lat, lon, bearing, m) => [lat + m * Math.cos(toRad(bearing)) / 111320,
                                           lon + m * Math.sin(toRad(bearing)) / (111320 * Math.cos(toRad(lat)))];
  window.drive = {
    async go(lat, lon, heading) {
      want = norm(heading);
      msg('Loading street pictures …');
      const r = await fetch(`/drive/nearest?lat=${lat}&lon=${lon}&heading=${want}`);
      const j = await r.json();
      if (!r.ok) { msg(j.detail); post({ type: 'error', message: j.detail }); return; }
      ours = true;
      const img = await viewer.moveTo(j.id).catch(e => { post({ type: 'error', message: String(e) }); });
      if (img) await this.face(want);
    },
    // Panoramas: turn the view to `heading`. Ordinary photos look where they were taken.
    async face(heading) {
      if (!current || current.cameraType !== 'spherical') return;
      const b = await viewer.getBearing(), c = await viewer.getCenter();
      const delta = ((heading - b + 540) % 360) - 180;
      viewer.setCenter([(((c[0] + delta / 360) % 1) + 1) % 1, c[1]]);
    },
    // One animated step (MapillaryJS glides between the photos); held keys call this again when it ends.
    async step(name) {
      if (busy || !current) return;
      busy = true;
      try {
        ours = true;
        let moved = name in OFFSET && await this.towards(norm(want + OFFSET[name]));
        if (!moved) {
          try { await viewer.moveDir(NavigationDirection[name]); moved = true; } catch (e) {}
        }
        if (moved) await this.face(want); else { ours = false; post({ type: 'blocked', dir: name }); }
      } catch (e) { post({ type: 'blocked', dir: name }); }
      busy = false;
    },
    // The best photo 4-14 m towards `bearing` that looks the way the walker looks.
    async towards(bearing) {
      const here = current.lngLat;
      for (const m of [4, 8, 14]) {
        const [lat, lon] = ahead(here.lat, here.lng, bearing, m);
        const r = await fetch(`/drive/nearest?lat=${lat}&lon=${lon}&heading=${want}&exclude=${current.id}`);
        if (!r.ok) continue;
        const j = await r.json();
        const d = Math.hypot((j.lat - here.lat) * 111320, (j.lon - here.lng) * 111320 * Math.cos(toRad(here.lat)));
        const dir = Math.atan2((j.lon - here.lng) * Math.cos(toRad(here.lat)), j.lat - here.lat) * 180 / Math.PI;
        const off = Math.abs(((dir - bearing + 540) % 360) - 180);
        if (j.id !== current.id && d > 1.5 && off < 30) { await viewer.moveTo(j.id); return true; }
      }
      return false;
    },
    // Turning changes where the walker wants to look; panoramas turn smoothly, ordinary photos
    // swap to a nearby photo that looks that way once the turn is big enough.
    async turn(deg) {
      if (!current) return;
      want = norm(want + deg);
      if (current.cameraType === 'spherical') { ours = true; await this.face(want); return; }
      const b = await viewer.getBearing();
      if (Math.abs(((want - b + 540) % 360) - 180) >= 40 && !busy) {
        busy = true;
        const here = current.lngLat;
        const r = await fetch(`/drive/nearest?lat=${here.lat}&lon=${here.lng}&heading=${want}&exclude=${current.id}`);
        if (r.ok) { const j = await r.json(); ours = true; await viewer.moveTo(j.id).catch(() => {}); await this.face(want); }
        busy = false;
      }
    },
    async look(dy) {
      const c = await viewer.getCenter();
      viewer.setCenter([c[0], Math.min(0.85, Math.max(0.15, c[1] - dy))]);
    },
  };
  window.drive.go(START[0], START[1], START[2]);
}
</script></body></html>
"""
