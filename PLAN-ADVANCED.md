# Beistand – advanced plan

8 Nov 2026. Builds on "Beistand App Plan" (7 Nov) and `PROGRESS.md`. hackaTUM is 27–29 Nov, 19 days away.

## 1. Why it still feels basic

The app has many screens, but the "intelligent" parts are mostly switched off or shallow:

| Gap | Effect today |
|---|---|
| No API keys on the server | Read this, scam check and "Explain" fall back to plain text reading. The live camera guide runs in simple mode. |
| The camera looks once per tap | Nothing watches the street continuously. Nothing beeps when a bike comes close. |
| Live guide model name is out of date (`gemini-live-2.5-flash-preview`) | Current models are `gemini-3.8-live` and `gemini-3.1-flash-live-preview`. |
| Live sessions with camera stop after 2 minutes | The guide needs session resumption, or it goes silent mid-walk. |
| Position is plain phone GPS (5–15 m in the city) | Too coarse to say "the crossing is 3 steps ahead, on your left". |
| The map only knows streets | It doesn't know where crossings with sound signals, kerbs, tactile paving, broken lifts or parked scooters are. |
| Many plan features are unbuilt | Obstacle beeps, transport helper, lift rerouting, sound alerts, counter mode, way home, day anchor and others. |

The plan below fixes this in three layers: **perception** (what the camera and microphone understand), **position** (where exactly the person is), and **map** (what is around them that matters for their disability).

## 2. Perception: live camera recognition in three speeds

One pipeline, three speeds. The fast layer protects, the middle layer understands, the slow layer reads carefully.

```
Camera 30 fps ─┬─► L1 on-device, every frame (<100 ms) ──► alarms: beeps, vibration, "stop"
LiDAR depth   ─┤        objects, distance, text, signs
Microphone   ──┤                │ events as text: "[CONTEXT] bike 3 m, left, approaching"
               ├─► L2 Gemini Live, 1 frame/s + voice ──► conversation, guidance, questions
               └─► L3 Claude Opus 5.5, one frozen frame ──► careful reading and explaining
```

### L1 – on device, every frame (new, biggest change)

| Feature | How | APIs | Effort |
|---|---|---|---|
| Obstacle beeps | LiDAR depth in a centre corridor, ignore the ground plane, beep faster as distance shrinks (2 m → 0.5 m). Fallback on phones without LiDAR: on-device depth model, marked "less reliable". | ARKit `sceneDepth`, Core Haptics, AVAudioEngine | M |
| Object detector | Detect person, bicycle, e-scooter, car, bus, tram, pole, bollard, bench, stairs, door, traffic light, crosswalk. Track each object between frames, estimate distance from LiDAR and speed from the change. Warn only for things in the walking path or moving towards it. | Core ML with a YOLO-class model (exported to Core ML, Neural Engine), Vision `VNCoreMLRequest`, ARKit depth | L |
| Live text | Read signs, platform numbers, line numbers, shop names and labels continuously; say them only when they matter (the destination, the line the person waits for). | Vision `VNRecognizeTextRequest` on frames, DataScanner (VisionKit) | M |
| Traffic light state | Detect the pedestrian signal and its colour, and say what it shows. **Never say "safe to cross"**: say "the light shows green" and add "listen to the traffic". | Detector + colour check in the light's box | M |
| Sound alerts | Sirens, horns, doorbell, fire alarm, a crying baby, a voice calling the person's name → watch pattern + screen colour. | SoundAnalysis (built-in classifier), custom recordings for the own doorbell | S |
| Scene memory | Remember what was recognised in the last minute ("you passed a bakery 20 m ago"), for questions like "where was the bench?". | Rolling buffer of L1 events with position | S |

Rules: L1 alarms always win over speech (a "stop" interrupts the guide). Everything L1 says is short and fixed, never generated text. Works offline.

### L2 – Gemini Live, the conversational guide

