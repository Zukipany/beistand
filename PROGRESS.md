# Beistand – progress log

Read this first when resuming. The full product plan is "Beistand App Plan" (7 Nov 2026).
Target: hackaTUM 27–29 Nov 2026 – older people mode + safety layer fully, sight mode "I'm lost" as second mode.

## Layout
- `backend/` FastAPI. `uvicorn app.main:app --reload --port 8000`. Tests: `.venv/bin/python -m pytest -q` (21 passing). Run the server with `.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload` (own environment in `backend/.venv`; create with `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`).
  - `app/ladder.py` help ladder state machine (asking → contacting → contact_responding / emergency_confirmed → resolved). Time is injected; `tick()` runs every second.
  - `app/notifier.py` Twilio calls/SMS, or dry-run log when keys are missing (`GET /outbox` shows what would be sent).
  - `app/llm.py` Read this (Claude vision → Leichte Sprache JSON) and Scam check (Claude + offline regex rules; never says "safe").
  - `app/data.py` cache with `age_s`/`stale`: Bright Sky weather + tip, MVG stations/departures, DB FaSta lifts, Overpass places, ORS routes.
  - `app/main.py` endpoints, `/live/{id}?t=` contact page, `/gemini/token` ephemeral Live token.
  - `.env.example` – every key optional.
- `supabase/schema.sql` profiles, modes, contacts, consents, events, medicines, doses + RLS (family sees only consented event kinds).
- `ios/` SwiftUI app, generated with XcodeGen (`cd ios && xcodegen generate`). iOS 18+, Swift 5 mode. Builds clean.
  - Onboarding (spoken questions, voice or tap, silence on "can you read this" → sight mode), 4-button home, Read this, Scam check, family settings behind PIN (default 0000) with demo toggles.
  - Safety: `FallPattern` (free fall → impact → 10 s still), `MotionMonitor` 50 Hz, `DropFinder` (rising tone, "Ich bin hier", torch ≤1 Hz, steady in seizure mode), `SafetyService` drives backend ladder, `IncidentViews` (countdown, bystander card, 112/nora).
  - App Intents: Hilfe, Wo bin ich, Telefon finden (for Action Button / Siri).

## Verified (8 Nov 2026)
- Backend tests pass; live Bright Sky, MVG (Marienplatz departures) and Overpass calls work.
- Fall → 30 s countdown → SMS + call to first contact, verified over HTTP against a running server.
- Fall-pattern logic: fall detected; pickup and walking not detected.
- Simulator tap-through on a dedicated simulator "Beistand Test" (iPhone 17 Pro, iOS 27):
  sign-up (name, 7 questions, contact) → home; weather tip; Wo bin ich (reverse geocode); Scam check;
  Help → contact alerted → "Mir geht es gut" → all-clear SMS; simulated fall → 30 s countdown → contact alerted;
  "Notruf 112 nötig" screen → cancel; app killed mid-alert → alert resumes on relaunch; phone finder screen opens/closes.
- Fixed in that pass: launch freeze (AVSpeechSynthesisVoice lookup blocked main thread → Speaker now on its own queue,
  with a timeout fallback so listening still starts), see-through alert screen, "in der …-Platz" wording,
  home buttons jumping / weather tip truncated, scam answer hidden by keyboard, overlapping question cross-fade,
  no way to cancel from the 112 screen, open alert lost after app restart, raw mode ids in settings.

## Not done yet / next steps
1. On a real iPhone: speech output and voice answers (simulator TTS is unreliable), finder tone + torch, real drop/fall motion.
   Read this needs ANTHROPIC_API_KEY and a camera.
2. Get keys (Anthropic, Gemini, Twilio, ORS, DB API Marketplace) into `backend/.env`; test Read this with a real letter.
3. Supabase: create project, run schema, swap in-memory `profiles` and incidents for tables.
4. Watch app — built (8 Nov 2026), see "Watch, languages, accessibility" below. Not run: no watchOS simulator runtime installed.
5. Sight mode "I'm lost" — built and simulator-tested (8 Nov 2026), Gemini Live never run (no key):
   - Backend `app/guide.py`: `/guide/prompt` (safety rules + plan_route / call_emergency_contact tools), `/geocode`
     (Nominatim), `/describe` (Claude one-photo fallback), `/route` straight-line fallback without ORS key. 14 tests.
   - iOS `Beistand/Guide/`: RouteFollower, LiveProtocol, LiveMedia (mic/speaker/camera/WebSocket), GuideController
     (@MainActor; Live or simple mode), ImLostView (newest caption on top). Entry points: orange "Ich habe mich verlaufen"
     button on home in sight/low-vision mode, App Intent "Ich habe mich verlaufen", settings demo button.
     Debug launch hook: `xcrun simctl launch <dev> app.beistand.ios -openGuide YES -guideDestination Odeonsplatz`.
   - Unit tests: `BeistandTests` (8: geometry, route following, off-route, Live messages). Run with xcodebuild test.
   - Simulator walks (`xcrun simctl location … start`): straight walk → max 2.7 m off, one "arrived";
     60 m detour → off-route at 31 m, one re-plan, new direction spoken. NOTE: give simctl many waypoints;
     with two far points it walks a curve and the app (correctly) reports off-route.
   - Fixed while testing: false contact offer (misses counted per GPS fix, now per re-plan), AI-facing text spoken to user
     in simple mode, captions not updating after background re-plan, wrapped half-width buttons, duplicate summary.
   Still open: real iPhone + GEMINI_API_KEY (Live audio/video/tools, echo cancellation, gemini model name in config),
   real camera for "Was ist vor mir?" (needs ANTHROPIC_API_KEY), voice destination input on device, watch haptics.
