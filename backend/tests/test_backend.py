from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from app import llm
from app.data import weather_tip
from app.ladder import Contact, Ladder, State, Trigger
from app.notifier import LogNotifier

T0 = datetime(2026, 11, 28, 10, 0, tzinfo=timezone.utc)
CONTACTS = [Contact("Anna", "+4915100000001"), Contact("Max", "+4915100000002")]


def make() -> tuple[Ladder, LogNotifier]:
    n = LogNotifier()
    return Ladder(n, ask_timeout_s=30, contact_retry_s=120), n


# ---------------------------------------------------------------- ladder

def test_fall_asks_first_then_contacts_first_contact_after_timeout():
    lad, n = make()
    inc = lad.start(user_id="u", person_name="Oma Ilse", trigger=Trigger.fall, contacts=CONTACTS, now=T0, lang="de")
    assert inc.state == State.asking and not n.sent
    lad.tick(T0 + timedelta(seconds=29))
    assert inc.state == State.asking
    lad.tick(T0 + timedelta(seconds=30))
    assert inc.state == State.contacting
    assert {m.to for m in n.sent} == {"+4915100000001"}
    assert {m.kind for m in n.sent} == {"sms", "call"}
    assert "gestürzt" in n.sent[0].body and inc.live_link in n.sent[0].body
    assert inc.show_bystander_card


def test_person_ok_during_countdown_sends_nothing():
    lad, n = make()
    inc = lad.start(user_id="u", person_name="Ilse", trigger=Trigger.fall, contacts=CONTACTS, now=T0)
    lad.person_ok(inc.id, T0 + timedelta(seconds=5))
    lad.tick(T0 + timedelta(seconds=60))
    assert inc.state == State.resolved and not n.sent


def test_help_button_skips_question():
    lad, n = make()
    inc = lad.start(user_id="u", person_name="Ilse", trigger=Trigger.help_button, contacts=CONTACTS, now=T0)
    assert inc.state == State.contacting and len(n.sent) == 2


def test_no_ack_escalates_to_all_contacts_then_stops():
    lad, n = make()
    inc = lad.start(user_id="u", person_name="Ilse", trigger=Trigger.help_button, contacts=CONTACTS, now=T0)
    lad.tick(T0 + timedelta(seconds=120))
    assert inc.contact_round == 2 and len(n.sent) == 2 + 4
    lad.tick(T0 + timedelta(seconds=240))
    assert inc.contact_round == 3
    lad.tick(T0 + timedelta(seconds=360))
    assert inc.deadline is None and inc.contact_round == 3  # stops, card stays up
    assert inc.show_bystander_card


def test_ack_stops_escalation_and_ok_sends_all_clear():
    lad, n = make()
    inc = lad.start(user_id="u", person_name="Ilse", trigger=Trigger.help_button, contacts=CONTACTS, now=T0, lang="de")
    lad.contact_ack(inc.id, "Anna", T0 + timedelta(seconds=10))
    lad.tick(T0 + timedelta(seconds=600))
    assert inc.state == State.contact_responding and len(n.sent) == 2
    lad.person_ok(inc.id, T0 + timedelta(seconds=700))
    assert "Entwarnung" in n.sent[-1].body


def test_emergency_is_never_automatic():
    lad, _ = make()
    inc = lad.start(user_id="u", person_name="Ilse", trigger=Trigger.fall, contacts=CONTACTS, now=T0)
    for s in range(0, 3600, 30):
        lad.tick(T0 + timedelta(seconds=s))
    assert inc.state != State.emergency_confirmed
    lad.confirm_emergency(inc.id, "Anna")
    assert inc.state == State.emergency_confirmed


def test_second_trigger_joins_open_incident():
    lad, _ = make()
    a = lad.start(user_id="u", person_name="Ilse", trigger=Trigger.fall, contacts=CONTACTS, now=T0)
    b = lad.start(user_id="u", person_name="Ilse", trigger=Trigger.spoken_help, contacts=CONTACTS, now=T0)
    assert a is b and a.state == State.contacting


# ---------------------------------------------------------------- scam rules

