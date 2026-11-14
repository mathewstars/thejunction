# Revontulet ("fox fires")

A 90-second game with no way to lose. It replaces Sparks and snow as the `focus` activity. Code: `ios/Lanvi/Screens/Revontulet/`. Switch back to Sparks and snow: `ActivityRouter.focusIsRevontulet = false`.

The scene: the painted night world (always night). A tall pane of dark frozen glass stands between the fox and the sky; the aurora behind it shows only dim and blurred. The fox sits in front of it on the snow.

## The beats and the study idea behind each

| Beat | What happens | Study idea |
|---|---|---|
| Choice (3 rounds) | Two fault lines light up: a thin low crack (one shot, a small warm glow) and a thick crystalline vein higher up (two embers on the way, a big burst of aurora). Tap one. | Effort-based choice (after the EEfRT paradigm): picking the bigger effort for the bigger reward, and how long the choice takes. |
| Trace | A glowing half-circle around the spark; trace it in one stroke and the light fills behind the finger. A quarter turn each round (bulging left, up, right). Lifting early keeps the charge. | A validated single-stroke drawing task: stroke speed, smoothness and lifts as a window on psychomotor speed. |
| Sling | Pull the charged spark back (threads of light stretch, tension rises in the hand), let go. The aim is helped: it cannot miss. | Pull distance and hold time. |
| Flight | The spark arcs up with a trail. On the vein, two embers flash on its path in rhythm; tapping each lights it. Missing costs nothing; lighting both gives more than promised, sometimes an extra ribbon of aurora. | Reaction times; a reward that can beat the expectation and never fall short of it. |
| Impact | Cracks race out, a ragged piece falls away, the sky behind is brighter. The fox flinches, then looks pleased. | |
| Breakthrough | The third impact bursts the wall into its pieces (about 60), which turn, catch the aurora on their edges, fall and fade; the aurora sweeps the sky; the fox celebrates. Then 3 seconds with the fox large and clear and nothing to touch. | Pleasant moments for the smile response (face frames). |
| Warmth | The view eases in on the fox; snow lies on its fur. Three slow strokes brush it off; the phone purrs, warmer when slow; the fox leans into the hand. | Slow gentle touch; stroke speed and length. |
| Sleep | After the third stroke, or at 1:28 at the latest, the fox yawns and falls asleep, the aurora softens, the game hands back. | A preset time limit. |

Nobody is left behind: no fail state, timer, score or counter. From 1:05 the next impact breaks the wall whatever the round; at 1:12 a wall still standing is broken by the fox's own spark. Everyone sees the aurora and gets at least 10 seconds with the fox. Closing early is allowed any time and is recorded as stopped by the person.

## Moments it announces (`GameMoments`, activity `focus`)

`revontuletStarted`, `effortChosen(round:effort:)`, `traceStarted(round:)`, `traceEnded(round:)`, `slingReleased(round:)`, `emberHit(reactionMs:)`, `emberMissed`, `iceImpact(round:)`, `iceShattered`, `foxCelebrates`, `foxStroked(number:)`, `revontuletEnded(finished:)`. Rounds and strokes count from 1. Pleasant moments (`FaceSense.mark()`, as `ios/SENSORS.md` describes) at the instant of the burst and the instant the fox's celebration starts. Face frames come from `FaceSenseHost`, one session per game, as for Sparks and snow.

## What it measures (`RevontuletResult`, stays on the phone)

