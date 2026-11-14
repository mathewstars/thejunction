# Lanvi app: read this first

For anyone starting work on the iPhone app: a new coding session, an agent, Peter, or dad. Written Saturday 14 Nov 2026, late morning. The "in flight" section goes stale fast; the rest should hold.

## What this is

Lanvi is our Junction 2026 entry for the Aalto challenge "Beyond the Clinic": helping people stay well at home after TMS treatment for depression. A small Arctic fox lives on the phone, offers one small thing a day, and the server learns what helps that person.

- Judged 25% each: usefulness, ease of use, smart sensing, creativity.
- Final submission: **Sunday 15 Nov, 10:00** (2-minute video, demo, source, PDF deck). Peer review 10:30 to 14:00.
- The repo is public and MIT. All code is written at the event. No keys or pairing codes in code, ever. The one exception to "no server addresses": the live server `lanvi.app`, which is public in the root README and is the app's default.

## Who owns what

| Who | Owns | Where |
|---|---|---|
| Matthew | The app: design, the fox, the games, the chat, pitch | `ios/` |
| Mathew (dad, `mstafurik`) | The server ("the mind"), clinician web page, research, docs | `engine/`, `docs/`, root `README.md` |
| Peter (`petermikeska67`) | Sensors: Apple Health, ARKit face capture, research tooling | `harness/` on branch `finalish-testing-app`, `facemetrics/` |

Changes to `engine/` or `docs/` go to dad as a pull request. Do not merge them yourself.

## What dad's side does (so the app fits it)

- **Server** in `engine/` (Python). How to run it and every call: `docs/api/README.md`, exact contract `docs/api/openapi.json`. Live server: lanvi.app. **Every build talks to it by default.** Pairing codes are one-time and come from dad; they are never in the repo.
- It compares each day with that person's own normal, picks **at most one suggestion a day**, counts XP and growth, sends Lanvi's lines and wandering stories, and learns from what the person did.
- **Clinician web page** (one line per patient, timeline, Conversation tab showing what the patient wrote and what Lanvi answered, Research tab).
- **Face data** (new on Saturday): the phone sends raw face frames and the server computes the measures. Read `docs/face-raw.md`.
- **Gemini** is used on the server only (weekly review, session reading). The team is in the "Best use of Gemini API" track.
- Useful docs: `docs/game-design.md` (the Lanvi design), `docs/demo-script.md`, `docs/pitch.md`, `docs/submission.md`, `docs/research-proposal.md`, `docs/research-video.md`, `aalto/CHALLENGE.md`.

## What Peter's side has

Branch `finalish-testing-app`, folder `harness/`: a separate test app plus reusable Swift modules. Start with `harness/docs/INTEGRATION.md`.

- **HealthKit reader** (`HealthKitManager`, `HealthTypeCatalog`, `HealthSummaryBuilder`): steps, sleep and the rest, with history.
- **ARKit face import and features** (`ARKitDatasetImporter`, `FacialFeatureAnalyzer`), built on the `facemetrics/` recorder.
- **A Gemini client through a proxy.** Not used in Lanvi: in the app, Gemini is reached only through dad's server.
- Peter's code was written without Xcode, so expect small first-build fixes (`harness/docs/LIMITATIONS.md`).

Where they plug into the app: Apple Health on first run and on every app open, sent to `POST /v1/daily`; face frames during Sparks and snow and Breathe, sent as `docs/face-raw.md` says. This is being wired on branch `fm/lanvi-sense`; it will add `ios/SENSORS.md`.

## The product, as decided by Matthew (do not reopen)