def test_scam_rules(monkeypatch):
    monkeypatch.setattr(llm.settings.__class__, "anthropic_api_key", property(lambda s: ""), raising=False)
    v = llm.check_scam("Hallo Mama, das ist meine neue Nummer. Kannst du mir heute noch 900 € überweisen?")
    assert v.level == "likely_scam" and "new_number" in v.patterns
    v = llm.check_scam("Ihr DHL Paket wartet. Zollgebühr 1,99 € – bitte Link klicken")
    assert v.level in ("suspicious", "likely_scam")
    v = llm.check_scam("Treffen wir uns morgen um drei im Café?", lang="de")
    assert v.level == "unclear" and "nicht, dass die Nachricht sicher ist" in v.spoken
    # English messages and English answers
    v = llm.check_scam("Hi mum, this is my new number. Can you transfer 900 pounds today?")
    assert v.level == "likely_scam" and "new_number" in v.patterns and "Don't pay" in v.spoken
    v = llm.check_scam("Your Royal Mail parcel is waiting, pay the customs fee: click the link")
    assert v.level in ("suspicious", "likely_scam")
    v = llm.check_scam("See you tomorrow at three?")
    assert v.level == "unclear" and "does not mean the message is safe" in v.spoken


def test_weather_tip():
    assert "glatt" in weather_tip(0, "rain", [], "de")
    assert "heiß" in weather_tip(31, "dry", [], "de")
    assert "keine Wetterwarnung" in weather_tip(15, "dry", [], "de")
    assert "icy" in weather_tip(0, "rain", []) and "hot" in weather_tip(31, "dry", [])


# ---------------------------------------------------------------- API

def test_api_flow():
    from app.main import app, notifier
    c = TestClient(app)
    assert c.get("/health").json()["ok"]
    r = c.put("/users/ilse/profile", json={"name": "Ilse", "modes": ["older"],
                                           "contacts": [{"name": "Anna", "phone": "+4915100000001"}]})
    assert r.status_code == 200
    assert c.put("/users/x/profile", json={"name": "X", "contacts": [{"name": "A", "phone": "0151"}]}).status_code == 422
    inc = c.post("/incidents", json={"user_id": "ilse", "trigger": "help_button",
                                     "location": {"lat": 48.15, "lon": 11.58}}).json()
    assert inc["state"] == "contacting"
    link = notifier.sent[-2].body.split("Live location: ")[1].split(" ")[0]   # profile has no language → English
    path = link.replace("http://localhost:8000", "")
    page = c.get(path)
    assert page.status_code == 200 and "openstreetmap" in page.text
    assert c.get(f"/live/{inc['id']}?t=wrong").status_code == 403
    tok = path.split("t=")[1]
    assert c.get(f"/live/{inc['id']}/ack", params={"t": tok, "name": "Anna"}).status_code == 200
    assert c.get(f"/incidents/{inc['id']}").json()["state"] == "contact_responding"
    assert c.post(f"/incidents/{inc['id']}/ok").json()["state"] == "resolved"
    assert "All clear" in c.get(path).text


# ---------------------------------------------------------------- guide

def test_lost_is_explicit():
    lad, n = make()
    inc = lad.start(user_id="u", person_name="Ilse", trigger=Trigger.lost, contacts=CONTACTS, now=T0, lang="de")
    assert inc.state == State.contacting and "verlaufen" in n.sent[0].body


def test_guide_prompt_keeps_safety_rules():
    from app import guide
    p = guide.prompt_for("sight", "de")["system_prompt"]
    assert "NIE, dass eine Straße sicher" in p and "Blindenstock" in p and "drei Versuchen" in p
    en = guide.prompt_for("sight", "en")
    p = en["system_prompt"]
    assert "NEVER say a street is safe" in p and "white cane" in p and "three tries" in p
    assert en["voice_language"] == "en-US"
    assert "low vision" in guide.prompt_for("low_vision", "en")["system_prompt"]
    names = {f["name"] for f in guide.TOOLS[0]["functionDeclarations"]}
    assert {"plan_route", "call_emergency_contact"} <= names


def test_direct_route_and_compass():
    from app.data import direct_route
    from app.guide import compass
    r = direct_route((48.15, 11.58), (48.16, 11.58), "de")  # ~1.1 km due north
    assert 1050 < r["distance_m"] < 1200 and "Norden" in r["steps"][0]["instruction"]
    assert "to the north" in direct_route((48.15, 11.58), (48.16, 11.58))["steps"][0]["instruction"]
    assert compass(95) == "Osten" and compass(350) == "Norden"


def test_api_guide_endpoints(monkeypatch):
    from app import data as _d
    import httpx as _h
    monkeypatch.setattr(_d, "valhalla_route", lambda *a, **k: (_ for _ in ()).throw(_h.ConnectError("offline")))
    from app.main import app
    c = TestClient(app)
    assert c.get("/guide/prompt?mode=sight").status_code == 200
    assert c.get("/guide/prompt?mode=xyz").status_code == 400
    r = c.get("/route", params={"from_lat": 48.15, "from_lon": 11.58, "to_lat": 48.16, "to_lon": 11.58})
    assert r.status_code == 200 and r.json()["direct"]


