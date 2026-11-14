# Lanvi: the rescue (game design for Peter)

A proposal from Mathew, written on Saturday 14 November. It adds one idea on top of `docs/game-design.md`, which stays Matthew's and stays the base. Nothing here removes or changes his rules. Matthew decides whether it goes in; Peter, this tells you what it would mean in the app and what to build first.

## The idea in one paragraph

The person does not get a mascot. They find a small Arctic fox kit that was left alone in the snow, and they take care of it. Every small thing the app asks for is something they do for Lanvi: play with him, breathe with him, tell him about the day. People who cannot do a thing for themselves will often still do it for an animal. And while they look after him, he keeps watch over them: the caring is where the phone's measurements come from. The last beat of the story is the turn: you thought you were saving a fox, and he kept the light on for you.

## Why change anything

- The judges, and later the patients, should feel something in the first ten seconds. A rescued animal does that; a cute mascot does not.
- It gives every activity a reason. "Play Sparks and snow" becomes "Lanvi wants to chase sparks".
- It is the same story in the app, in the pitch and in the research video.

## The one rule that makes it safe

**He is rescued once, at the start. After that he is safe for good.**

Lanvi never gets hungry, cold, sick or sad because the person missed a day, and never looks abandoned again. A fox that suffers when a depressed person cannot get up would be cruel and would drive people away. This is already Matthew's rule ("Lanvi never dims, gets sick, dies or looks sad because of the person"). The rescue changes where he comes from, not what happens later.

So: no hunger meter, no "Lanvi misses you", no countdown. After a gap he still says "I kept the light on for you."

## What changes, screen by screen

### Onboarding (replaces steps 1 and 2, the rest stays)

| Step | Now | With the rescue |
|---|---|---|
| 1 | Snowy night, a faint glow in the snow. | The same scene. The glow is a fox kit curled up alone, snow on his fur. One line: "Someone has been left out here." |
| 2 | A sleepy kit wakes up. "Hi, I'm Lanvi." Name and tail colour. | The person holds a finger on him to warm him (about three seconds; the glow slowly comes back to his tail). He opens his eyes. "…you stayed." Then name and tail colour, as now. |
| 3 to 7 | What helps, Apple Health, camera, first breath, home. | Unchanged. The first breath becomes "Breathe with me. I'm still a bit cold." |

That hold-to-warm gesture is the whole rescue. It takes ten seconds and it is the moment people will remember.

### Home

- Lanvi lives on his snowy hill, as now. Add one small thing: a lantern beside him that is always lit. It never goes out. It is the "light" in "I kept the light on for you", and it is what the person sees first after a gap.
- The daily suggestion keeps coming from the server (`lanvi.line` in `GET /v1/today`). Only the wording moves into the care frame; see the lines below. No app change.

### The three activities, same mechanics, new reason

| Activity | Mechanics | What Lanvi says before | What happens after |
|---|---|---|---|
| Sparks and snow | Unchanged | "I want to chase sparks. Come?" | He catches the last spark in his mouth and his tail brightens. |
| Breathe with Lanvi | Unchanged | "Sit with me a minute?" | He settles against the edge of the screen and sleeps for a moment. Small aurora, "Nice." |
| Evening check-in | Unchanged | "Tell me three good things. I'll keep them." | He tucks them under the lantern. Tomorrow he asks about the plan. |

Nothing in the records the app sends changes. XP stays as it is.

### Growing up, told as trust

Same three stages and the same XP thresholds; only the names and the look of each stage change.

| Stage | XP | What you see |
|---|---|---|
| Found | 0 | Small, stays close to the lantern, tail glow faint. |
| At home | 100 | Runs across the hill, comes when the app opens. |
| Free | 300 | Tail paints small northern lights. He goes on wanderings and always comes back. |

"He always comes back" is the point of the wanderings now: he is free and chooses to return.

### The turn: when the person has a hard day

This is the part that carries the pitch, and it needs almost no new code.

- When the server's answer to a note or a check-in has `crisis: true`, the help screen opens as it does today. Behind it, Lanvi comes to the front of the screen and sits facing the person, lantern beside him. One line: "My turn. I'm staying."
- When `GET /v1/today` carries an attention level (the phone does not show the level itself), Lanvi's daily line comes from a gentler set: "Slow day? I'll sit with you." No change in what is offered; only the wording.

He never says he knows how the person feels. He stays; that is all.

## Lines (drafts, for Matthew to rewrite)

Server-side lines live in `engine/clinic_engine/data/lanvi_lines.json`, so wording can change without an app release. In-app lines (onboarding) are Peter's strings.

| Where | Line |
|---|---|
| Onboarding 1 | "Someone has been left out here." |
| Onboarding 2, after warming | "…you stayed." |
| First breath | "Breathe with me. I'm still a bit cold." |
| Focus offer | "I want to chase sparks. Come?" |
| Breathing offer | "Sit with me a minute?" |
| Check-in offer | "Tell me three good things. I'll keep them." |
| After a gap | "I kept the light on for you." (already there) |
| Back from a wandering | "I went far. I came back." |
| Hard day | "Slow day? I'll sit with you." |
| Help screen open | "My turn. I'm staying." |

## What Peter would build, in order

Time is short, so in strict order. Stop wherever Sunday morning arrives.

| # | What | Size | Why first |
|---|---|---|---|
| 1 | Onboarding step 1 and 2: the kit alone, hold to warm, "…you stayed." | Half a day at most: one scene, one long-press, one animation of the tail glow | It is the ten seconds the video and the stage demo open with. |
| 2 | The lantern on Home, always lit | Small: one sprite | Makes "I kept the light on" visible. |
| 3 | Lanvi comes forward behind the help screen with "My turn. I'm staying." | Small: one pose, one line, triggered by `crisis: true` | It is the emotional peak of the demo, and the trigger already exists. |
| 4 | After-activity moments (catches the spark, settles, tucks the good things under the lantern) | Medium: three short animations | Nice, not needed for the demo. |
| 5 | Stage names and looks | Small if the art exists | Only if Matthew has the art. |

Server work for all of this is wording only, and that is mine: tell me which lines Matthew approves and I change the file and deploy.

## What must not be built

- Any meter that goes down, or any state where Lanvi looks worse than yesterday.
- Any message that he misses the person, waited, or was alone.
- Any link between his look and the person's mood, face or steps. The measurements go to the clinic, never into the fox.
- A second rescue. He is found once.

## How it shows in the demo

1. Open the app fresh: the kit in the snow. Hold to warm him. "…you stayed."
2. One activity: "I want to chase sparks."
3. Type the help note. The help screen opens, Lanvi comes forward: "My turn. I'm staying." The clinician's phone buzzes.
4. Laptop: the same evening on the clinician page.

Closing line for the stage: "She thought she was saving a fox. He kept the light on for her."