6. Lift rerouting on routes (ORS + FaSta), easy walks with benches/toilets, morning check-in, medicine taps.
7. Public URL (tunnel) for `PUBLIC_BASE_URL` so contacts can open the live page during the demo.

## Watch, languages, accessibility (8 Nov 2026, second pass)
- Run on the real iPhone (an iPhone 16 Pro, iOS 27.0.1; use your own device UDID and team ID):
  `xcodebuild -project ios/Beistand.xcodeproj -scheme Beistand -destination 'id=<device-udid>' -derivedDataPath ios/build-device -allowProvisioningUpdates DEVELOPMENT_TEAM=<team-id> build`
  then `xcrun devicectl device install app --device <udid> ios/build-device/Build/Products/Debug-iphoneos/Beistand.app` and
  `xcrun devicectl device process launch --device <udid> --terminate-existing app.beistand.ios -backendURL http://<mac-ip>:8000`
  (the app remembers -backendURL). Server must listen on the network: `uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload`.
- Watch app `ios/BeistandWatch/` (watchOS 11, embedded in the iPhone app) + `ios/Shared/` (compiled into both):
  `WatchMessage`/`WatchState` (plist dicts), `WristFallPattern` (hit > 3 g, arm still 10 s → fall; moving/clapping → no fall),
  hold-1-s Help button, "Are you OK?" + "I'm OK" on the wrist, haptics (left 2 taps, right 3, arrived success, asking repeats),
  offline fallback (call contact / 112 from the wrist). Phone side `Safety/WatchLink.swift`: wrist hit confirms a phone fall pattern
  (drop vs fall), wrist fall alone starts the ladder, incident state → watch via application context, guide cues → watch.
  Settings demo button "Simulate a wrist fall (watch)". Tested on a paired watch simulator "Beistand Watch" (Apple Watch SE 3, watchOS 27)
  paired with "Beistand Test": phone Help → watch "Help is coming. Calling Anna."; watch I'm OK → phone alert cancelled; watch wrist
  fall → impact + fall → phone and watch "Are you OK?" countdown. Fix needed for that: `WatchAppDelegate` (WKApplicationDelegateAdaptor)
  starts WCSession at launch and completes WC background tasks. Watch test hook: `xcrun simctl launch <watch> app.beistand.ios.watchkitapp -watchAction ok|help|fall`.
  Install: `xcrun simctl install <watch> ios/build/Build/Products/Debug-watchsimulator/BeistandWatch.app`. Logs: subsystem app.beistand.watch / category watch (use `log show --info`).
  Watch accelerometer only runs while the watch app is open; real background needs a workout/extended-runtime session.
