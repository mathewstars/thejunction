# Lanvi iPhone app: the handbook

Read this first. It tells a new coding session (or Peter) what Lanvi is, who owns what, the rules nobody reopens, and how to work without freezing the captain's Mac.

## What Lanvi is

- Built at **Junction 2026**, Aalto challenge **"Beyond the Clinic"**: help people stay well at home after TMS treatment for depression.
- Judged 25 % each on: usefulness, ease of use, smart sensing, creativity.
- Final submission: **Sunday 15 Nov 2026, 10:00** (2-minute video, demo, source, PDF deck).
- The repo is public and MIT licensed (`LICENSE`). All code is written at the event.

## Who owns what

| Who | Owns | How to work with it |
|---|---|---|
| Matthew (captain) | Design, the fox, the games, the chat, naming, pitch. Builds the app. | Judges every UI change from a screenshot or screen recording before it merges. |
| Mathew (his dad, GitHub `mstafurik`) | The server in `engine/`, `docs/`, the clinician web page. | Changes to `engine/` go to him as a pull request. We never merge them. |
| Peter (`petermikeska67`) | Sensors: `harness/` (Apple Health reader, ARKit face capture, research tooling) and `facemetrics/`. Branch `finalish-testing-app`. | Stay out of his folders. Note: `harness/` is on his branch, not on `main` yet. |

Do not touch the root `README.md`, `docs/`, `engine/`, `facemetrics/` or `harness/` from an app session.

## The product (decided by the captain, do not reopen)

- Name **Lanvi**. Mascot: a little **Arctic fox**, from the Finnish legend of fox fires ("revontulet", the northern lights).
- A Finch-style companion. Lanvi never dies, never dims, is never sad because of the person.
- XP for showing up, never for scores. No guilt, no streak pressure. A "days together" count that never resets.
- Never clinical words. Never a diagnosis.
- **Home shows ONE thing for today**, picked by Lanvi, not a menu of games. Order (`AppStore.todayThing`): a waiting story, then what is already done today, then the server's suggestion, then the clock (morning Breathe, afternoon Sparks and snow, evening check-in).
- Activities:
  - **Sparks and snow**: focus tap game, about 45 seconds. Tap the warm sparks, let the snowflakes fall.
  - **Breathe with Lanvi**: about 1 minute of slow breathing with the fox.
  - **Evening check-in**: three good things and one small thing for tomorrow.
- A real back-and-forth **chat** with Lanvi.

**Rejected, never bring back:** smile-back faces, a farm, a glowing ball mascot, an AR catch-the-lights game, fox art drawn by an agent, stacks of white cards on Home, a light or glow effect on the fox's tail, swinging the front legs as arms, busy idle motion (the fox must never shake in place).

## Design rules (the captain's bar)

- **The scene is the screen.** Full-bleed hand-painted world (dawn, day, night). Lanvi large and exactly centred. One speech bubble. One primary chunky button. Tiny corner controls. Almost no containers.
- Font **Nunito** (`Lanvi/Fonts/`). Colours **blue and white** (`Design/Theme.swift`).
- Motion like Duolingo's mascot: eased or sprung, overlap and follow-through, 60 fps.
- Calm idle: slow breathing, slow tail sway, blinks, a rare ear flick, otherwise perfectly still.
- Rejected on sight: anything that looks like a default shape, a gradient with a sticker on it, or "AI slop".
- Every UI change needs a screenshot or screen recording for the captain before it merges.

## The fox art

Art was generated on the team's Higgsfield account from the captain's own fox. **Never draw new fox art in code.** All of it is in `Lanvi/Assets.xcassets`.

| Assets | What they are | Made by |
|---|---|---|
| `lanvi-cheer`, `-curious`, `-meh`, `-run`, `-love`, `-surprised`, `-grumpy`, `-peek` | The eight sticker poses, cut from the captain's sticker sheet sharpened to 4K. | `tools/cut_poses.py` |
| `puppet-ear-left/right`, `puppet-head` (blank), `puppet-body`, `puppet-tail`, `puppet-leg-left/right` | The living puppet's body parts. | `tools/cut_puppet_parts.py` |
| `puppet-eyes-open/half/closed/happy/left/right/up/wide`, `puppet-mouth-smile/o/happy/yawn/flat` | Eye sets and mouths for the puppet face. | `tools/cut_puppet_parts.py` (also writes `Mascot/LanviArt.swift`, do not edit it by hand) |
| `world-dawn`, `world-day`, `world-night` | The three painted Home scenes. | |

Poses `curious`, `cheer`, `love`, `surprised` are drawn as the puppet. `run`, `peek`, `grumpy`, `meh` are still single pictures.

## Code map (`ios/Lanvi/`)

