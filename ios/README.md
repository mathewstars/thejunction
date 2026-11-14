# iOS app

**Start here: [HANDOFF.md](HANDOFF.md).** It has what the app is, who owns what, the code map, how to run it and the rules for working on it. The rest of this page is older.

The Xcode project goes here. Peter writes the code, Matthew builds it on his Mac and puts it on TestFlight.

Read first:

- `docs/app-design.md`: the screens and the calls to the server.
- `docs/game-interface.md`: what the app logs during each activity and the record it sends.

Rules:

- All code is written at the event. Open-source libraries are fine.
- The repo is public. No API keys, tokens or server addresses in the code. Put them in a config file that is git-ignored and commit an example file with placeholders.
- Commit often, so the history shows when the code was written.

## The app base (Friday night)

A starting point with the look and the fox, so the real screens can be built on top.

How to run it:

1. Open `ios/Lanvi.xcodeproj` in Xcode (or run `xcodegen generate` in `ios/` first if you change `project.yml`).
2. Pick an iPhone simulator and press Run.
3. Add `-demo` under Scheme, Arguments to get an automatic walk-through (good for recording the video).

What is in it:

- `Design/Theme.swift`: the blue and white colours and the rounded font.
- `Design/Chunky.swift`: the 3D buttons and cards that press down.
- `Design/SkyScene.swift`: the night sky with moving aurora, stars and snow hills.
- `Mascot/LanviView.swift`: Lanvi. It breathes and sways all the time. Change `bounceTrigger` or the pose and it jumps with a squash and stretch. Eight poses: cheer, curious, meh, run, love, surprised, grumpy, peek.
- `Screens/WelcomeView.swift` and `Screens/HomeView.swift`: the two finished screens. Tapping Lanvi on Home cycles its poses.

The fox art is in `Assets.xcassets` as `lanvi-<pose>`. It is low resolution for now; sharper versions of the same poses will replace the files without code changes.

## Talking to the server

**Every build talks to the live server, `https://lanvi.app`** (set in `ios/Base.xcconfig`). On first run the app asks for the clinic's one-time pairing code: ask Mathew (dad) for one. Codes work once; Help has "Disconnect this phone" to pair again. Launch with `-offline` for sample data and no server (UI tests and screenshots always pass `-offline`). A git-ignored `ios/Config.xcconfig` (copy `ios/Config.example.xcconfig`) can point the app at another server, such as a local engine.

- `Net/`: the client (`LanviClient`), the data types from `docs/api/openapi.json` (`APIModels.swift`), the device token in the Keychain, the outbox (an activity that could not be sent is kept on disk and sent on the next open) and the offline demo (`DemoBackend`).
- `State/AppStore.swift`: one observable store with today's state, used by every screen.
- `Screens/ActivityRouter.swift`: the one place Home opens Sparks and snow, Breathe with Lanvi and the check-in, and turns their results into server records.

To try it against a local engine: run it as in `docs/api/README.md` (seed with `--pairing-code`), put `http:/$()/127.0.0.1:<port>` in `Config.xcconfig`, run in the simulator and type the printed code on the pairing screen (or put the code in `Config.xcconfig` too, to pair silently).

## Launch arguments

- `-demo`: the whole story by itself for the pitch video (about a minute): Welcome, what helps, Home, Breathe with Lanvi, the XP and glow moment, growing up, a wandering and its story. Always offline.
- `-screen home | whathelps | focus | breathe | checkin | checkin-plan`: open one screen.
- `-offline`: sample data, no server (always use it for tests and screenshots).
- `-screen pair`: the pairing screen on its own. `-pairTry CODE[,CODE]` (debug builds) types each code and presses Connect, for testing against a local engine.
- Home moments for screenshots: `-demoGlow 0.9`, `-demoXP 295`, `-demoSuggestion breathing`, `-demoWandering back|away`, `-demoPlay focus|breathing|checkin`, `-demoOpen help|story|mind|focus|breathing|checkin`, `-demoAnswer a|b`.
