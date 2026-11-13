# iOS app

The Xcode project goes here. Peter writes the code, Matthew builds it on his Mac and puts it on TestFlight.

Read first:

- `docs/app-design.md`: the screens and the calls to the server.
- `docs/game-interface.md`: what the app logs during an AR round and the record it sends.

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