| Folder / file | What it is |
|---|---|
| `App/LanviApp.swift` | App entry. First run: Welcome, then What helps, then Home. Reads `-demo` and `-screen`. |
| `State/AppStore.swift` | The one store every screen uses: today's state, the one thing for today (`todayThing`), days together, chat thread, the mind, demo vs live mode. |
| `Net/LanviClient.swift` | The real server client (pairs itself, re-pairs on 401). |
| `Net/APIModels.swift` | The server's data types, field for field from `docs/api/openapi.json`. |
| `Net/DemoBackend.swift` | Offline demo: acts like the server with sample data. |
| `Net/ChatLink.swift` | The one place chat talks to the server. |
| `Net/ServerConfig.swift`, `Net/TokenKeychain.swift` | Server address from config; device token in the Keychain, one per server. |
| `Net/ActivityOutbox.swift` | Activities not sent yet, kept on disk and sent on the next open; last known "today". |
| `Mascot/LanviView.swift` | **Use this for the fox.** Read the note at the top. |
| `Mascot/LanviPuppet.swift`, `LanviRig.swift`, `LanviMotion.swift` | The puppet: draws the parts, where they sit, how they move from one clock. |
| `Mascot/LanviPuppetPreview.swift` | A screen to judge the puppet (`-screen puppet`). |
| `Screens/HomeView.swift` + `Screens/Home/` | Home and its pieces: `PaintedWorld` (the three scenes), `HomeChatScreen` (chat), `HomeMindScreen` (what Lanvi has learned), `HomeOverlays` (help with call buttons), `HomeMoments` (growing up), `HomeSheets`, `HomeParts`. |
| `Screens/WelcomeView.swift`, `WhatHelpsView.swift` | First run. What helps sends `PUT /v1/preferences`. |
| `Screens/ActivityRouter.swift` | The one place Home opens an activity and turns its result into the server record. |
| `Screens/Focus/` | Sparks and snow (`FocusGameView`, `FocusEngine`, `FocusArt`, `FocusResult`). |
| `Screens/Breathe/` | Breathe with Lanvi (`BreatheView`, `BreathePieces`, `BreatheResult`). |
| `Screens/Checkin/` | Evening check-in (`CheckinView`, `CheckinParts`, `CheckinModels`). |
| `Design/Theme.swift` | Colours and the Nunito font helper `Theme.rounded`. |
| `Design/Chunky.swift` | `ChunkyButtonStyle` and `ChunkyCardStyle`: 3D buttons that press down onto a hard edge. |
| `Design/SkyScene.swift` | The moving night sky (aurora, stars, snow hills) used behind the games. |

### The fox: `LanviView` in one look

```swift
LanviView(pose: .curious, size: 200, bounceTrigger: bounce)
    .lanviMood(.sleepy)                       // held while set
    .lanviReaction(.happy, trigger: xp)       // plays once each time xp changes
    .lanviLookAt(UnitPoint(x: 0.9, y: -0.3))  // eyes, then head, turn to a point
```

- Moods: `calm`, `happy`, `curious`, `surprised`, `sleepy`, `listening`. No sad mood, on purpose.
- Every `LanviView` is alive by itself. Tapping the fox makes it look and hop.
- The view's square is centred on head and body; the tail hangs out on the left. Centre the view and the fox looks centred.

## Launch arguments

Add them in Xcode under Scheme, Arguments, or after `xcrun simctl launch <device> app.lanvi.Lanvi`.

