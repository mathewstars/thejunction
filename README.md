# thejunction

Team workspace for the Junction hackathon, November 2026.

Team: Mathew, Peter, Matthew. The same three who built [Gridzilla](https://github.com/mathewstars/Gridzilla) at the Energy Bridge Critical Infrastructure Hackathon in Vienna (23–25 October 2026).

## Status

| | |
|---|---|
| Challenge / track | Aalto University, "Beyond the Clinic". Tech track: Google DeepMind, Gemini API. AstraZeneca and Valio Aimo are dropped. |
| Idea | draft below, open for changes |
| Demo | none yet |
| Pitch | none yet |

Update this table as soon as something is decided, so all three of us read the same thing.

## Where we are (Friday 13 Nov, late night)

**Read first:** `aalto/CHALLENGE.md` has the brief, the judging weights and what Aalto provides. `docs/app-design.md` has the app screen by screen and the calls to the server.

**The challenge in three lines.** People with severe depression get brain stimulation (TMS) in daily clinic visits. When the visits end they are at home with no scans and no psychiatrist, and the depression can return. Aalto wants a product that helps them stay well at home, best as a loop: sense how the person is doing, respond with something that helps, learn what works for that person.

**Judging:** usefulness 25%, ease of use 25%, smart sensing 25%, creativity 25%. The prize is not announced yet.

**Draft idea (working name Lanvi, domain lanvi.app; Matthew decides the final name).** One loop, three parts:

1. **Sense.** The phone already knows how the person moves: steps and walking speed from Apple Health, plus heart-rate variability and sleep when a watch is there. The server compares each day with that person's own normal.
2. **Respond.** On a clear change the app offers one small action. The main one is a two-minute round in AR: lights appear in the person's own room and they move to catch them.
3. **Learn.** Whether the person did it, and how the next days went, decides what the app offers next time. An offered round that is not played is recorded too.

A clinician sees one line per patient: who is outside their own normal this week.

The person can also write a few words. The server only turns them into a few fixed labels and answers from a fixed set; it is not a chat. If the words suggest the person needs help, the help screen opens at once and the clinic gets a short "needs review" message.

**Checked with the Aalto mentors on Friday night:** they like the AR game idea.

**Decided on Friday night:** the AR round stays, as the response and not as the sensor. iOS only. Face tracking is a stretch goal. Peter has a checkpoint on Saturday mid-afternoon: lights visible and catchable in a real room, otherwise the round moves to the flat screen.

**Who does what**

| Who | Part |
|---|---|
| Peter | Coding the app: AR, the round, Apple Health, the calls to the server |
| Matthew | Design, naming and presentation; builds the iOS app on his Mac and puts it on TestFlight |
| Mathew | The server and the "mind" logic |

**How it fits together**

```
iPhone app                    Server (one small service)            Web page
daily movement data  --POST-> store the day                         clinician list
from Apple Health     daily   compare with own baseline    --GET--> who is outside
show today's         <-GET--  pick one action, word it              their own normal
suggestion            today   review: lessons, questions
AR round, feedback   --POST-> remember what was followed
```

**In scope for the weekend:** the daily read from Apple Health, the baseline and deviation on the server, the AR round, a feedback tap that changes the next suggestion, the clinician page with a simple login, one static crisis screen.

**Out of scope:** doctor onboarding, patient accounts, push notifications, settings, Android, a Garmin integration (Garmin users reach us through Apple Health). One hard-coded demo patient. A seed script adds example patients, labelled as example data.

**Where it runs:** the engine on our own server behind an HTTPS proxy, with an S3-compatible object store (RustFS) for the data. Host names, addresses and passwords stay in `.env` on the server.

**Tech track: Google DeepMind, "Best Use of Gemini API".** Two model levels:

| Level | Model | Job |
|---|---|---|
| 1 | A local open model on hardware we control | Everyday work: words the daily suggestion from the action the code picked |
| 2 | Gemini API | The review: reads the recent rounds and feedback, writes lessons and at most three questions, and the plain-language summary for the clinician |

Level 1 is served with a standard open-source model server, not through any private gateway of ours. Level 2 gets numbers without a name or any other identity. If a model is not reachable, a fixed-template suggestion is the fallback. If level 1 runs a Gemma model, the same build can also enter "Best Use of Gemma"; not decided.

**Rule that changes our plan: no code written before the event.** All code outside open-source libraries must be written at the event, or the team is disqualified. A project related to an already existing company is disqualified too. Patterns from earlier projects are reference for how to build, not files to copy. We rewrite here.

**Open, in this order:**

1. Agree the records between the app and the server, field by field: the day, the round, the feedback.
2. Ask the Aalto mentors: which movement signals from a phone they trust, what the app must show when someone is in crisis, which open datasets they point to.
3. Decide where the server and the model run for the demo: a laptop at the venue or a machine at home.
4. Matthew decides the name.

**Dates:** final submission Sunday 15 Nov 10:00 with the project set to FINAL, a public video of at most 2 minutes, demo link, source link, pitch deck PDF. Peer reviewing 10:30–14:00, all present.

## What we bring with us

Under the Junction rules everything here is reference only: we may reuse the ideas and the structure, not the code.

**The agent-and-gate pattern (from an earlier project of ours).** Written for the Valio Aimo idea; the gate and the grounding check still apply to what the model may say to a patient:

| Pattern | What it does | Where it goes in the Valio Aimo build |
|---|---|---|
| Two model tiers | A cheap model triages and looks things up, a strong model decides | Lookup against order decision |
| Code gate | One function that every action passes: caps, allowed actions, dry run unless armed, "no plan, no order" | Spend limits and approval rules |
| Code proposal as fallback | The code makes its own safe proposal; the model may only choose inside the limits | Partial availability and substitutions when the model is silent or wrong |
| Grounding check | A number that is not in the data the model was given is refused | Trust in price and stock claims |
| Read-only tool registry | One list of tools, served to every model over MCP | The open interface |
| Human in the loop | Approve or stop from the phone; the human can always stop | Sign-off |
| Audit and replay | Every decision is logged and can be replayed | Audit trail |

**Gridzilla.** Everything below is in the public Gridzilla repo.

**Gridzilla in one paragraph.** A grid signaling platform for grid-serving storage. A grid operator (DSO) sees a transformer or feeder about to overload and sends a signed, bounded, segment-scoped signal that tells the home batteries in that segment how much the house may import or export for a limited time. The signal always ends in a local policy agent that merges it with the owner's own limits before anything is written to the inverter, so the operator never gets raw control of a device.

**Working pieces to learn from**

| Piece | Where in Gridzilla | What it does |
|---|---|---|
| Signal protocol | `protocol/` (PROTOCOL.md, JSON schemas for signal, envelope, ack) | Signed envelopes, sequence numbers, scoped addressing, signed acks and refusals |
| Platform | `platform/` (Python, FastAPI) | Device registry, signal composer, policy guard, signing, MQTT publish, audit, history |
| Agents | `agent/` (Node sim fleet, Node-RED flow generator for Victron Cerbo GX) | Verify, scope, merge with owner limits, heartbeat, revert |
| Advisor | `platform/` | Deterministic rule advisor, or an LLM advisor that only turns bounded knobs |
| Console and site | `dashboard/`, `site/` (React, Vite) | Operator console and public site |
| Pitch material | `docs/` (deck, trailer, architecture page, presentation notes) | The structure that worked on stage |

Live: https://gridzilla.victronlab.sk (site at `/`, operator console at `/console`).

**Domain knowledge on the team:** Victron and GoodWe storage systems, ESS control, Node-RED on Venus OS, MQTT, Modbus, heat pumps and EV charging as flexible loads, tariff and spot-price optimisation with an LP planner, trust and security of a remote control channel.

## What worked last time

- Build a real, running thing by the first night, then spend the rest on the story.
- One live demo on real hardware beats ten slides, but keep a simulated twin so the demo never depends on the weather or the battery state.
- Backend and UI stay separate, and state persists across redeploys. Never restart the demo fleet right before the pitch.
- The pitch opens with the problem in thirty seconds and one number people remember.
- Agree on names early (devices, segments, topics) and do not rename them later.

## Ground rules for this repo

- **Public repo. No secrets, ever:** no tokens, passwords, keys, private IPs or hostnames, personal phone numbers or emails. Use `.env` (git-ignored) and commit a `.env.example`.
- Small commits straight to `main` are fine during the hackathon; use a branch for anything that could break the demo.
- Write decisions into this README, not only into chat.

## Layout

- `docs/app-design.md` — the app screen by screen, the AR round, and how the app talks to the server.
- `docs/game-interface.md` — what ARKit gives the app, the round record the app sends, what the server makes of it, and where the two model levels come in.
- `engine/` — the server and the mind, with its tests. It runs on the demo server at https://lanvi.app.
- `docs/app-api.md` — how the app and the server talk, call by call, with real examples. Written for Peter to review.
- `docs/api/` — the API: `openapi.json` and a short guide for the app.
- `ios/` — the iPhone app. The Xcode project goes here.
- `LICENSE` — MIT, as Junction requires for every submission.
- `aalto/` — our challenge, Aalto "Beyond the Clinic": brief, judging criteria and what they provide in `CHALLENGE.md`.
- `valioaimo/` — dropped on Friday night. The Valio Aimo brief, kept for the record.
- `astrazeneca/` — dropped on Friday night. The AstraZeneca brief and the material they provided, kept for the record.
- `facemetrics/` — FaceMetrics, a native iOS ARKit facial-tracking research instrument (Swift, SwiftUI, ARKit, SceneKit). Xcode project, not yet compiled on a Mac. See `facemetrics/README.md`.

Suggested once we start building: `docs/` for the pitch, one top-level folder per component.