- Name **Lanvi**. A little Arctic fox (the Finnish "fox fires" legend). Finch-style companion.
- Lanvi never dies, never dims, is never sad because of the person. XP is for showing up, never for scores. No guilt, no streak pressure. "Days together" only ever goes up.
- Never clinical words, never a diagnosis.
- **Home shows one thing for today, picked by Lanvi** (the server's suggestion, else by time of day). It is not a menu of games.
- Activities: **Sparks and snow** (focus tap game, about 45 s), **Breathe with Lanvi** (about 1 min), **Evening check-in** (three good things, one small thing for tomorrow).
- A **real back-and-forth chat** with Lanvi.

Rejected by Matthew, do not bring back: smile-back faces, a farm, a glowing ball mascot, the AR catch-the-lights game, foxes drawn by an agent (use his art only), stacks of white cards on Home, any light or glow on the fox's tail, swinging the fox's front legs as arms, a fox that shakes or fidgets in place, Lanvi wandering off or bringing back stories (cut; the app ignores the server's `wandering` and never calls the wandering answer endpoint).

## Design bar

Matthew judges every UI change from a screenshot or a screen recording before it merges. He rejects anything that looks like a default shape, a gradient with a sticker on it, or "AI slop".

- The scene is the screen: a full-bleed hand-painted world (dawn, day, night). Lanvi large and exactly centred. One speech bubble, one chunky primary button, tiny corner controls, almost no boxes.
- Font Nunito. Blue and white.
- Motion like Duolingo's mascot: eased or sprung, never linear; parts overlap and follow through. Idle is calm: slow breathing, a slow tail sway, a blink, a rare ear flick, otherwise perfectly still. 60 fps.

## Code map (`ios/Lanvi/`)

| Folder | What is in it |
|---|---|
| `App/LanviApp.swift` | Entry point, launch arguments, which screen opens |
| `Design/` | `Theme.swift` (colours, Nunito), `Chunky.swift` (3D press-down buttons), `SkyScene.swift` (older drawn sky) |
| `Mascot/` | The living fox. `LanviView` is the one view every screen uses. `LanviPuppet`, `LanviRig`, `LanviMotion`, `LanviArt` build it from separate parts; `LanviPuppetPreview` is a test screen |
| `Screens/HomeView.swift` + `Screens/Home/` | Home, the painted world (`PaintedWorld.swift`), the XP moment, sheets, the chat (`HomeChatScreen.swift`), "what Lanvi noticed" (`HomeMindScreen.swift`) |
| `Screens/Focus/` | Sparks and snow |
| `Screens/Breathe/` | Breathe with Lanvi |
| `Screens/Checkin/` | Evening check-in |
| `Screens/ActivityRouter.swift` | The one place that opens an activity and takes its result |
| `Screens/WelcomeView.swift`, `WhatHelpsView.swift` | First run |
| `State/AppStore.swift` | The app's state: today, XP, stage, suggestion |
| `Net/` | `LanviClient.swift` (all server calls), `APIModels.swift`, `ActivityOutbox.swift` (unsent activities retried later), `ChatLink.swift`, `DemoBackend.swift` (offline sample data), `ServerConfig.swift`, `TokenKeychain.swift` |
| `Assets.xcassets` | `lanvi-<pose>` (eight sticker poses), `puppet-*` (fox parts, eyes, mouths), the painted scenes |
| `../tools/` | `cut_poses.py`, `cut_puppet_parts.py`: re-cut the art when better pictures arrive |

The fox art comes from Matthew's own fox, sharpened and split into parts on the team's Higgsfield account. Never draw new fox art in code.

## Run it

1. `cd ios && xcodegen generate` (needed after adding files; commit the regenerated `Lanvi.xcodeproj`). On a project-file merge conflict take main's version and regenerate; never hand-merge it.
2. Open `ios/Lanvi.xcodeproj`, pick an iPhone simulator, Run. iOS 17, SwiftUI, no third-party packages.
3. **Builds talk to the live server, `lanvi.app`.** On first run the app asks for a one-time pairing code (get one from Mathew, dad). Codes work once; Help has "Disconnect this phone" to pair again with a new one. For sample data with no server, launch with `-offline` (UI tests and screenshot runs must always pass `-offline`, so automated runs never send fake activity to the live clinic). To use another server (a local engine), copy `ios/Config.example.xcconfig` to `ios/Config.xcconfig` (git-ignored).

Launch arguments (Scheme, Arguments): `-demo` plays the whole story by itself; `-screen home|whathelps|focus|breathe|puppet` opens one screen; `-hour <0-23>` forces the time of day; `-offline` uses sample data instead of the server. More demo switches exist (`-demoXP`, `-demoGlow`, `-demoDone`, `-demoSuggestion`, `-chatDemo` and others): read `App/LanviApp.swift` and `Net/DemoBackend.swift`.

## How the app talks to the server

Pair once (`POST /v1/devices/pair`), then `GET /v1/today` on open and after every activity, `POST /v1/activities` for a finished activity (types `focus`, `breathing`, `checkin`), `POST /v1/feedback` for "I did it / Not today", `POST /v1/notes` for each chat message (the reply is `reply.text`; `crisis: true` opens Help at once), plus check-in options, preferences and "mind" (never the wandering answer: stories are cut). All of it is in `Net/LanviClient.swift`.

A new kind of activity needs dad's server to accept it first. Today it knows only `focus`, `breathing`, `checkin`.

## Rules for every session and agent

Matthew's Mac (18 GB) froze twice from simulators. These are not optional.

- **One simulator booted at a time, across all sessions.** Before any `xcodebuild` or simulator boot: `mkdir /tmp/lanvi-heavy.lock`. If that fails someone else is building: wait 30 seconds and retry (if the folder is older than 15 minutes, remove it and take it). `rmdir /tmp/lanvi-heavy.lock` the moment your run ends. Never hold it more than 5 minutes.
- Your own simulator device and your own `-derivedDataPath build/dd` inside your working copy. Shut the simulator down after every run.
- Never leave screenshot or recording loops running in the background.
- Never open windows on Matthew's screen. Never play sound.
- Never `pkill -f` or `killall`. Stop only what you started, by exact process id.
- On this Mac never pipe into `grep` (it is a wrapped function and hangs). Use `/usr/bin/grep` on a file, or awk.

## How to contribute

- Branch from `origin/main`. Small commits with plain-English messages. Open a pull request against `main`.
- Stay in your own folder so parallel sessions do not collide. A games session owns `Screens/Focus/`, `Screens/Breathe/`, `Screens/Checkin/` and any new game folder beside them, wired through `ActivityRouter.swift`. Leave `Mascot/`, `Screens/Home/`, `Net/` and `State/` to the sessions working there unless you agree it first.

## In flight right now (Saturday, late morning)

| Branch | What |
|---|---|
| `fm/lanvi-puppet` | Making the fox's motion smooth and its idle calm (Matthew rejected it twice as shaky and choppy) |
| `fm/lanvi-server` | Home in the painted world, the chat screen, the short demo video |
| `fm/lanvi-sense` | Plugging in Peter's Apple Health reader and the face frames |
| `fm/lanvi-chat` | Gemini-written chat replies on the server, as a pull request for dad |

Not started: making the games look and feel great, the pitch video, TestFlight.