Every instant is kept as a date and as `CACurrentMediaTime()` seconds (the face frames' clock). Touches come from UIKit with their own timestamps and every coalesced sample.

- The game: start and end, completed or stopped, when the wall burst and the celebration began, whether the fox's own spark finished the wall, surprise ribbons.
- Per round: easy or hard; decision time (fault lines lit to the tap); the half-circle appearing and the first touch on it; trace duration (first touch to the end), length of the finger's path, mean speed (path over finger-down time), peak speed (smoothed), lifts, mean `UITouch.majorRadius`; pull distance (spark, after the soft limit) and the farthest the finger went, hold time; launch time; embers shown, and per ember lit its reaction time and instant; impact time.
- Per stroke: start, duration, length, mean and peak speed, how much of it went downwards, mean touch radius.

## How it reaches the server (`focus` record plus the `revontulet` object)

| `focus` field | From the game |
|---|---|
| `correct_taps` | launches + embers lit |
| `wrong_taps` | 0 (there is nothing wrong to tap) |
| `misses` | embers that flashed and passed |
| `reaction_ms` | only the ember taps, flash to finger (each 0 to 10,000); an easy-only game sends `[]` |
| `duration_s`, `completed`, `ended_by` | as for every activity; leaving the app mid-game is `interrupted` |

Everything else rides in one optional object, `revontulet`, fixed by the contract agreed with the server side (`data/lanvi-game-data/contract.md` in the firstmate home). Built in `RevontuletMeasures.swift`; every value is clamped to the contract's range.

| Field | What |
|---|---|
| `rounds[]` | per round where a line was picked: `effort` (`easy`/`hard`), `choice_ms`, `trace_start_ms` (half-circle appearing to the first touch; left out when a first-time coach showed the move), `trace_ms`, `trace_length_pt`, `trace_mean_speed_pt_s`, `trace_peak_speed_pt_s`, `trace_lifts`, `pull_pt`, `pull_hold_ms`, `embers_shown`, `embers_hit`, `bonus` (the surprise ribbon) |
| `strokes[]` | `ms`, `length_pt`, `mean_speed_pt_s` |
| `broke_through_s` | start to the wall bursting |
| `fox_finished` | the fox's own spark broke the wall at 1:12 |
| `pt_per_cm` | 60.4 on 3x iPhones, 64.2 on 2x (from the display scale) |
| `touch_radius_mean_pt`, `touch_radius_var` | `UITouch.majorRadius` over the whole game; left out from the auto-play |

**Safe fallback.** The live server refuses unknown fields until dad's change goes live. If a record carrying `revontulet` is refused, `LanviClient.send` sends the same record (same id) once more without it, and the rest of that app run sends records plain straight away; the next launch tries again (`RevontuletSendGate`). The outbox sends through the same function, so a refused record never gets stuck. Tests: `LanviTests/RevontuletMeasuresTests.swift` (the JSON matches the contract's example key for key; the fallback). Lines touched in `Net/`: one optional property on `API.ActivityIn` (`APIModels.swift`) and the body of `LanviClient.send`.

## Testing without a finger (launch arguments)

- `-screen revontulet` opens the game directly (one line in `App/LanviApp.swift`). Always add `-offline`.
- `-revontuletAuto` plays itself from Start to sleep through the engine's own inputs, with a soft finger dot. `-revontuletAuto hard`: the vein every round, every ember lit. `-revontuletAuto easy`: the crack twice, then the vein with both embers missed. `-revontuletAuto idle`: Start, then nothing (the clock breaks the wall, the fox finishes it, it falls asleep).
- `-revontuletFreeze <beat>`: opens frozen on one beat for stills: `intro`, `choice`, `trace`, `sling`, `flight`, `impact`, `burst`, `celebrate`, `warmth`, `sleep`.

## Feel

Haptics only, no sound, all in `RevontuletFeel.swift` with every number in one table (`RevontuletTune`) so it can be retuned after feeling it on a phone. The engine starts with the game and stays on (no auto shutdown), every pattern is built once, and hits whose time is known (embers flashing, the impact, the burst) are scheduled on the haptic engine's clock the moment they are certain, so they land on the frame they are drawn. It stops when the app leaves the foreground and does nothing where haptics are missing.

## Files

| File | What |
|---|---|
| `RevontuletModel.swift` | Beats, inputs, events, the layout, the flight path, the result |
| `RevontuletEngine.swift` | The game as a plain value: inputs and the clock in, state out (no SwiftUI) |
| `RevontuletAutoPlay.swift` | The pretend finger |
| `RevontuletArt.swift` | The ice's fracture pieces, cracks, snow on the fur |
| `RevontuletPainter.swift` | Drawing: aurora, ice, shards, spark, embers, half-circle |
| `RevontuletFox.swift` | The fox (one swap point each for the celebration and sleep clips) and the touch layer |
| `RevontuletFeel.swift` | Haptics |
| `RevontuletView.swift` | The screen |