- Language: English by default, German when the phone is German. `Shared/Lang.swift` → `tr("English", "Deutsch")`, `Lang.code`,
  `Lang.speech` (voices + recognition), `-lang de` launch arg to force. App sends `lang` to every server call; server `app/lang.py`
  (guide prompts in both languages, scam rules match English + German scams, weather tip, routes, SMS/call to the contact in the
  person's language, contact live page). Permission texts: English in project.yml, German in `de.lproj/InfoPlist.strings`.
  Yes/no now matches whole words ("know" ≠ "no").
- iPhone accessibility settings are read on sign-up (`Core/SystemAccessibility.swift`): VoiceOver → sight, very large text /
  inverted colours → low vision, captions / mono audio → hearing, Switch Control / AssistiveTouch → tremor. Those questions are
  skipped; turning a setting on later adds the mode once (on app activation). Simulator-verified with extra-large text.
- Text size + contrast: big texts use `scaledFont` (follow Dynamic Type, capped), BigButton stacks icon over text at accessibility
  sizes, alert + sign-up screens scroll when needed (`FitScroll`), button colours darkened to ≥ 4.5:1 with white (`A11yColor`),
  Increase Contrast adds outlines. Checked in the simulator at the largest size with Increase Contrast.
- Volume (`Core/Volume.swift`): yellow "Your phone is quiet" banner on sign-up, home, alert and guide screens while volume < 50 %
  (not in hearing mode); the "Can you hear this tone?" question waits for the volume. Test hook `-fakeVolume 0.2`.
- Read this: phone text recognition (Apple Vision, offline, no key) as fallback, finds amount + date; `ReadAloudText` highlights each
  word as it is spoken; "Choose a picture" for screenshots. With ANTHROPIC_API_KEY the server's simple-words version wins.
- Magnifier (low-vision home button, `Features/Magnifier.swift`): live camera with real zoom (pinch, +/−), light, colours
  (normal / high contrast / inverted), freeze, "Explain" → `/describe` purpose=magnify, else on-device text reading.
  Simulator shows a test label picture (`-openMagnifier YES`); verified zoom, colours, Explain → read aloud with highlighting.
- Tests: 22 app tests (watch messages, wrist fall, accessibility hints, languages, yes/no, text extraction) + 14 backend.
- Still open: watch on a real watch/sim; magnifier + Read this with a real camera; speech + highlighting timing on the device.
- Testing modes: Settings (PIN 0000) → "Try the app as …" one-tap profiles (Older person, Blind, Low vision, Deaf, Memory, Wheelchair,
  Seizures, Deafblind) and a switch per mode. Home buttons follow the modes (Blind → I'm lost; Low vision → Magnifier; Deaf → Live captions).
- Live captions (hearing/deafblind, `Features/LiveCaptions.swift`): on-device speech recognition of the surroundings; each word sized and
  weighted by how loud it was said (mic dBFS averaged over the word's timing, 18–60 pt), meter "≈ 68 dB · normal voice", red "Loud sound
  nearby" banner + vibration for loud sounds, new line after a 1.5 s pause. Simulator demo `-demoCaptions YES` (scripted voices) verified;
  real microphone not yet tried on the iPhone. Loudness mapping unit-tested.

## Better engines + Diagnostics (8 Nov 2026, third pass)
- Routes: free OpenStreetMap Valhalla server (no key; `VALHALLA_URL`), profiles foot-walking (steps penalised), wheelchair,
  blind (landmark-style instructions; used automatically in sight mode), English/German instructions. Chain:
  OpenRouteService (if ORS_API_KEY) → Valhalla → straight line. Response has `provider`. Live-checked Marienplatz → Odeonsplatz.
- Vision: `app/llm.py` `ask()` now uses the official Anthropic SDK (`anthropic` in requirements) with `claude-opus-5-5`
  (ANTHROPIC_MODEL), effort medium for letters/scams, low for camera questions, `fallbacks: "default"` (server-side refusal
  fallback). Gemini (`GEMINI_VISION_MODEL`, default gemini-2.5-flash, unverified name) when only a Gemini key exists; else the
  app reads text on the phone. /health lists `vision` and `routes`. Not run with real keys yet.
- Speech to text: `Core/ModernSpeech.swift` uses SpeechAnalyzer/SpeechTranscriber (iOS 26+, on device, exact word timing;
  model downloads once) in Live captions, falling back to SFSpeechRecognizer (the simulator only has the old one).
  Onboarding/guide short answers still use `Listener` (SFSpeech).
- Translation: Live captions "They speak: …" (14 languages); lines are translated on the phone into the app language
  (Translation framework, `TranslationSession(installedSource:)`, iOS 26), with a one-time language-pack download button.
  Not available in the simulator; needs the iPhone.
- Diagnostics (Settings → Diagnostics, or `-openDiagnostics YES`): server, contact messages mode, vision chain, Live guide,
  router, speech engine, translation, watch; test buttons: sample label (server model or on-phone), route with your profile,
  scam sample, voice, watch tap. Simulator-verified: label read on phone, Valhalla route, scam/voice buttons present.
- Tests: 18 backend (polyline6, Valhalla parsing, route fallback chain, no-key vision) + app tests incl. word timing,
  line loudness, speaker languages. All pass.
- Installed on the iPhone (8 Nov 2026) with -backendURL http://<mac-ip>:8000 (Mac address changes with the network: relaunch with the new one, or set it in Settings → Server).

## Week one of PLAN-ADVANCED.md (8 Nov 2026)
- Live guide: model `gemini-3.8-live` (config default), token from `v1beta/auth_tokens`. Session resumption: setup sends
  `sessionResumption` (+ handle when resuming) and `contextWindowCompression.slidingWindow`; the app keeps the latest
  `sessionResumptionUpdate.newHandle`, reconnects on `goAway` or an unexpected close with the same token, and only falls back to
  simple mode after 5 failed reconnects in a row (`ResumePolicy`). `LiveClient` ignores events from replaced connections.
  Not run against Gemini yet (no key).
- Munich traffic-light layer (`backend/app/crossings.py`): city open data `lsa_opendata` (1,160 active lights: field `zeb`
  TA = sound + touch, T = touch only), cached daily. Every `/route` lists `crossings` within 15 m with `along_m` and a spoken
  sentence; blind profile asks Valhalla for alternatives and picks the most sound-signal crossings within +15 % length
  (`alternatives_checked`). `/crossings?lat&lon` for the nearest lights. Guide tool `crossing_info()` (prompt + app).
  App: `RouteFollower` announces each crossing once ~25 m before it (`.crossing`), one haptic pulse; live mode tells the
  guide to say it without judging safety. Diagnostics: route test Sendlinger Tor → Hauptbahnhof shows crossings,
  "Traffic lights near Hauptbahnhof" test, Live reconnect count.
- Keys still missing: see `backend/.env.example` (where to get each key).

## Week two of PLAN-ADVANCED.md: fast on-phone layer (8 Nov 2026)
- `Guide/GuideCamera.swift`: on LiDAR phones the guide camera is ARKit (sceneDepth + horizontal planes): JPEG 1/s for
  Gemini/describe, obstacle lanes ~10/s, objects ~2/s. Other phones: the old `CameraFeed`, no depth. Preview: ARSCNView.
- `Guide/Obstacles.swift`: `ObstacleGeometry` (depth pixels → world points → left/ahead/right lanes in the walking direction,
  0.8 m corridor, ignores ground < 15 cm and overhead > 2 m; floor from ARKit's lowest plane, else phone − 1.3 m),
  `BeepTiming` (silent > 2 m, 0.7 s … 0.1 s at ≤ 0.5 m), `Beeper` (1.4 kHz click + haptic; haptic only in hearing modes),
  `ObjectAlerts` (fixed phrases, things ahead first, 4 m range, people only < 1.5 m, 8 s no-repeat, 2 s gap).
  Objects: Apple Vision human detector + objectness boxes, labelled by `VNClassifyImageRequest` (no licence issues;
  YOLO models are AGPL), distance from LiDAR at the box centre.
- Guide: warnings interrupt Gemini audio, are captioned and sent to Gemini as `[CONTEXT]` (respond false).
  Three-bar indicator at the top of "I'm lost". Setting: "Obstacle beeps and warnings in the camera guide" (default on).
- `Core/WalkRecorder.swift`: Diagnostics → "Record test walks" writes walks/*.jsonl (fixes, lanes, objects, spoken
  warnings); share from Diagnostics; `WalkRecorder.read` + `testReplayRecordedWalk` replay them.
- Verified: unit tests (geometry, unprojection, beep timing, alert order, label mapping, replay), simulator fallback path.
  NOT verified: anything with real LiDAR/camera (simulator has none) — needs the iPhone 16 Pro: depth orientation, box →
  depth mapping (`u = 1 − midY, v = 1 − midX` for portrait), classifier labels outdoors, beep feel.

## Hearing tools and smarter guide (9 Nov 2026, PLAN-ADVANCED 18–21 Nov block)
- Sound alerts: `Shared/SoundKind.swift` (8 kinds, thresholds, urgency, `SoundAlertPolicy` with 8 s no-repeat),
  `Core/SoundAlerts.swift` (`SoundClassifier` on Apple's built-in classifier, haptic patterns, `SoundWatcher`),
  `Features/SoundAlertsView.swift` (big card, slow pulse ≤ 1/s, steady in seizure mode). Live captions feed the same
  classifier from their own microphone tap and show a named banner. Watch: `WatchMessage.sound` → full-screen card + haptics.
- Counter mode: `Features/CounterModeView.swift`; staff half rotated 180°, quick phrases, staff language menu,
  Translation sessions both ways when installed; `Speaker.say(…, language:)`.
- Guide tools `next_departures` (MVG /stations + /departures; backend `with_minutes` ignores realtime > 3 h off planned,
  drops past/cancelled) and `where_is` (`SceneMemory`, 3 min, one entry per thing per 10 s). Simple mode: "Next departures" button.
- L1 grounding: periodic live context now includes LiDAR lane distances.
- Debug hooks: `-openSounds YES [-testSound siren]`, `-openCounter YES`.
- Verified: backend tests (23), app unit tests, simulator: siren card, counter mode layout, live departures at Marienplatz.
  NOT verified: real sounds on the iPhone, translation on device, watch sound card on a real watch.