# ---------------------------------------------------------------- providers

def test_polyline6_decode():
    from app.data import decode_polyline6
    # Google's reference example, scaled to 6 decimals (Valhalla precision).
    pts = decode_polyline6("_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI")
    assert pts == [[-120.2, 38.5], [-120.95, 40.7], [-126.453, 43.252]]


def test_route_chain_falls_back_to_straight_line(monkeypatch):
    import dataclasses
    import httpx
    from app import data, main
    from app.main import app
    monkeypatch.setattr(main, "settings", dataclasses.replace(main.settings, ors_api_key=""))
    data.cache._d.clear()

    def boom(*a, **k):
        raise httpx.ConnectError("offline")
    monkeypatch.setattr(data.httpx, "post", boom)
    r = TestClient(app).get("/route", params={"from_lat": 48.15, "from_lon": 11.58, "to_lat": 48.16,
                                              "to_lon": 11.58, "profile": "blind"}).json()
    assert r["provider"] == "straight-line" and r["direct"] is True


def test_valhalla_parsing(monkeypatch):
    from app import data
    data.cache._d.clear()

    class Resp:
        def raise_for_status(self): pass
        def json(self):
            return {"trip": {"legs": [{"shape": "_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI",
                                       "summary": {"length": 0.25, "time": 200},
                                       "maneuvers": [{"instruction": "Walk north.", "length": 0.2, "begin_shape_index": 0},
                                                     {"instruction": "You have arrived.", "length": 0, "begin_shape_index": 2}]}]}}
    sent = {}
    monkeypatch.setattr(data.httpx, "post", lambda url, json, **k: sent.update(json) or Resp())
    r = data.valhalla_route((1.0, 2.0), (1.1, 2.1), "wheelchair", "en")["data"]
    assert sent["costing_options"]["pedestrian"]["type"] == "wheelchair" and sent["language"] == "en-US"
    assert r["distance_m"] == 250 and r["steps"][0]["instruction"] == "Walk north."
    assert r["steps"][1]["lat"] == 43.252 and r["provider"] == "valhalla"


def test_vision_without_keys_is_unavailable(monkeypatch):
    import dataclasses
    from app import llm
    monkeypatch.setattr(llm, "settings", dataclasses.replace(llm.settings, anthropic_api_key="", gemini_api_key=""))
    assert llm.providers() == []
    try:
        llm.ask("x", [{"type": "text", "text": "hi"}])
        raise AssertionError("should fail")
    except llm.LLMUnavailable:
        pass


# ---------------------------------------------------------------- crossings (Munich traffic lights)

LINE = [[11.5000, 48.1000], [11.5100, 48.1000]]          # ~744 m due east
LIGHTS = [
    {"name": "on route, sound", "lat": 48.10005, "lon": 11.5050, "signal": "sound"},     # ~6 m off, ~372 m along
    {"name": "on route, none", "lat": 48.0999, "lon": 11.5020, "signal": "none"},        # ~11 m off, ~149 m along
    {"name": "too far", "lat": 48.1010, "lon": 11.5050, "signal": "sound"},              # ~110 m off
]


def test_crossings_along_route_in_walking_order():
    from app import crossings
    cs = crossings.along_route(LINE, "en", LIGHTS)
    assert [c["name"] for c in cs] == ["on route, none", "on route, sound"]
    assert 140 < cs[0]["along_m"] < 160 and 360 < cs[1]["along_m"] < 385
    assert "sound and touch" in cs[1]["say"]
    assert "Ton- und Tastsignal" in crossings.along_route(LINE, "de", LIGHTS)[1]["say"]


def test_blind_choice_prefers_sound_signals_within_detour():
    from app import crossings
    plain = {"distance_m": 1000, "crossings": [{"signal": "none"}]}
    better = {"distance_m": 1100, "crossings": [{"signal": "sound"}]}
    too_long = {"distance_m": 1300, "crossings": [{"signal": "sound"}, {"signal": "sound"}]}
    assert crossings.best_for_blind([plain, better, too_long]) is better
    assert crossings.best_for_blind([plain]) is plain


