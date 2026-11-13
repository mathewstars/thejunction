# thejunction

Team workspace for the Junction hackathon, November 2026.

Team: Mathew, Peter, Matthew. The same three who built [Gridzilla](https://github.com/mathewstars/Gridzilla) at the Energy Bridge Critical Infrastructure Hackathon in Vienna (23–25 October 2026).

## Status

| | |
|---|---|
| Challenge / track | candidate: AstraZeneca, "Equal Care Across Finland" (not decided by all three yet) |
| Idea | draft below, open for changes |
| Demo | none yet |
| Pitch | none yet |

Update this table as soon as something is decided, so all three of us read the same thing.

## Where we are (Friday 13 Nov, evening)

**Read first:** `astrazeneca/CHALLENGE.md` has the brief, the judging weights, the Goal 3 indicators in English and the Junction rules.

**The challenge in three lines.** Find regional gaps in cancer care in Finland from public, aggregate data. Show where on the pathway each gap emerges: detection, referral, diagnosis or treatment start. Recommend concrete actions a wellbeing services county could carry out; they call this the most important part.

**Judging:** actionability 30%, insight 25%, data quality and transparency 20%, live demo 15%, clarity in two minutes 10%.

**Draft idea.** An auditable analyst for county decision-makers:

1. One store of observations: indicator, county, period, value, source link, known limitation.
2. Flags: a county against its own history and against the national level.
3. A county status that is the worst of the four pathway stages, so the screen shows where the gap sits.
4. An AI analyst that turns flags into proposed actions, each with an owner, a target and the indicator that would prove it worked. Every sentence carries its source; reasoning is marked as reasoning.
5. A read-only dashboard and a page that lists every source and its limits.

**Rule that changes our plan: no code written before the event.** All code outside open-source libraries must be written at the event, or the team is disqualified. So the Gridzilla pieces listed below, and patterns from other earlier projects, are reference for how to build, not files to copy. We rewrite here.

**Open, in this order:**

1. Decide the challenge, all three of us.
2. Check that public sources give per-county figures for stage at diagnosis, waiting times, survival and mortality (Cancer Registry statistics, THL Sotkanet, NORDCAN). Not checked yet, and the brief itself warns the data is thin. If the figures are not there, the idea changes.
3. Ask the AstraZeneca mentors: which indicator they trust most, where they see the referral delay, what a county could realistically act on. Medical affairs is at the stand on Saturday during the day.
4. Agree names early: counties, indicators, pathway stages.

**Dates:** final submission Sunday 15 Nov 10:00 with the project set to FINAL, a public video of at most 2 minutes, demo link, source link, pitch deck PDF. Peer reviewing 10:30–14:00, all present.

## What we bring with us

Everything below is in the public Gridzilla repo. Under the Junction rules it is reference only: we may reuse the ideas and the structure, not the code.

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

- `astrazeneca/` — the AstraZeneca challenge "Equal Care Across Finland": brief, judging criteria and Goal 3 indicators in `CHALLENGE.md`, plus the strategy, roadmap and link list they provided.

Suggested once we start building: `docs/` for the pitch, one top-level folder per component.