| Change | How | Effort |
|---|---|---|
| Current model | `GEMINI_LIVE_MODEL=gemini-3.8-live` (check on the Models page on the day) | S |
| Sessions longer than 2 minutes | Session resumption: keep the resumption handle, reconnect before the limit, send the latest context again. | M |
| Grounded by L1 | Every second, send L1 events and the route state as `[CONTEXT]` text, so the model reasons about measured distances instead of guessing them from a 1 fps picture. | S |
| Better frames | 768×768 frames, sharpest of the last second (least motion blur), not just the latest. | S |
| Tools | Add `where_is(thing)` (search scene memory and nearby places), `next_departures(stop)`, `crossing_info()` (is there a sound signal here?), alongside `plan_route` and `call_emergency_contact`. | M |

### L3 – one careful look

Claude Opus 5.5 for letters, packaging, forms, expiry dates and "what is this?" (already built; needs `ANTHROPIC_API_KEY`). Add: send the sharpest frame plus the L1 text result, so the model can check the on-device reading.

## 3. Position: as exact as possible ("military-grade" without the military)

Military map and positioning services are not open to the public. Galileo's encrypted service (PRS) is for governments only. But the same techniques have civilian versions, several of them free:

| Option | Accuracy | Cost and access | Fits an iPhone? | Plan |
|---|---|---|---|---|
| Phone GPS today | 5–15 m in streets | free | yes | baseline |
| **Map matching + step counting** (software) | 2–4 m along a pavement | free | yes | **do first**: snap position to the pavement graph, fill gaps between GPS fixes with steps and heading (CoreMotion pedometer, compass), Kalman filter. No hardware. |
| **Apple geo tracking** (camera matches Apple's street imagery) | ~1 m and exact heading | free | yes, iPhone XS or newer | Check `ARGeoTrackingConfiguration.checkAvailability` at Munich's coordinates on the phone. If available, it becomes the best source while the camera guide runs. Coverage outside the US is limited, so it's a bonus, not a dependency. |
| **SAPOS HEPS** (Bavarian survey corrections, NTRIP) | 1–2 cm | about €20/year administration fee in Bavaria; registration with the LDBV | **no**: needs an external RTK receiver | Optional "precision kit": a Bluetooth RTK receiver (u-blox ZED-F9P class, ~€200–300) clipped to a bag strap; the app streams SAPOS corrections to it. Great demo, not for every user. |
| **Galileo HAS** (free EU corrections) | ~20 cm under ideal conditions | free | not through iOS today | Same external receiver can use it where SAPOS isn't available. |

Order of work: map matching first (helps everyone, no hardware), then geo tracking check, then the optional RTK kit if a team member owns or borrows a receiver.

## 4. Map: an accessibility layer for Munich

Today routes come from Valhalla on plain OpenStreetMap. The upgrade is our own Munich routing graph that knows what matters per disability.

| Data | What it adds | Source | Licence |
|---|---|---|---|
| **Traffic lights with signals for blind people** | 1,186 lights; **683 tactile + acoustic**, **244 tactile only** (checked 8 Nov). Routes for blind users prefer these crossings; the guide says "crossing with a sound signal ahead". | Munich open data `lsa_opendata` (WFS, GeoJSON, field `zeb`) | dl-de/by-2.0 |
| Pavements, crossings, kerbs, tactile paving, steps, surface, incline | Step-free and kerb-aware routing; "kerb is lowered here" | OpenStreetMap (Overpass) | ODbL |
| Zebra crossings, signs, streetlights seen in photos | Fills OSM gaps; lit routes at night | Mapillary API (map features, detections) | CC BY-SA |
| 3D buildings (LoD2) | "the building on your left", predicting where GPS will be poor (narrow streets) | Bavarian open geodata (LDBV) | CC BY 4.0 |
| 20 cm aerial photos (DOP20, WMS) | High-contrast map for low vision; VLM checks of crossings from above | `geoservices.bayern.de/od/wms/dop/v1/dop20` | CC BY 4.0 |
| Lift status at stations | Reroute around broken lifts, say how old the status is | DB FaSta (key), MVG | per terms |
| Live departures, stops | Transport helper | MVG (unofficial), MVV GTFS | CC BY / terms |
| Parked scooters and bikes | "Scooter on the pavement in 20 m" | GBFS feeds (check Munich coverage) | per operator |
| Noise maps | Quiet routes for calm mode | Bavarian LfU | free |
| Step-free entrances, accessible toilets | Destination details | accessibility.cloud, Wheelmap | token |

How:

1. A nightly job downloads these into PostGIS and joins them to OSM pavement and crossing points.
2. We host our own Valhalla with a Munich extract, with the extra tags written into the OSM data before the graph is built. That allows custom costs: blind = strongly prefer acoustic crossings, wheelchair = no steps and kerbs under 3 cm, calm = avoid noisy streets.
3. The route response gets "hazards and helpers along the way", like a crossing with sound in 40 m, a broken lift at Odeonsplatz, or a bench in 120 m. The guide announces them at the right moment.

Effort: L for the whole graph; the traffic-light layer alone is S and is the best first step.

## 5. Features by mode

Priority: **H** = for hackaTUM, **N** = next (December), **L** = later.

### Sight and low vision
| Feature | Priority | Notes |
|---|---|---|
| Obstacle beeps (LiDAR) | H | biggest "wow" for blind users |
| Object detector + warnings | H | scooters, bikes, poles, people |
| Live guide on Gemini 3.8 with session resumption | H | grounded by L1 events |
| Acoustic-crossing routing and announcements | H | Munich traffic-light data |
| Map matching + step counting | N | better position for everyone |
| Transport helper (reads line and destination from the camera, confirms "it's yours") | N | MVG departures + live text |
| Lift rerouting | N | DB FaSta key |
| Scooter warning | N | GBFS |
| Apple geo tracking where available | N | runtime check |
| Colour names, yellow-on-black theme | N | low vision |
| RTK precision kit | L | optional hardware |

### Hearing
| Feature | Priority | Notes |
|---|---|---|
| Sound alerts on the watch | H | SoundAnalysis |
| Counter mode (split screen, both directions, with translation) | H | reuses captions + translation |
| Speaker colours in captions | N | turn-taking by voice pause and loudness |
| Type to speak, Personal Voice | N | |
| Station announcements to text | L | captions + departures check |

### Older people and dementia
| Feature | Priority | Notes |
|---|---|---|
| Morning check-in | N | |
| Medicine taps (phone + watch) | N | |
| Easy walks with benches and toilets | N | Overpass benches already in the cache |
| Day anchor, found card, way home | N | dementia mode start |

### Wheelchair, calm, speech, easy reading
| Feature | Priority | Notes |
|---|---|---|
| Kerb-aware routes and live lifts | N | own Valhalla graph |
| Barrier report (photo → VLM → map) | L | |
| Quiet routes (noise map) | L | |
| Picture board, scene suggestions | L | ARASAAC + VLM |
| Form helper | L | |

### Safety layer
| Feature | Priority | Notes |
|---|---|---|
| Watch fall detection in the background (workout session) | N | today it works only while the watch app is open |
| Twilio live with keys, public URL for the contact page | H | needs keys and a tunnel |
| Supabase accounts and family view | N | |

## 6. Making it testable

Every new feature ships with three things: a unit test for the logic, a Diagnostics entry with a Test button, and a recorded test case.

| Tool | What it does |
|---|---|
| **Test walks** | Record a real walk once (video, LiDAR depth, GPS, motion) to a file. Replay it in the simulator or on the Mac, so detector, warnings, map matching and guide prompts can be tested again and again without going outside. |
| **Detector test set** | 200 Munich street photos with marked scooters, bikes, poles and crossings. A script reports how many each model version finds and misses. |
| **Route checks** | Fixed routes (Marienplatz → Odeonsplatz, a station with a lift) with expected hazards; the backend test fails if a crossing or lift warning disappears. |
| **Diagnostics** | Add rows for LiDAR, detector speed (frames per second), geo-tracking availability, RTK status, Live session age and reconnects. |
| **Field tests** | One blind, one deaf and one older tester before the pitch (for example through BBSB, the Bavarian association for blind and partially sighted people, and a senior centre). |

## 7. Schedule to hackaTUM

| When | Work |
|---|---|
| 9–12 Nov | Keys (Anthropic, Gemini, Twilio, DB FaSta). Live guide on `gemini-3.8-live` with session resumption. Traffic-light layer and acoustic-crossing announcements. |
| 13–17 Nov | L1: LiDAR obstacle beeps, then the object detector with tracking. Test-walk recorder and replay. |
| 18–21 Nov | L1 → L2 grounding, new guide tools, sound alerts on the watch, counter mode. |
| 22–24 Nov | Map matching + step counting. Geo-tracking check in Munich. Field tests with users. |
| 25–26 Nov | Fix what testers found. Freeze features. Rehearse the demo. |
| 27–29 Nov | hackaTUM: polish, the demo story, submission before Sunday 10:00. |

Demo story addition: a blind tester walks to a crossing, the phone beeps at a parked scooter, says "crossing with a sound signal ahead, the light shows red", and the guide answers "where is the U-Bahn entrance?".

## 8. Rules that stay

- Never say a street is safe to cross. Describe; the person decides.
- Cane and guide dog stay primary.
- No automatic 112 call.
- Live video goes only to the guide or a chosen contact; nothing stored without consent.
- L1 warnings are fixed phrases, tested; generated text never replaces a warning.
- Show the age of every live data item (lifts, scooters, departures).
- Not a medical device, not a safety certification.

## 9. Open questions

1. Who on the team owns which layer (perception, position, map, modes)?
2. Is an iPhone Pro with LiDAR available for every developer, or only one?
3. Budget for an RTK receiver and API usage during the event?
4. Which sponsor track at hackaTUM? Some tracks favour maps, others AI or health.

## Sources

- SAPOS in Bavaria: [access information (LDBV)](https://www.ldbv.bayern.de/mam/ldbv/dateien/sapos_zugangsinformationen.pdf), [fees discussion (OSM forum)](https://community.openstreetmap.org/t/sapos-dienste-in-bayern-jetzt-fast-kostenfrei/115445)
- Galileo HAS: [EU Space](https://eu-space.europa.eu/satellite-navigation/galileo/high-accuracy-service-has), [smartphone PPP study (TU Wien)](https://repositum.tuwien.at/bitstream/20.500.12708/206047/1/Wareyka-Glaner-2024-Smartphone%20PPP%20with%20the%20Galileo%20High%20Accuracy%20Service-vor.pdf)
- Apple geo tracking: [ARGeoTrackingConfiguration](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration), [WWDC21 session](https://developer.apple.com/videos/play/wwdc2021/10073/)
- Bavarian geodata: [DOP20 WMS and LoD2 notes (Bayern planning guide)](https://www.digitale.planung.bayern.de/medien/dokumente/hilfestellung_für_den_einsatz_von_geodaten.pdf), [LoD2 catalogue (TUM)](https://catalog.savenow.gis.lrg.tum.de/dataset/activity/3d-gebaudemodelle-lod2)
- Munich traffic lights: [opendata.muenchen.de lsa_opendata](https://opendata.muenchen.de/dataset/lsa_opendata)
- Mapillary: [API FAQ](https://www.mapillary.com/developer/api-documentation/faq), [object detections](https://help.mapillary.com/hc/en-us/articles/360003021312-Exploring-object-detections), [Munich walkability use (plan4better)](https://www.plan4better.de/en/post/high-quality-data-now-automatic)
- Gemini Live: [capabilities and limits](https://aistudio.google.com/docs/live-api/capabilities), [Firebase limits](https://firebase.google.com/docs/ai-logic/live-api/limits-and-specs)
