# App design

What the iPhone app does, screen by screen, and how it talks to the server. Written on Friday night from what the team decided so far. Working name: **Angel** (not final, Matthew decides).

Who builds what: Peter builds the app, AR and the Apple Health read. Matthew owns the look, the game design and the wording. Mathew builds the server and the mind.

## The idea in one loop

1. **Sense.** The phone already knows how the person moves. The app reads it from Apple Health and sends one record per day.
2. **Respond.** When the server sees a clear change from that person's own normal, the app offers one small action. The main one is a two-minute round in AR: lights appear in the person's own room and they move to catch them.
3. **Learn.** The app reports what the person did. The server learns what helps this person and offers that first next time.

The app never diagnoses. It says "you have moved less than your usual this week", never anything about depression.

## What the app reads from the phone

| Data | Source | Needed |
|---|---|---|
| Steps per day | Apple Health, from the iPhone itself | Yes |
| Walking speed | Apple Health, from the iPhone itself | Yes |
| Heart-rate variability | Apple Health, only with a watch | Optional |
| Sleep hours | Apple Health, only with a watch | Optional |

- On first start the app asks permission and uploads the history the phone already holds, so the server has a real baseline at once.
- After that it sends one record per day, when the app opens.
- Garmin users are covered if Garmin Connect syncs into Apple Health. There is no Garmin code in the app.
- Peter confirms the exact data types and that his developer account allows the Apple Health capability.

## Screens

| Screen | What the person sees | Notes |
|---|---|---|
| **Start** | What the app measures and what it does not. Permission for Apple Health. A pairing code from the clinic. | The pairing code is how the person agrees to share with the clinic. For the demo one code is fixed. |
| **Today** | Most days: "all as usual" and nothing else. On a change: one sentence about what the app noticed and one suggestion. | The app is quiet by default. No streaks, no guilt about a skipped day. |
| **The round** | The room through the camera with lights floating in it. Time left, lights caught, pause, "sit down instead". | See "The AR round" below. |
| **After the round** | "Done." Three answers to the suggestion: I did it, not today, something else. One optional tap: rough, ok, good. | Answers are buttons, not text. |
| **A few words** | A short text box, about 280 characters. The app answers with one short, warm line. | The answer is picked from a fixed set by the server. It is not a chat. If the note suggests the person needs help, the help screen opens at once. |
| **What works for you** | What the app has learned, in plain words, each with a "not true" button. The person's own rules. At most three questions from the app, answered yes, no or not sure. | The person can always correct the app. Their rules always win. |
| **Help** | The app is not an emergency service, and where to get help now. | Reachable from every screen. The text comes from the server so the clinic can set it. Wording to be agreed with the Aalto mentors. |

## The AR round

The round is what the app offers. The phone's daily data stays the main sensor; the round adds a small signal about how the person moved.

- Two minutes. Lights appear around the room, the person walks to each one to catch it, the round ends warmly.
- Three modes: standing in AR, seated in AR, and on the flat screen with no camera. The flat-screen mode is also the fallback if AR does not work in time.
- The app logs each light and the path of the phone and sends one record when the round ends. The full interface is in `docs/game-interface.md`.
- A round can be played any day, not only when the app suggests it.
- An offered round that is not played is recorded too. Ignoring it is also a signal.

**Checkpoint, Saturday mid-afternoon:** lights visible and catchable in a real room on Peter's phone. If not, the round moves to the flat screen.

Stretch goals, only after the loop works: a calm voice during the round, and face tracking as a second optional signal.

## How the app talks to the server

The app talks only to the server, over HTTPS, with a bearer token it gets at pairing. The clinician page and the models are behind the server.

| When | Call | What it does |
|---|---|---|
| First start | `POST /v1/devices/pair` | Exchanges the pairing code for the device token |
| First start, then daily | `POST /v1/daily` | Sends day records; many days in one call for the history upload |
| App opens, and after every round | `GET /v1/today` | Returns the status, one suggestion or none, the round settings and the help text |
| A round ends | `POST /v1/rounds` | Reports the round |
| The person answers a suggestion | `POST /v1/feedback` | Reports the answer |
| The person writes a few words | `POST /v1/notes` | Sends the note; returns the reply line and whether to open the help screen |
| "What works for you" opens | `GET /v1/mind` | Returns rules, lessons and questions |
| The person edits rules or answers | `POST /v1/mind/...` | Adds or removes a rule, rejects a lesson, answers a question |

Status values the app must handle: `no_baseline` (not enough history yet), `within` (as usual), `outside` (a clear change), `no_data` (nothing received for some days).

This table is the draft the server is being built against. The exact fields will be in `docs/api/openapi.json` and `docs/api/README.md` when the server lands in the repo. Until then, treat field names as not final.

## Rules for wording and behaviour

- One suggestion at a time. No repeated reminders.
- Never clinical words. Never a diagnosis.
- Most days the app says nothing.
- "Not today" is a fine answer and is never argued with.
- Everything the person typed stays on the clinic's server. It is never sent to an outside model.
- The help screen is always one tap away.

## What the clinician sees

A web page behind a login, not part of the app: one line per patient, with those outside their own normal on top, a short plain summary, and a progress view per patient. For a case that needs a look today, the clinic gets a short message with no patient data in it, only a label and a link.

## The demo in three steps

1. Show the patient "as usual" in the app, and their line on the clinician page.
2. Switch the demo patient into a dip. The app shows the suggestion, we play the AR round live and answer.
3. Run the learning step. The next suggestion is different, and the clinician page has changed.

The server has a switch for step 2 and a reset, so the demo can be repeated all Sunday.

## Not in the app this weekend

Accounts and passwords, push notifications, settings, Android, a Garmin integration, an open chat.

## Open points

1. Peter confirms which Apple Health values the phone gives without a watch.
2. Matthew decides the name, the look and the round's game design.
3. The help-screen text and the words that trigger it, with the Aalto mentors.
4. A second iPhone with the app installed, as a spare for Sunday.
