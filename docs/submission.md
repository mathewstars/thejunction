# Junction submission

The text and links of our submission on the Junction platform, so they can be edited here. Matthew owns the wording.

The platform does not read this file. After a change here, the same change has to be made in the form: Junction platform, "Your Submissions", open "Lanvi", edit, "Save Draft". The saved draft on the platform was brought in line with this file on Friday 13 Nov, late night, after the change to the Lanvi game design.

**Deadline:** Sunday 15 Nov, 10:00. Before then the draft must be set to final with "Submit Final". The form closes by itself.

## State of the form

| Field | Limit | Value now |
|---|---|---|
| Project name | 30 characters | Lanvi |
| Punchline | 200 characters | See below (181 characters) |
| Description | 5,000 characters | See below (4,999 characters) |
| Challenge | one | Aalto University, Beyond the Clinic |
| Tech challenge | any number | Google DeepMind, Best Use of Gemini API |
| Project demo | link | https://lanvi.app/demo (no login, read only; https://lanvi.app itself needs a login, which is no longer published) |
| Source code | link | https://github.com/mathewstars/thejunction |
| Video | public link, at most 2:00 | the film is ready (1:49); the link is missing until it is uploaded |
| Other link | link | https://lanvi.app/demo#/blueprint (the research and the mind in depth, no login) |
| Presentation | PDF or slides, at most 20 MB | deck ready as a PDF (8 slides, 1.1 MB); not uploaded yet |

Still to do before Sunday 10:00:

- The video. At most 2:00, and they are strict about it. Aim for 1:50. It must be public, for example on YouTube.
- The pitch deck as a PDF.
- The description below is the one version. "What is real and what is not" was filled in on Saturday evening from the server side. Still to check with Peter before the final submission: that the phone build really sends Apple Health days and the face numbers from a real iPhone, since the description says so.
- Team name on the platform stays "coderama" (Matej's decision, 15 Nov); the project name is Lanvi.
- Check the Gemini tech challenge is still true: it stays only if Gemini really runs in the demo.

## Punchline

```
After TMS for depression, a rescued fox asks one small thing a day. The phone compares you with your own normal, and the clinic hears when you start to slide. Try it: lanvi.app/demo
```

## Description

Plain text on purpose. The form says it supports markdown, but we keep it without markdown symbols so it reads the same everywhere. Rewritten on Saturday night at Matej's word: its headings are the jury's four questions, it is brief on the clinic software and long on what the phone measures and on how the mind was tested; the film carries the whole prototype. An independent reader scored it as a juror against the earlier version and its edits are in.

```
After TMS the daily clinic visits end and nobody sees a slow slide back. Lanvi is a small Arctic fox on the phone (northern lights in Finnish: revontulet, fox fires). He asks for one small thing a day. While the person plays, the phone measures, and the clinic hears when someone starts to slide.

What we can show:
- It runs. The film shows the app; lanvi.app/demo opens the clinic page, no login.
- The face, as numbers only (ARKit and the Face ID sensor). On 1,684 real videos of people with and without depression, our three best-supported face hypotheses hold: less time smiling, fewer smiles, less facial movement.
- The mind: rules notice, two AI models in two layers weigh (the clinic's own, then Gemini), code guards, and it learns which small step helps each person. Tested on 40 cases: worse never meant lower, 0 of 107.
- Movement: in 1,390 real Fitbit wearers our hypothesis holds within a person, and it is small.
- Not shown: that any of it follows depression in one patient over time. That is the study.

COULD IT HELP PEOPLE STAY WELL AT HOME?

When someone drifts from their own normal for days, their name moves to the top of the clinic's list and, if it is serious, the clinic gets a message the same day. When someone writes that they need help, help numbers open on the phone at once and the clinic is told, with no model in between. Lanvi is not a crisis service; the help wording still needs a clinician's review. Then one small offer: sense, respond, learn.

WOULD SOMEONE RECOVERING FROM DEPRESSION USE IT EVERY DAY?

One thing a day, 90 seconds or less: a game, a minute of breathing together, three good things in the evening. No score, no streak, nothing to set up, and a bad day costs nothing. The camera is optional.

SMART SENSING: WHAT THE PHONE MEASURES

During the game and the breathing, ARKit turns the front camera into 52 numbers about how the face moves and three head angles, thirty times a second. No photo or video leaves the phone. The server computes 18 measures: smiles, blinks, gaze, how much the face moves. Since Saturday night the app also sends a finer signal from the Face ID sensor: the face mesh reduced on the phone to twelve regions, in millimetres. Nine real sessions so far; nothing reads it. The game borrows from published tasks: effort for reward, drawing speed, reaction time, swipe speed. Steps and walking speed come from Apple Health.

WHAT WE TESTED, AND HOW

We fixed 24 hypotheses before any data (three redefined when the game changed), then ran them on public data of real people, with every rule decided before looking at a result.

Faces (LMVD, 1,684 video logs, half by people with depression): 6 of 11 measures differ as we wrote down, including all three we rated strongest; 3 go the other way; 2 show nothing. A score from our measures ranks unseen videos at 0.76.
Fine movement (1,676 of those videos through our Face ID code): with depression a region of the face travels 4 mm from rest against 6.6 mm, and more slowly. Brief twitches came out opposite, so we do not trust that rule yet.
Movement (PSYCHE-D, 1,390 people, a year): a quarter with steps clearly below the person's own normal had a PHQ-9 0.4 points above their own other quarters.
False alarms (LifeSnaps, 67 healthy volunteers): our rule, unchanged, flagged 23 at least once in three months. A low-step day there is a rest day, not a sad one.
Gemini as second reader: on ten hard generated sessions, with disturbances its prompt names, it found all 41 planted smiles and nothing else; our fixed rule found 20. Code checks every item.

These are differences between people, or at coarse time scales: they support our choice of measures, not that a phone can warn of relapse.

THE MIND, AND HOW WE TESTED IT

Plain rules we can explain notice a change and raise a flag. Two models weigh it: a small one on the clinic's own hardware sets how soon someone should look, and Gemini agrees, raises or lowers one step. Code guards both: help is always urgent, no model can lower what the rules call "needs review today", and the rules stand when no model answers. A clinician can add a rule for one person in plain words.

On 40 generated cases read by the real models: worse never meant lower; the clinic rule was applied where it belonged in 20 of 20; against the rules alone the models only lowered, 12 of 107 flags by one step. What does not flatter us: the same case read twice changed 7 of 107 flags, and Gemini agreed in 369 of 372 readings.

WHAT IS REAL AND WHAT IS NOT

Live: the server, the clinician page, both models, the alert; a team member's iPhone sent real games, face numbers and Apple Health days through the whole path. The other people on the page are generated examples. Nothing is tested with patients. That is the study we want to run with Aalto: 20 to 30 people after TMS, twelve weeks, each compared only with themselves.

In depth: lanvi.app/demo#/blueprint. Every check with its script: github.com/mathewstars/thejunction, docs/checks.
```

## Rules for the wording

- Say "notices" and "needs review". Do not say "diagnoses" or "detects depression".
- Write like a person. No lists of absolute promises ("never", "always"); say what the thing does.
- Say only what works. A reviewer may open the demo and the code.
- Say that the demo data is example data.
- No names of existing companies of ours anywhere in the submission.