def test_route_has_crossings_and_blind_picks_alternative(monkeypatch):
    from app import crossings, data, main
    main_route = {"distance_m": 744, "duration_s": 600, "steps": [], "geometry": LINE, "provider": "valhalla",
                  "alternatives": [{"distance_m": 800, "duration_s": 650, "steps": [], "provider": "valhalla",
                                    "geometry": [[11.5000, 48.10030], [11.5100, 48.10030]]}]}   # ~33 m north
    import copy
    monkeypatch.setattr(data, "valhalla_route", lambda *a, **k: {"data": copy.deepcopy(main_route), "age_s": 0, "stale": False})
    lights = [{"name": "sound on alt only", "lat": 48.10030, "lon": 11.5050, "signal": "sound"},   # 0 m alt, 33 m main
              {"name": "none on main only", "lat": 48.09995, "lon": 11.5020, "signal": "none"}]    # 6 m main, 39 m alt
    monkeypatch.setattr(crossings, "signals", lambda: {"data": lights})
    c = TestClient(main.app)
    q = {"from_lat": 48.1, "from_lon": 11.5, "to_lat": 48.1, "to_lon": 11.51}
    walk = c.get("/route", params=q | {"profile": "foot-walking"}).json()
    blind = c.get("/route", params=q | {"profile": "blind"}).json()
    assert walk["distance_m"] == 744                                  # walkers keep the shortest
    assert blind["distance_m"] == 800 and blind["alternatives_checked"] == 2
    assert any(x["signal"] == "sound" for x in blind["crossings"])


def test_departure_minutes_ignore_implausible_realtime():
    from app.data import with_minutes
    now = 1_000_000.0                                    # seconds
    deps = [
        {"line": "U3", "planned": (now + 300) * 1000, "realtime": (now - 86_000) * 1000},   # realtime a day off: use planned
        {"line": "S1", "planned": (now + 60) * 1000, "realtime": (now + 360) * 1000},       # delayed: use realtime
        {"line": "S2", "planned": (now - 120) * 1000, "realtime": None},                    # gone
        {"line": "S3", "planned": (now + 30) * 1000, "realtime": None, "cancelled": True},  # cancelled
    ]
    out = with_minutes(deps, now)
    assert [(d["line"], d["minutes"]) for d in out] == [("U3", 5), ("S1", 6)]


def test_guide_tools_declared():
    from app import guide
    names = {f["name"] for f in guide.TOOLS[0]["functionDeclarations"]}
    assert {"plan_route", "crossing_info", "next_departures", "where_is", "call_emergency_contact"} <= names
    assert "next_departures()" in guide.prompt_for("sight", "en")["system_prompt"]


# --------------------------------------------------------------------------- camera orientation

def test_orient_bearing_and_distance():
    from app import orient
    here = (48.1374, 11.5755)
    assert abs(orient.bearing(here, (48.1474, 11.5755)) - 0) < 0.5           # north
    assert abs(orient.bearing(here, (48.1374, 11.5855)) - 90) < 0.5          # east
    assert 1100 < orient.distance(here, (48.1474, 11.5755)) < 1120


def test_orient_parse_streets_shops_entrances():
    from app import orient
    here = (48.1374, 11.5755)
    elements = [
        # an east-west street 20 m north of the person
        {"type": "way", "tags": {"highway": "pedestrian", "name": "Kaufingerstraße"},
         "geometry": [{"lat": 48.13758, "lon": 11.5740}, {"lat": 48.13758, "lon": 11.5770}]},
        # the same street again, further away: one entry per name
        {"type": "way", "tags": {"highway": "pedestrian", "name": "Kaufingerstraße"},
         "geometry": [{"lat": 48.1390, "lon": 11.5740}, {"lat": 48.1390, "lon": 11.5770}]},
        {"type": "node", "lat": 48.1375, "lon": 11.5757, "tags": {"shop": "chemist", "name": "Rossmann"}},
        {"type": "node", "lat": 48.1372, "lon": 11.5755, "tags": {"railway": "subway_entrance"}},
        {"type": "node", "lat": 48.1380, "lon": 11.5760, "tags": {"amenity": "bench"}},          # no name: dropped
    ]
    out = orient.parse(elements, here, "en")
    names = [o["name"] for o in out]
    assert names.count("Kaufingerstraße") == 1 and "Rossmann" in names and "U-Bahn entrance" in names
    street = next(o for o in out if o["name"] == "Kaufingerstraße")
    assert 15 <= street["distance_m"] <= 25 and street["street_bearing"] in (89, 90, 91)
    assert next(o for o in out if o["name"] == "Rossmann")["kind"] == "drugstore"
    assert out == sorted(out, key=lambda o: o["distance_m"])
    assert next(o for o in orient.parse(elements, here, "de") if o["name"] == "Rossmann")["kind"] == "Drogerie"


