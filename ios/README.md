# Lanvi, the iPhone app

Lanvi is a little Arctic fox who keeps you company at home after TMS treatment. Each day Lanvi picks one small thing to do together: a short focus game (Sparks and snow), a minute of breathing, or an evening check-in. You can also chat with Lanvi. Built at Junction 2026.

## Start here

- [`AGENTS.md`](AGENTS.md): the handbook. What the app is, who owns what, design rules, code map, launch arguments, server calls, how to build and the rules for working on the shared Mac.
- [`SENSORS.md`](SENSORS.md): Apple Health and face reading (Peter's area).
- `docs/api/README.md` (repo root): the server the app talks to.

## Run it in two steps

1. Open `ios/Lanvi.xcodeproj` in Xcode (after changing `project.yml`, run `xcodegen generate` in `ios/` first).
2. Pick an iPhone simulator and press Run.

With no `ios/Config.xcconfig` the app runs an offline demo with sample data. To talk to a real server, copy `ios/Config.example.xcconfig` to `ios/Config.xcconfig` and fill in the address and pairing code. That file is git-ignored: never commit addresses, codes or keys.

Add `-demo` under Scheme, Arguments for the whole story by itself (used for the pitch video).
