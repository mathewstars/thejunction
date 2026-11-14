# Lanvi: game design

Owner: Matthew (game design, name, look). Peter builds it in the app. Mathew builds the server side.

**Name: Lanvi.** Replaces the working name Angel.

**This replaces the "catch the lights" AR round.** The character and the activities below are the response part of the loop. Apple Health stays the main sensor. The face measurements come from Peter's FaceMetrics, running quietly during two of the activities.

Designs live in Figma (file "Lanvi", owner Matthew). Ask Matthew for access.

## The idea in one paragraph

Lanvi is a little Arctic fox whose tail glows. In Finland the northern lights are called revontulet, "fox fires": an old story says a fox running across the snow throws sparks into the sky with its tail. Lanvi grows up as the person takes care of themselves. While they play, the front camera notices how their face moves, and the server compares that with their own normal. The person never sees a score or a mood. They see their fox grow.

## Rules that never change

- XP is for showing up, never for playing well. A bad day must never earn less.
- XP never goes down. Lanvi never dims, gets sick, dies or looks sad because of the person.
- No streaks. No "you missed 3 days". After a gap Lanvi says "I kept the light on for you."
- The person never sees a mood or a score, and Lanvi never says anything like "you look sad". Measurements go to the server and the clinician page only.
- A Help button is one tap away on every screen (from `docs/app-design.md`, unchanged).
- The front camera is opt-in. No photo or video is ever saved or sent. Numbers only leave the phone: how far each part of the face moved, about thirty times a second during the activity (`docs/face-raw.md`).

## Lanvi, the character (works like the bird in Finch)

- **Glow:** activities, walks and sleep fill Lanvi's glow.
- **Wanderings:** when the glow is full, Lanvi runs off across Lapland for a few hours and comes back with a tiny story and one question with 2 answers. This is the reason to come back, not guilt.
- **Growing up:** kit, young fox, grown fox (whose tail paints small northern lights). 3 stages for the weekend, more later. Growth comes from showing up and never goes back.
- **One line a day:** Lanvi says the server's daily suggestion in its own voice ("Want to breathe with me for a minute?"). When the person writes a few words, Lanvi answers with one warm line from the server's fixed set. Not a free chat.
- **Voice:** short, warm, curious. Never lectures, never guilts.
- **Tail colour:** picked in onboarding from northern lights colours: green, pink, violet, blue.

## The three activities

### 1. Sparks and snow (focus, about 45 seconds)

- Warm sparks and snowflakes drift down. Tap the sparks, let the snowflakes fall.
- Starts slow, speeds up a little. A missed spark just fades, nothing is lost.
- Normal screen, works sitting or lying down.
- App records: reaction times, correct taps, wrong taps (tapped a snowflake), misses, completed or stopped early.
- Why: trains focus and self-control. Aalto's own depression game (Meliora, by Soihtu) trains the same skills, and slower reactions are a known sign of low mood.

### 2. Breathe with Lanvi (1 minute)

- Lanvi's tail glow rises while breathing in and fades while breathing out, about 6 breaths a minute.
- No winning or losing. Ends with a small aurora and "Nice."
- App records: completed or stopped early, time played. Heart data is read afterwards from Apple Health when a watch is there. No live watch app this weekend.
- Why: slow breathing with heart-rate feedback is what Meru Health uses (named in Aalto's brief). A 2021 review of 14 trials found it reduced depression symptoms.

### 3. Evening check-in (about 1 minute, once a day)

- 3 good things from today (tap a suggestion or type a few words).
- 1 small nice thing for tomorrow (a walk, coffee outside, call someone). The next day Lanvi asks if it happened.
- App records: good things count, tomorrow's plan done or not.
- Why: "three good things" lowered depression for months in one study, and planning small pleasant things (behavioural activation) worked as well as CBT in a 2016 Lancet trial.

## Face measurements (Peter, from FaceMetrics)

Only during Sparks and snow and Breathe with Lanvi, and only if the person allowed the camera.

Per activity the app sends a short summary, no raw frames:

- how often and how much the person smiled
- overall facial activity (how much the face moved)
- blink rate
- share of time looking down, average head tilt
- tracking quality, so the server can ignore a bad session

The server compares each summary with that person's own normal, never with other people.

## XP (design values, tune later)

| Action | XP |
|---|---|
| Sparks and snow played | 10 |
| Breathe with Lanvi done | 10 |
| Evening check-in done | 10 |
| Yesterday's plan done | 15 |
| Walked or slept around your normal (Apple Health) | 5 |

Same XP whatever the score. Stages: kit at 0, young fox at 100, grown fox at 300 (tune so the demo patient reaches grown fox in about two weeks of seeded data). A full glow meter starts a wandering.

## Onboarding (about 1 minute)

1. **Welcome:** snowy night, a faint glow in the snow. "You did the hard part. Lanvi helps it last."
2. **Meet Lanvi:** a sleepy fox kit wakes up. "Hi, I'm Lanvi." Name it (Lanvi by default) and pick its tail colour.
3. **What helps:** Music, Moving, People, Quiet. Lanvi answers "Got it. I'll start with walks."
4. **Apple Health:** "Can I read your sleep and steps, so I know your normal?" iPhone popup, then "Got it. I know your normal now."
5. **Camera:** "When we play, I notice small changes in your face. I never save photos or video." Allow, or play without it.
6. **First breath:** 1 minute of Breathe with Lanvi. First small aurora, first XP.
7. **Home:** Lanvi on a snowy hill under the night sky.

No separate safety screen in onboarding. The Help button on every screen covers it, and the clinic consent stays with the pairing step from `docs/app-design.md`.

## What this means for the server

- The round record from `docs/game-interface.md` becomes an activity record: type (`focus`, `breathing`, `checkin`), started, duration, completed, the activity's own numbers, and the face summary when present.
- A check-in record: good things count, tomorrow's plan text, done yes or no (sent the next day).
- Lanvi's lines (daily suggestion, wandering stories, replies) come from the server, so the clinic and the mentors can change the wording.
- Where XP is counted (app or server) is Mathew's call.

## Cut for the weekend

- The AR "catch the lights" round, any AR farm or AR daylight check
- Kind lanterns to strangers (comes back as a stretch goal: it was the social part the mentor asked for)
- Live heart data from a watch app
- Lanvi's shop, decorations and friends (later, Finch style: free core, paid cosmetics)

## Sources

- Finch growth stages: https://finch.fandom.com/wiki/Stages_of_Growth
- Finch adventures: https://finch.fandom.com/wiki/Adventuring
- Meliora trial, Aalto and Soihtu: https://eprints.gla.ac.uk/396483/
- Project EVO, focus training in depression: https://www.healio.com/news/psychiatry/20170112/cognitive-training-app-effective-for-moderate-latelife-depression
- Heart-rate breathing training and depression, 2021 review: https://doaj.org/article/dfdd11f16d5a4f74a799a884c159ff49
- Behavioural activation vs CBT, COBRA trial: https://ore.exeter.ac.uk/repository/handle/10871/22750
- Three good things and gratitude: https://pmc.ncbi.nlm.nih.gov/articles/PMC4380267
- SPARX, a CBT game for depression: https://pmc.ncbi.nlm.nih.gov/articles/PMC3330131
- Face behaviour during a game, teenagers: https://www.wjgnet.com/2220-3206/full/v16/i9/119308.htm
- FacePsy, face sensing on phones: https://arxiv.org/html/2406.17181v1