| Argument | What it does |
|---|---|
| `-demo` | The whole story by itself for the pitch video: Welcome, Home, Breathe, XP moment, growing up, a wandering and its story, a word in chat. Always offline, hour forced to 20. |
| `-screen <name>` | Open one screen: `home`, `whathelps`, `focus`, `breathe`, `checkin`, `checkin-plan`, `puppet`. |
| `-offline` | Offline demo data even when a server is configured. |
| `-hour <0-23>` | Show the app as at that hour (sky, pose, today's pick). |
| `-demoDays <n>` | Days together in the demo (default 11). |
| `-demoDone focus\|breathing\|checkin` | Demo starts with that activity already done today. |
| `-demoGlow 0.15`, `-demoXP 230` | Demo starting glow and XP. |
| `-demoSuggestion breathing\|focus_game\|checkin\|walk_10min` | The demo server's suggestion. |
| `-demoWandering back\|away` | Lanvi is back from (or away on) a wandering. |
| `-demoPlay focus\|breathing\|checkin` | Sends one activity at once (see the XP moment). `-demoDelay <s>` waits first. |
| `-demoOpen help\|story\|mind\|chat\|more\|growth\|focus\|breathing\|checkin` | Opens that screen on Home. |
| `-demoAnswer a\|b` | Answers the waiting story. |
| `-chatDemo typing\|long\|talk\|help` | Chat screenshot moments. `-chatSlow` makes the demo reply slow to show the waiting dots. |
| `-puppetFreeze happy:0.32`, `-puppetDemo YES`, `-puppetDemoDelay 11` | Puppet stills and the puppet video (with `-screen puppet`). |

## The server link

Every call goes through `AppStore` to `LanviClient` (live) or `DemoBackend` (offline). The contract is `docs/api/README.md` and `docs/api/openapi.json`.

| Call | Used for |
|---|---|
| `POST /v1/devices/pair` | First open: trade the pairing code for a device token (done inside `LanviClient`). |
| `GET /v1/today` | Lanvi's state, today's suggestion, wandering, help text. |
| `POST /v1/activities` | A finished game, breath or check-in (via `ActivityRouter`). |
| `POST /v1/feedback` | "I did it" / "Not today" on a suggestion. |
| `GET /v1/checkin/options` | What the check-in offers to tap. |
| `PUT /v1/preferences` | What usually helps (first run). |
| `POST /v1/lanvi/wanderings/{id}/answer` | Answering Lanvi's story after a wandering. |
| `POST /v1/notes` | Each chat message. |
| `GET /v1/mind`, `POST /v1/mind/lessons/{id}/reject`, `POST /v1/mind/questions/{id}/answer` | What Lanvi has learned, "Not true", and answering its questions. |

**Config.** The address and pairing code live only in `ios/Config.xcconfig`, which is git-ignored. Copy `ios/Config.example.xcconfig` to make it. No config means **offline demo mode** with sample data. Never put keys, pairing codes or server addresses in code.

**Local engine for testing.** Run it as in `docs/api/README.md` (seed with `--pairing-code`), then put `http:/$()/127.0.0.1:8080` and the printed code in `Config.xcconfig`.

## Chat and Gemini

- The app sends each message to `POST /v1/notes` and shows `reply.text` (`Net/ChatLink.swift`). A crisis reply shows the help contacts.
- Gemini is called **only by the server**. The app never holds a Gemini key.
- PR #6 for the dad (`fm/lanvi-chat`) lets Gemini write the reply, behind the server switch `CHAT_MODE` (off by default).

## Sensors (Peter's area)

- Apple Health and face reading are being plugged in from Peter's `harness/` modules on branch `fm/lanvi-sense`. See [`SENSORS.md`](SENSORS.md) once it lands.
- ARKit face tracking does not run in the simulator. Test it on a real iPhone.

## Build and run

- iOS 17, SwiftUI, no third-party packages.
- The Xcode project is generated by **XcodeGen** from `project.yml`. After adding or removing files run `xcodegen generate` in `ios/` and commit the regenerated `Lanvi.xcodeproj`.
- On a project-file merge conflict: take main's version, run `xcodegen generate` again. Never hand-merge it.
- Build (from `ios/`, inside the lock below):

```sh
xcodebuild -project Lanvi.xcodeproj -scheme Lanvi \
  -destination 'platform=iOS Simulator,id=<your-device-id>' \
  -derivedDataPath build/dd build
```

- Then `xcrun simctl install <device> build/dd/Build/Products/Debug-iphonesimulator/Lanvi.app`, `xcrun simctl launch <device> app.lanvi.Lanvi -screen home`, and `xcrun simctl io <device> screenshot shot.png`.

## Working rules for every session (the captain's Mac froze twice)

- **Only ONE simulator booted at a time across all sessions.** Before any `xcodebuild` or simulator boot: `mkdir /tmp/lanvi-heavy.lock` (if it fails, someone else has it: wait). `rmdir /tmp/lanvi-heavy.lock` right after. Never hold it more than 5 minutes. If it is older than 15 minutes, remove it.
- Your own simulator device per session, your own `-derivedDataPath` inside your working copy.
- Shut your simulator down after each run (`xcrun simctl shutdown <device>`).
- Never leave screenshot or recording loops running.
- Never open windows on the captain's screen. Never play sound.
- Never `pkill -f` or `killall`.
- On this Mac never pipe into `grep` (it is a wrapped shell function and hangs). Use `/usr/bin/grep` on a file, or `awk`.

## How to contribute

- Branch from `origin/main`. Small commits, plain-English messages, no agent co-author lines. Open a pull request against `main`.
- Stay in your own folder so parallel sessions do not collide. Safe for a mini-games session: `Screens/Focus/`, `Screens/Breathe/`, `Screens/Checkin/`, and new game folders beside them, wired in through `Screens/ActivityRouter.swift`.
- A new activity type needs the dad's server to accept it first. Today it knows `focus`, `breathing`, `checkin` (`ActivityKind` in `State/AppStore.swift`).

## In flight right now

Written Saturday 14 Nov, late morning. **This goes stale fast; check `git branch -r` and open PRs.**

- `fm/lanvi-puppet`: puppet motion being made smoother.
- `fm/lanvi-server`: Home, painted world, chat and demo.
- `fm/lanvi-sense`: sensors.
- `fm/lanvi-chat`: Gemini chat on the server (PR #6, for the dad).
- Not started: making the two games look and feel great, the pitch video, TestFlight.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
