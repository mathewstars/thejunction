# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Three parts: `engine/` (Python server, run and API in `docs/api/README.md`), `ios/` (Lanvi iPhone app, see `ios/README.md`), `docs/` (design: `docs/game-design.md`).
- iOS project is generated: edit `ios/project.yml`, run `xcodegen generate` in `ios/`, commit the regenerated `Lanvi.xcodeproj`. On a project-file merge conflict take one side and regenerate; never hand-merge it.
- iOS server address and pairing code live only in git-ignored `ios/Config.xcconfig` (template `ios/Config.example.xcconfig`); without it the app runs an offline demo. Public repo: never commit keys, tokens, codes or server addresses.
- iOS screenshots headless: `xcodebuild ... -derivedDataPath build/dd`, then `xcrun simctl launch <device> app.lanvi.Lanvi -screen <name>` and `xcrun simctl io <device> screenshot`; launch arguments are listed in `ios/README.md`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
