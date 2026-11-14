# App design

What the iPhone app does and why, in the fox design. Short on purpose. The game detail is in `docs/game-design.md` (Matthew). The calls are in `docs/app-api.md`. What the app code holds today is in `ios/HANDOFF.md` and `ios/SENSORS.md`.

The product is **Lanvi**, a small Arctic fox on the phone, for people at home after TMS treatment for depression. This page replaces the earlier design, an AR round where the person walked to lights in the room. That round is cut.

Who owns what: Matthew the app, the fox, the games and the wording. Peter the sensors (Apple Health, the face frames). Mathew the server, the clinician page and these documents.

## The idea in one loop

1. **Sense.** The phone already counts how the person moves and sleeps. The app reads daily totals from Apple Health and sends them. During two short activities it can also send how the face moved, as numbers.
2. **Respond.** The server compares each day with that person's own normal. When it sees a clear change, Lanvi offers one small thing: a minute of breathing, a short game, a walk, some daylight, a message to someone, an evening check-in.
3. **Learn.** The app reports what the person did. The server learns what suits this person and offers that first next time. The person can see what it learned and say "not true".

The app never diagnoses. The server's sentence is "Your movement has been lower than your usual for a few days", never a word about depression.

## What the app reads from the phone

| Data | Source | Needed |
|---|---|---|
| Steps per day | Apple Health | Yes |
| Walking speed | Apple Health | Optional, sent when the phone has it |
| Heart-rate variability | Apple Health, only with a watch | Optional |
| Hours asleep | Apple Health, only with a watch | Optional |
| Face movement during Sparks and snow and Breathe with Lanvi | Front camera (ARKit), about 30 times a second | Optional, asked once, can be switched off on the Help screen |

- First run: the app asks for Apple Health in Lanvi's voice and sends the history the phone holds, up to 400 days. After that it sends the missing days on every open.
- The server needs 14 days before it knows a person's normal.
- Face: numbers only leave the phone. No picture, video or face mesh is kept or sent. A phone without Face ID sends nothing and the games are unchanged.
- Both questions can be skipped and the app works the same.

## Screens

Taken from the code in `ios/Lanvi/`. Matthew judges the look; this table is only what each screen is for.

| Screen | What the person sees |
|---|---|
| **Welcome** | "You did the hard part. Lanvi helps it last." |
| **What helps** | Music, Moving, People, Quiet. Up to four, in the order tapped. Lanvi answers with one line. Can be skipped. |
| **Apple Health, then the face question** | One question each, asked once. The face question comes before the first game: "May I watch your face while we play?" with "Not now" as an equal answer. |
| **Home** | A painted scene with Lanvi in the middle, one line of speech, and one thing for today: the server's suggestion, else a pick by time of day. Not a menu. Help is in a corner. The three activities are always reachable one tap further. |
| **Sparks and snow, Breathe with Lanvi, Evening check-in** | See below. |
| **The XP moment** | After an activity: "+10 XP", the growth bar, Lanvi's line. Sometimes Lanvi grows up or runs off to wander. |
| **A story** | When Lanvi is back from a wandering: a few sentences and one question with two answers. |
| **Chat** | A thread with Lanvi for today. Every reply comes from the server. If the words ask for help, the Help screen opens at once. |
| **How Lanvi is growing, and what Lanvi noticed** | The stage, a bar to the next one, days together, and what the server learned in plain words, each with "Not true". Up to three questions, answered yes, no or not sure. |
| **Help** | The app is not an emergency service, and who to call. The text comes from the server so the clinic can set it. Also the switch for the face. |

There is no pairing screen. The pairing code is put into the build (`ios/Config.xcconfig`, never committed). With no server set, the app runs on sample data.

## The three activities

| Activity | Length | What it is | What the app sends |
|---|---|---|---|
| **Sparks and snow** (focus) | 45 seconds | Tap the sparks, let the snowflakes fall. | Taps, wrong taps, misses, reaction times, face numbers |
| **Breathe with Lanvi** | About a minute, 6 breaths | Breathe in and out with a light behind Lanvi. No winning or losing. | Time played, breaths completed, face numbers |
| **Evening check-in** | About a minute, once a day | Three good things from today (tap or type), one small nice thing for tomorrow. Next evening Lanvi asks if it happened. | The chosen items, the plan, the answer about yesterday's plan |

An activity can be played any day, not only when Lanvi suggests it. Rules, timings and the reasons behind each: `docs/game-design.md`.

## Rules for wording and behaviour

- **No score.** XP is for showing up. A game played badly or stopped early earns the same as a perfect one.
- **No streak.** Nothing counts days in a row. "Days together" only goes up. After a gap Lanvi says "I kept the light on for you."
- **A bad day never costs anything.** XP never goes down and the stage never goes back.
- **Nothing about mood or the face is shown to the person.** Those measures go to the server and the clinician page only. Lanvi never says "you look sad".
- **Never a sad fox.** Lanvi does not dim, get sick or look sad because of the person.
- One suggestion at a time. "Not today" is a fine answer and is never argued with.
- Never clinical words. Never a diagnosis.
- The Help button is one tap away. Words that ask for help open it by themselves.
- What the person types stays on the clinic's server. One exception, off by default: the server's chat mode, where a message that did not open Help goes to Gemini so it can write Lanvi's reply (`docs/api/README.md`, "Free text").
- Every sentence Lanvi says comes from the server (`engine/clinic_engine/data/lanvi_lines.json`), so the clinic can change the wording. No clinician has reviewed it yet.

## What the clinician sees

A web page behind a login, not part of the app. One line per patient, those who need a look on top, each compared with their own normal. Per patient: the days as a chart, the activities with their numbers (reaction time, time played, good things, the face measures and how well the face was tracked), what the person wrote and what Lanvi answered (the words only if the patient's record allows it), every decision the server made and why, and a research view. For a case that needs a look today the clinic can get a short message with a label and a link and no health data in it (Telegram; off unless set up).

## The demo in three steps

Before the demo the example patient is put into a dip with a switch on the clinician page. A reset puts it back, so the demo can be repeated.

1. **Phone.** Lanvi offers one small thing. We play it for a few seconds.
2. **Phone, then the clinic's phone.** We type a few words that ask for help. The Help screen opens by itself and the clinic gets its message.
3. **Clinician page.** The patient is on top of the list. We show the days against the person's own normal, what was written and answered, and what the server decided and refused.

The full run, with times and fallbacks, is `docs/demo-script.md`. Its status there is "a draft, not rehearsed".

## Not in the app this weekend

The AR round. Accounts and passwords. A screen to type the pairing code. Push notifications. Android. A Garmin integration (it works only if Garmin Connect writes into Apple Health; not tested). Live heart data from a watch. A screen where the person gives or withdraws consent for outside processing. The person's own rules (the server has them, the app does not). Naming the fox and choosing a tail colour (in `docs/game-design.md`, not in the app or the server).

## Open points

1. **Matthew:** the handbook says no light or glow on the fox's tail. The server's lines still say "my tail glows" in several places, and `docs/game-design.md` describes a glowing tail. Which stays?
2. **Matthew and the Aalto mentors:** the Help text and the word list that opens it are drafts.
3. **Peter:** the face capture on a real phone (the list in `ios/SENSORS.md`). ARKit face tracking does not run in the simulator.
4. **All:** a second iPhone with the app installed, as a spare for Sunday.
5. **All:** with real patients, sending face numbers or chat words to Gemini needs their consent and an agreement with the provider. In the demo it is example data.
