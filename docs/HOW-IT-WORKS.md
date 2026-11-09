# How Beistand works

The detailed companion to the [README](../README.md): a day with the app, how each part works, the
backend API, running on devices, testing hooks and troubleshooting.

- [A day with Beistand](#a-day-with-beistand)
- [How each part works](#how-each-part-works)
- [Backend API](#backend-api)
- [Running on devices](#running-on-devices)
- [Testing hooks](#testing-hooks)
- [Troubleshooting](#troubleshooting)

---

## A day with Beistand

This follows the demo story from the plan. Each step says what the person does, what the app does, and which code does it.

### Signing up (Maria, 78, has trouble reading small print)

1. Maria opens the app. It speaks at once: *"Welcome to Beistand. I can see: very large text is on. I'll set the app up to match. … What is your name?"* She says "Maria" or types it.
   *Code:* `Features/OnboardingView.swift`, `Core/SystemAccessibility.swift` (reads VoiceOver, text size, captions, mono audio, Switch Control, AssistiveTouch).
2. The question "Can you read this text?" is skipped, because her iPhone settings already answered it (low-vision mode is on). The counter says "Question 1 of 6".
3. "Can you hear this tone?" waits until the volume is at least half, so a quiet phone isn't mistaken for hearing loss. A yellow banner says *"Your phone is quiet. Press the volume-up button on the left side."* (`Core/Volume.swift`).
4. She answers the other questions by voice ("yes", "no"; whole words only, so "I know" is not "no") or by tapping. Silence on the reading question would have meant blind mode.
5. Her daughter Anna types her own number as the emergency contact.
   The profile is saved on the phone and sent to the server (`PUT /users/{id}/profile`).

### The home screen

Four big buttons, at least 88 points tall, that grow with the iPhone's text size; at the largest sizes the icon moves above the words. Button colours are dark enough for white text (at least 4.5:1); with Increase Contrast they get an outline. A long press reads out what a button does. Taps within 0.8 s of each other are ignored (tremor).

Above the buttons: the day's weather tip (*"It may be icy today. Wear sturdy shoes or wait until midday."*), from official DWD warnings.

### A letter arrives

Maria taps **Read this** and photographs the letter.

- **With a vision-model key:** the server sends the photo to the cloud vision model with a prompt that asks for Easy Language, the action and the deadline first, and a scam warning when something looks wrong. The answer comes back as JSON (sender, what they want, amount, deadline, spoken text). Code: `backend/app/llm.py` → `read_letter`.
- **Without a key, or offline:** the phone reads the text itself with Apple Vision, finds the first amount and date, and reads everything out. Code: `Features/ReadAloud.swift` → `OnDeviceReader`.

Either way, the text is shown large and **each word is highlighted as it is spoken**, and one button sends it to Anna by SMS.

### A strange message

*"Hi mum, this is my new number. Can you transfer 900 pounds today?"* Maria taps **Is this a scam?** and pastes it.

The offline rules (`SCAM_PATTERNS` in `llm.py`: new number, fake police, fake bank, fake parcel, urgent payment, gift cards, prize, shock call, in German and English) flag it as **likely scam**. With a key, the model adds its judgement, but the rules can only raise the warning level, never lower it. The answer never says a message is safe: *"This looks like a scam. Someone is pretending to be your child or grandchild with a new number. Don't pay anything. Call the person or company on the number you already know."*

### Going for a walk

Maria's grandson set the app to show the **I'm lost** button (Settings → "Try the app as … Low vision"). She presses it, or the Action Button, or says "I'm lost with Beistand" to Siri.

1. The guide says where she is: *"You are here: Sendlinger-Tor-Platz 11, Altstadt-Lehel."* (reverse geocoding on the phone).
2. *"Where would you like to go?"* She says "Hauptbahnhof". The server finds the place near her (`/geocode`, OpenStreetMap Nominatim, cached for a week).
3. The server plans a route (`/route`): OpenRouteService if there is a key, else the free Valhalla server, else a straight line with distance and direction so the guide never has nothing. For blind users it asks Valhalla for alternatives and picks the one with the most crossings that have a **sound signal for blind people**, as long as it is at most 15 % longer (`crossings.best_for_blind`).
4. While she walks, `Guide/RouteFollower.swift` compares each GPS fix with the route:
   - about 15 m before each turn it speaks the instruction and vibrates (2 pulses left, 3 right; on the watch too);
   - about 25 m before each traffic light it says *"Traffic light crossing ahead, with a sound and touch signal."*: never whether it is safe;
   - more than 25 m off the route (twice in a row, allowing for GPS error) it re-plans and says so calmly; after three re-plans it offers to call Anna;
   - within 10 m of the goal: *"You have arrived: Munich Central Station."*
5. **With a Gemini key** the same walk becomes a conversation: the camera sends one picture per second, the microphone streams, and Gemini answers by voice. The route, the position and every warning from the phone are sent to Gemini as `[CONTEXT]` text. When Gemini announces it will close the connection (camera sessions are limited to about 2 minutes), the app reconnects with a resume handle and the conversation continues (`ResumePolicy`).
6. **On an iPhone Pro**, the camera is ARKit with LiDAR depth. A parking-sensor beep speeds up as something gets closer in an 80 cm lane straight ahead (silent beyond 2 m, fastest under 0.5 m), ignoring the ground and anything above head height. Apple Vision finds people and prominent objects; the phone says *"Scooter, 2 metres, ahead."* These warnings are fixed phrases and interrupt the guide.

### She drops the phone

The phone feels free fall, a hard impact, then stillness. The watch felt no impact on the wrist, so it is probably a dropped phone, not a fall. After about 20 seconds without a pickup, the **phone finder** starts: a loud rising tone (it plays even in silent mode), *"I'm here"* every few seconds, a white screen and a slowly pulsing torch (at most once per second, and never flashing in seizure mode). Picking it up stops it.

### She falls

This time the watch also feels a hard hit, then a still arm for 10 seconds (`Shared/WristFall.swift`). The phone and the watch agree: probably a fall.

1. **Ask:** the phone says *"Are you OK? Tap: I'm OK. Otherwise I'll call for help in 30 seconds."*; the watch vibrates and shows the same. Deaf users get a pulsing yellow screen instead of speech (steady in seizure mode).
2. **Contact:** after 30 s without an answer, the server texts and calls Anna through Twilio with a live location link. The call says the message twice, in Maria's language. If Anna doesn't respond, it tries again and then everyone on the list (up to 3 rounds).
3. **Anna** opens the link: a simple page with the location on a map and an "I'm taking care of it" button. Maria's phone then says *"Anna is taking care of you."*
4. **Emergency:** only after a clear yes from Maria or Anna does the phone offer 112 (iOS asks to confirm the call), or nora, the official emergency app for deaf people.
5. **Bystanders:** the alert screen shows a card: *"Maria may need help. Please call Anna: +49 …"*, with what to do for a seizure, or "I have memory problems", when those modes are on.
6. Maria taps **I'm OK** at any point: everything stops, and Anna gets an all-clear text.

The ladder runs **on the server** (`backend/app/ladder.py`), so it continues if the phone breaks or loses power. The app picks an open alert back up after a restart.

### At the station: hearing mode

Her neighbour Ali is hard of hearing. In Live captions, what people around him say appears as large text; **louder speech is bigger and bolder**, so he can tell a shout from a whisper. A meter shows the loudness (*"≈ 68 dB · normal voice"*), and a horn or a shout without words shows *"Loud sound nearby"* and vibrates. A tourist asks him something in Turkish: he picks "They speak: Turkish", and each line is translated on the phone into his language, large, with the original small underneath.


---

## How each part works

### Language

`ios/Shared/Lang.swift` holds one helper, `tr("English", "Deutsch")`: the app is in German when the phone's first language is German, otherwise in English. Every user-facing string, every spoken sentence, speech recognition, voices, Gemini's voice language and every server request (`lang=en|de`) follow it. On the server, `backend/app/lang.py` does the same; guide prompts exist in both languages. The emergency contact gets texts and calls in the person's language. Force a language for testing with the launch argument `-lang de`.

### Profile, modes and accessibility

- `Core/AppStore.swift`: the profile (name, modes, contacts), persisted on the phone and synced to the server. 13 modes: older, dementia, sight, low vision, hearing, wheelchair, speech, calm, easy reading, seizure, tremor, low energy, deafblind.
- `Core/SystemAccessibility.swift`: maps iPhone settings to modes (pure function `hints(_:)`, unit-tested). A setting switched on later adds its mode once; turning it off never removes a mode.
- `Features/Scaled.swift`: `scaledFont` (big text that follows Dynamic Type, growth capped), `A11yColor` (button colours ≥ 4.5:1 with white), `FitScroll` (screens scroll only when large text needs it).
- Settings → **Try the app as …** replaces all modes at once (older person, blind, low vision, deaf, memory, wheelchair, seizures, deafblind); below it, one switch per mode.

### Speech in and out

- `Core/Speaker.swift`: AVSpeechSynthesizer on its own queue (the first voice lookup can block for seconds; on the main thread it froze the app), slower rate for older users, a timeout so follow-up actions still happen if speech stalls, and word-by-word callbacks for highlighting.
- `Core/Listener.swift`: short answers ("yes", "no", a name) with on-device recognition; `yesNo` matches whole words in both languages.
- `Core/ModernSpeech.swift`: SpeechAnalyzer + SpeechTranscriber on iOS 26+: long-form, on device, punctuation, and the audio time of every word. The language model downloads once.

### Safety service

- `Safety/FallDetector.swift`: `FallPattern` (free fall < 0.35 g for ≥ 80 ms → impact > 2.5 g within 1 s → 10 s within ±0.12 g of rest), fed by CoreMotion at 50 Hz.
- `Safety/SafetyService.swift`: decides fall vs dropped phone (watch confirmation, or the demo switch "A phone fall counts as a fall of the person"), drives the server ladder, polls it every 2 s, keeps sending the location, resumes after a restart, falls back to dialling the contact directly if the server is unreachable.
- `Safety/DropFinder.swift`: tone, voice, torch, screen.
- `Safety/IncidentViews.swift`: the countdown, emergency and bystander screens.
- `backend/app/ladder.py`: `Ladder.start / person_ok / contact_ack / confirm_emergency / resolve / tick`. Time is passed in, so the tests run a whole incident in milliseconds. Explicit triggers (help button, spoken help, lost) skip the "Are you OK?" step.

### Watch

- `ios/Shared/WatchMessage.swift`: everything phone and watch say to each other, as plist dictionaries (help, I'm OK, wrist impact, wrist fall, guide cues; the incident state as application context, so a sleeping watch catches up).
- `ios/Shared/WristFall.swift`: hit > 3 g, then an arm still for 10 s → fall; moving on or clapping → no fall; at most one impact report per 2 s.
- `BeistandWatch/`: hold-1-second Help button (a brushed sleeve doesn't call for help), "Are you OK?", "Help is coming. Calling Anna.", 112 button, and an offline fallback that offers the calls itself when the phone is out of reach. Haptics: left = 2 taps, right = 3, arrived = success, asking = repeated until answered.
- `Safety/WatchLink.swift`: the phone side.

### The camera guide ("I'm lost")

- `Guide/GuideController.swift`: starts in Live mode if the server has a Gemini key, else simple mode; plans routes, follows them, runs the guide's tools (`plan_route`, `crossing_info`, `call_emergency_contact` (only after a clear yes)), sends `[CONTEXT]` updates, shows captions (newest on top, large, also for deaf companions).
- `Guide/LiveProtocol.swift`: Gemini Live messages (setup with session resumption and sliding-window compression, audio, video, text, tool responses, parsing incl. `goAway` and `sessionResumptionUpdate`), and `ResumePolicy` (reconnect up to 5 times in a row).
- `Guide/LiveMedia.swift`: 16 kHz microphone in, 24 kHz voice out with echo cancellation, and the WebSocket client, which ignores late events from a replaced connection.
- `Guide/RouteFollower.swift`: geometry and the step/crossing/off-route/arrival logic (pure, tested with simulated walks).
- `backend/app/guide.py`: system prompts (sight and low vision, English and German) with the safety rules, tools, place search, one-photo description and magnifier explanation.

### Obstacles and objects (iPhone Pro)

- `Guide/GuideCamera.swift`: on LiDAR phones, ARKit with scene depth and horizontal planes: a JPEG per second for the guide, obstacle lanes ~10 times per second, objects ~2 times per second. Other phones use the plain camera.
- `Guide/Obstacles.swift`:
  - `ObstacleGeometry`: depth pixels → world points (camera intrinsics scaled to the depth image) → three lanes in the walking direction; ignores the floor (ARKit's lowest plane) and anything above 2 m.
  - `BeepTiming`: silent > 2 m, 0.7 s … 0.1 s between beeps.
  - `ObjectAlerts`: what to say, nearest in the path first, people only within 1.5 m, no repeat within 8 s, 2 s between warnings.
  - `Beeper`: 1.4 kHz click plus haptic; haptic only for deaf users.
- Objects come from Apple Vision (human detector, objectness boxes, image classifier on each box), so there are no model licence issues.

### Maps and routes

- `backend/app/data.py`: `valhalla_route` (pedestrian costing types foot / wheelchair / blind, steps penalised for walkers, polyline6 decoding, alternatives for blind users, cached 6 h), `route` (OpenRouteService), `direct_route` (straight line), `nearby` (benches, toilets, wheelchair toilets, pharmacies, doctors, disabled parking from Overpass), MVG stations and departures, DB FaSta lifts, Bright Sky weather with a tip in the person's language.
- `backend/app/crossings.py`: the city's traffic lights (1,186 in the data, 1,160 still in service; 683 have a sound + touch signal for blind people, 244 touch only), loaded daily; which lie within 15 m of a route and how far along; the spoken sentence; the blind route choice.

### Hearing: live captions and translation

`Features/LiveCaptions.swift`:
- The microphone runs in measurement mode (no automatic gain, so loud really reads as loud).
- Each word's loudness is the power average of the microphone level over the time the word was spoken (`Loudness.average`), mapped to 18–60 pt and three font weights.
- The newer engine settles words with final results and shows guesses with volatile ones; a 1.5 s pause starts a new line.
- With "They speak: …", recognition runs in that language and each line is translated with Apple's on-device Translation framework.

### Low vision: magnifier and read-aloud

`Features/Magnifier.swift` (camera zoom via `videoZoomFactor`, torch, Core Image colour modes, freeze, "Explain") and `Features/ReadAloud.swift` (`ReadAloudText` with word highlighting, `OnDeviceReader` with amount and date extraction).

### Diagnostics and testing hooks

`Features/Diagnostics.swift` shows: server reachability, whether contact messages are real or a dry run, the vision model chain, the live guide state and reconnect count, LiDAR, the router, the speech engine, translation, the watch connection. Test buttons: read a sample label, plan Sendlinger Tor → Hauptbahnhof with your profile, list traffic lights near Hauptbahnhof, scam check, speak a sentence, tap "turn left" on the watch. It also switches the walk recorder on and shares recorded walks.


---

## Backend API

All endpoints accept `lang=en|de` where text comes back. Live data comes wrapped as `{"data": …, "fetched_at", "age_s", "stale"}`, so the app can show how old it is.

| Method and path | What it does |
|---|---|
| `GET /health` | Which features are live: Twilio, LLM, Gemini (+ model), router, vision chain, lifts. |
| `PUT /users/{id}/profile` · `GET …` | Save / read a profile (name, language, modes, contacts in E.164). |
| `POST /incidents` | Start the help ladder: `{user_id, trigger, location?}`. Triggers: `fall`, `help_button`, `spoken_help`, `lost`, `no_sign_of_life`, `long_shaking`. |
| `GET /incidents/{id}` | Current state, deadline, who acknowledged. |
| `POST /incidents/{id}/ok` · `/ack` · `/confirm-emergency` · `/resolve` · `/location` | The person is OK · a contact takes care · emergency confirmed · close · new position. |
| `GET /live/{id}?t=…` · `GET /live/{id}/ack?t=…&name=…` | The contact's page (map link, history, "I'm taking care of it"), only with the secret token, only during the alert. |
| `GET /outbox` | Texts and calls that were sent (or would have been, in dry run). |
| `POST /read` | Photo → `{readable, retake_hint, sender, wants, amount, deadline, spoken}`. |
| `POST /scam-check` | Text → `{level: likely_scam / suspicious / unclear, patterns, spoken, source}`. Never "safe". |
| `POST /gemini/token` | Short-lived Gemini Live token + model for the phone. |
| `GET /warnings?lat&lon` | Weather, official warnings, one-sentence tip. |
| `GET /stations?lat&lon` · `GET /departures?global_id` | MVG stops and live departures. |
| `GET /lifts?station_number` | Lift and escalator status (DB FaSta). |
| `GET /nearby?lat&lon&kind&radius_m` | Benches, toilets, wheelchair toilets, pharmacies, doctors, disabled parking. |
| `GET /route?from_lat&from_lon&to_lat&to_lon&profile` | `profile`: `foot-walking`, `wheelchair`, `blind`. Steps, geometry, `crossings`, `provider`, `alternatives_checked`. |
| `GET /crossings?lat&lon&radius_m` | Nearest traffic lights with their signal. |
| `GET /guide/prompt?mode` | Guide system prompt, tools and voice language (`mode`: `sight`, `low_vision`). |
| `GET /geocode?q&lat&lon` | Places near the person. |
| `POST /describe` | One photo → short spoken description (`purpose`: `lost` or `magnify`). |

---

## Running on devices

### On a real iPhone

1. In Xcode, select the **Beistand** target → Signing & Capabilities → your team. Do the same for **BeistandWatch**. Or pass the team on the command line:

   ```bash
   xcodebuild -project Beistand.xcodeproj -scheme Beistand \
     -destination 'id=<your-iphone-udid>' -derivedDataPath build-device \
     -allowProvisioningUpdates DEVELOPMENT_TEAM=<your-team-id> build
   xcrun devicectl device install app --device <udid> build-device/Build/Products/Debug-iphoneos/Beistand.app
   ```

2. Tell the app where the Mac is (same Wi-Fi):

   ```bash
   xcrun devicectl device process launch --device <udid> --terminate-existing app.beistand.ios \
     -backendURL http://<your-mac-ip>:8000
   ```

   The app remembers the address. You can also change it in Settings → Server. Find the Mac's address with `ipconfig getifaddr en0`.

3. If the phone shows as "unavailable" in `xcrun devicectl list devices`, unlock it and wait a few seconds.

### Watch app in a paired simulator

```bash
xcrun simctl create "Beistand Watch" com.apple.CoreSimulator.SimDeviceType.Apple-Watch-SE-3-44mm \
  com.apple.CoreSimulator.SimRuntime.watchOS-27-0
xcrun simctl pair <watch-udid> <iphone-sim-udid>
xcrun simctl boot <watch-udid>
xcrun simctl install <watch-udid> ios/build/Build/Products/Debug-watchsimulator/BeistandWatch.app
xcrun simctl launch <watch-udid> app.beistand.ios.watchkitapp
```

(If the watch runtime is missing: `xcodebuild -downloadPlatform watchOS`.)

Model names are settings, too: `ANTHROPIC_MODEL`, `GEMINI_LIVE_MODEL` (default `gemini-3.8-live`) and `GEMINI_VISION_MODEL`.

---

## Testing hooks

### Launch options for testing (debug builds)

Pass them after the bundle id: `xcrun simctl launch <device> app.beistand.ios -openGuide YES`.

| Option | Effect |
|---|---|
| `-backendURL http://…:8000` | Server address (remembered) |
| `-lang de` | Force German (or `en`) |
| `-openGuide YES -guideDestination Odeonsplatz` | Open "I'm lost" and go to a place after 4 s |
| `-openMagnifier YES` | Open the magnifier (simulator shows a test medicine label) |
| `-openCaptions YES -demoCaptions YES` | Live captions with a scripted conversation at different volumes |
| `-openDiagnostics YES` | Open Diagnostics |
| `-openSounds YES -testSound siren` | Open sound alerts and raise a test alert after 2 s |
| `-openCounter YES` | Open counter mode |
| `-openMap YES -dropPin 48.1372,11.5755` | Open the destination map with a pin and its accessibility card |
| `-openGuide YES -simDrive YES -simStart 48.1388,11.5672 -simHeading 90` | Test drive from Neuhauser Straße, facing east |
| `-openGuide YES -lookAround YES -fakeSweep YES` | Live street view, turning slowly on the spot (the simulator has no compass) |
| `-fakeVolume 0.2` | Pretend the phone is quiet |
| Watch: `-watchAction ok\|help\|fall` | The watch presses that button 3 s after connecting |

### Simulated walks

Get a route from the server, cut it into ~10 m waypoints, and let the simulator walk it:

```bash
xcrun simctl location <device> start --speed=4 48.134,11.5671 48.1341,11.5670 …
```

Give it many waypoints: with only start and end, the simulator walks a curve and the app (correctly) reports that the person left the route.

### Recorded walks

Settings → Diagnostics → **Record test walks**. Each walk is saved as JSON lines (GPS fixes, obstacle lanes, detected objects, everything the phone said), shareable from Diagnostics, and readable with `WalkRecorder.read`, so a real walk can be replayed through the warning rules in a unit test (`testReplayRecordedWalk`).

---

## Troubleshooting

| Problem | Fix |
|---|---|
| The iPhone can't reach the server | Same Wi-Fi as the Mac; server started with `--host 0.0.0.0`; correct address in Settings → Server (`ipconfig getifaddr en0` on the Mac). |
| `No module named uvicorn` | Run the server with `backend/.venv/bin/python`, not the system `python3`. |
| Phone "unavailable" for `devicectl` | Unlock it, keep it plugged in, wait a few seconds. |
| Live guide stays in "Simple mode" | `GEMINI_API_KEY` missing, or the model name is wrong; check `/health` and the Models page. |
| Read this only reads word for word | No `ANTHROPIC_API_KEY`: that's the offline fallback. |
| No obstacle beeps | Needs an iPhone with LiDAR; Diagnostics → "LiDAR depth" must say yes; Settings → obstacle warnings on. |
| Translation "not available" | Needs iOS 26 on a real device; download the language pack once from Live captions. |
| Speech engine shows SFSpeechRecognizer | Normal in the simulator and below iOS 26. |
| Simulated walk says "off route" | Give `simctl location start` many waypoints along the route. |
