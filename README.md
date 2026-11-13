# thejunction

Team workspace for the Junction hackathon, November 2026.

Team: Mathew, Peter, Matthew. The same three who built [Gridzilla](https://github.com/mathewstars/Gridzilla) at the Energy Bridge Critical Infrastructure Hackathon in Vienna (23–25 October 2026).

## Status

| | |
|---|---|
| Challenge / track | not chosen yet |
| Idea | open |
| Demo | none yet |
| Pitch | none yet |

Update this table as soon as something is decided, so all three of us read the same thing.

## What we bring with us

Everything below is public and reusable from the Gridzilla repo.

**Gridzilla in one paragraph.** A grid signaling platform for grid-serving storage. A grid operator (DSO) sees a transformer or feeder about to overload and sends a signed, bounded, segment-scoped signal that tells the home batteries in that segment how much the house may import or export for a limited time. The signal always ends in a local policy agent that merges it with the owner's own limits before anything is written to the inverter, so the operator never gets raw control of a device.

**Working pieces we can lift**

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

- `astrazeneca/` — the AstraZeneca challenge "Equal Care Across Finland": brief, judging criteria and Goal 3 indicators in `CHALLENGE.md`, plus the strategy, roadmap and link list they provided.

Suggested once we start building: `docs/` for the pitch, one top-level folder per component.
