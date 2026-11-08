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
    assert names == {"plan_route", "call_emergency_contact"}


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
