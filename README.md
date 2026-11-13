# thejunction

Team workspace for the Junction hackathon, November 2026.

Team: Mathew, Peter, Matthew. The same three who built [Gridzilla](https://github.com/mathewstars/Gridzilla) at the Energy Bridge Critical Infrastructure Hackathon in Vienna (23–25 October 2026).

## Status

| | |
|---|---|
| Challenge / track | Valio Aimo, "Trusted Trade Agents". AstraZeneca is dropped. |
| Idea | draft below, open for changes |
| Demo | none yet |
| Pitch | none yet |

Update this table as soon as something is decided, so all three of us read the same thing.

## Where we are (Friday 13 Nov, night)

**Read first:** `valioaimo/CHALLENGE.md` has the brief, the judging weights and what Valio Aimo provides.

**The challenge in three lines.** Valio Aimo is a food-service wholesaler. They want the interface and the rules through which an external purchasing agent can look up products, prices and availability, place an order, and get human approval where it is needed. Everything runs against their mock APIs with synthetic data.

**Judging:** working end-to-end demo 30%, solving the buyer's need 20%, autonomy and controls 20%, robustness to exceptions 15%, openness and path to production 15%.

**Why we switched from AstraZeneca.** We have built this shape before: an agent that proposes and a code gate that decides. The mock APIs and data are already published, so there is no data risk. The first prize is 4,000 € against 1,000 €.

**Draft idea.** A purchasing agent on a leash:

1. A read-only tool layer over the Valio Aimo mock APIs (search, price, availability, delivery time, labels), served over an open standard so any agent can use it.
2. The agent proposes an order. It never places one by itself.
3. A code gate decides, not the model: spend limit, allowed categories, allergen rules, substitutions only inside the buyer's stated preferences, dry run unless armed. Inside the limits the order goes through. Outside them it goes to a human.
4. Human approval in one tap, with the reason and the alternatives ("good, better, best" when the exact product is short).
5. A grounding check: every price and quantity in an answer must come from an API result of this session, or the answer is refused.
6. An audit trail a human can read: what was asked, what was found, what the gate allowed or stopped, who approved.

**Rule that changes our plan: no code written before the event.** All code outside open-source libraries must be written at the event, or the team is disqualified. So the Gridzilla pieces listed below, and patterns from other earlier projects, are reference for how to build, not files to copy. We rewrite here.

**Tech challenges we can enter with the same project** (they stack on the main challenge):

| Tech challenge | Role in our build | Prize |
|---|---|---|
| Google DeepMind, Gemma | Cheap first tier: triage and product lookup | 1,000 € each to three teams |
| Google DeepMind, Gemini API | Second tier: the order decision and its explanation | 4,000 € + cloud credits, 2,000 €, 1,000 € |
| Aiven | Postgres for the audit trail and the event log | 1,000 €, 750 €, 500 € |
| NVIDIA Nemotron (in place of Gemma) | First tier with tool use | An RTX 5080 for each of two teams |

**Open, in this order:**

1. Open the resource portal, read the API documentation and run one lookup against the mock API.
2. Ask the Valio Aimo mentors: which approval rules a real kitchen buyer has, what a substitution may change, and which open standard they would accept.
3. Decide the two models and which tech challenges we enter. Ask the info desk if there is a limit.
4. Agree names early: tools, order states, gate rules, approval reasons.

**Dates:** final submission Sunday 15 Nov 10:00 with the project set to FINAL, a public video of at most 2 minutes, demo link, source link, pitch deck PDF. Peer reviewing 10:30–14:00, all present.

## What we bring with us

Under the Junction rules everything here is reference only: we may reuse the ideas and the structure, not the code.

**The agent-and-gate pattern (from an earlier project of ours).** This is the closest thing we have to the Valio Aimo task:

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

- `valioaimo/` — our challenge, Valio Aimo "Trusted Trade Agents": brief, judging criteria and what they provide in `CHALLENGE.md`.
- `astrazeneca/` — dropped on Friday night. The AstraZeneca brief and the material they provided, kept for the record.

Suggested once we start building: `docs/` for the pitch, one top-level folder per component.