def test_landmarks_endpoint(monkeypatch):
    from app import orient
    from app.main import app
    monkeypatch.setattr(orient.data.cache, "get", lambda key, ttl, fetch: {"data": [
        {"type": "node", "lat": 48.1375, "lon": 11.5757, "tags": {"shop": "bakery", "name": "Rischart"}}],
        "fetched_at": 0, "age_s": 0, "stale": False})
    r = TestClient(app).get("/landmarks", params={"lat": 48.1374, "lon": 11.5755})
    assert r.status_code == 200 and r.json()["data"][0]["kind"] == "bakery"


def test_describe_passes_map_places(monkeypatch):
    from app import guide
    seen = {}
    def fake_ask(system, content, max_tokens=0, task=""):
        seen["text"] = content[-1]["text"]
        return '{"spoken": "ok", "signs": []}'
    monkeypatch.setattr(guide, "ask", fake_ask)
    guide.describe("AAAA", None, 10.0, None, "en", nearby=["Rossmann (drugstore), 20 m ahead"])
    assert "Rossmann (drugstore), 20 m ahead" in seen["text"]


def test_access_summary_from_osm_tags():
    from app import orient
    here = (48.1374, 11.5755)
    els = [
        {"type": "node", "lat": 48.13742, "lon": 11.57552, "tags": {"amenity": "cafe", "name": "Café Glockenspiel",
                                                                   "wheelchair": "limited", "toilets:wheelchair": "yes"}},
        {"type": "node", "lat": 48.1376, "lon": 11.5755, "tags": {"highway": "elevator", "level": "-1;0"}},
        {"type": "node", "lat": 48.1375, "lon": 11.5756, "tags": {"entrance": "main", "wheelchair": "yes", "automatic_door": "yes"}},
        {"type": "node", "lat": 48.1380, "lon": 11.5760, "tags": {"amenity": "toilets", "wheelchair": "yes", "centralkey": "eurokey"}},
        {"type": "way", "tags": {"highway": "steps"}, "geometry": [{"lat": 48.1371, "lon": 11.5755}, {"lat": 48.1371, "lon": 11.5756}]},
        {"type": "node", "lat": 48.1373, "lon": 11.5754, "tags": {"kerb": "lowered"}},
    ]
    out = orient.summarize_access(els, here, "en")
    assert out["place"]["name"] == "Café Glockenspiel" and out["place"]["wheelchair"] == "limited"
    assert len(out["elevators"]) == 1 and out["lowered_kerbs"] == 1
    s = out["spoken"]
    assert "partly step-free" in s and "wheelchair toilet" in s and "1 lift nearby" in s
    assert "automatic door" in s and "Euro key" in s and "steps without a ramp" in s
    de = orient.summarize_access(els, here, "de")["spoken"]
    assert "teilweise stufenlos" in de and "Aufzug" in de


def test_access_unknown_is_not_accessible():
    from app import orient
    els = [{"type": "node", "lat": 48.13741, "lon": 11.57551, "tags": {"shop": "bakery", "name": "Rischart"}}]
    s = orient.summarize_access(els, (48.1374, 11.5755), "en")["spoken"]
    assert "nobody has entered" in s and "step-free." not in s.replace("whether it is step-free", "")
    assert "no accessibility information" in orient.summarize_access([], (48.1, 11.5), "en")["spoken"]


def test_osm_map_api_shaped_like_overpass():
    from app import orient
    raw = [
        {"type": "node", "id": 1, "lat": 48.1, "lon": 11.5},
        {"type": "node", "id": 2, "lat": 48.1, "lon": 11.501},
        {"type": "node", "id": 3, "lat": 48.1001, "lon": 11.5005, "tags": {"highway": "elevator"}},
        {"type": "way", "id": 9, "nodes": [1, 2], "tags": {"highway": "residential", "name": "Teststraße"}},
        {"type": "way", "id": 10, "nodes": [1, 2]},                     # untagged: geometry only
    ]
    els = orient.osm_to_elements(raw)
    assert [e["id"] for e in els] == [3, 9]
    assert els[1]["geometry"] == [{"lat": 48.1, "lon": 11.5}, {"lat": 48.1, "lon": 11.501}]
    assert orient.is_landmark(els[1]["tags"]) and not orient.is_landmark(els[0]["tags"])
