# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Three parts: `engine/` (Python server, run and API in `docs/api/README.md`), `ios/` (Lanvi iPhone app, see `ios/README.md`), `docs/` (design: `docs/game-design.md`).
- iOS project is generated: edit `ios/project.yml`, run `xcodegen generate` in `ios/`, commit the regenerated `Lanvi.xcodeproj`. On a project-file merge conflict take one side and regenerate; never hand-merge it.
- Linking is off for now: a build with no pairing code connects anyway and the server puts every phone on one shared test profile (`ServerConfig.openLinkingCode` in the app, `OPEN_PAIRING_PATIENT` on the server; undo both to bring one-time codes back). A real code, when used, lives only in git-ignored `ios/Config.xcconfig` (template `ios/Config.example.xcconfig`). Public repo: never commit keys, tokens, codes, logins or server addresses; the root `README.md` says whom to ask for the demo login.
- Sensors (Apple Health, raw face frames): `ios/SENSORS.md`. Peter's harness files live unchanged in `ios/Lanvi/Sense/Peter/`, built as the separate `Harness` framework target; change them only in step with his `harness/`.
- iOS screenshots headless: `xcodebuild ... -derivedDataPath build/dd`, then `xcrun simctl launch <device> app.lanvi.Lanvi -screen <name> -senseScreen off` (without it the Apple Health ask covers the screen) and `xcrun simctl io <device> screenshot`; launch arguments are listed in `ios/README.md`.
- No `.metal` files: Xcode here has no Metal Toolchain, so a shader breaks every teammate's build. The fox (`ios/Lanvi/Mascot/`) gets its depth from layers cut by `ios/tools/cut_puppet_parts.py` and moves only with transforms; `ios/tools/motion_check/` measures its motion without a simulator, `ios/tools/seam_check/` shoots the extreme head turns and wobbles and makes 4x sheets of every seam. Every moving layer carries a rim of its own fur wider than its largest slide, and the part under it is filled only where the marking was (grown in from the fur at its edge), so a slide never uncovers a pale fill.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
