# Junction submission

The text and links of our submission on the Junction platform, so they can be edited here. Matthew owns the wording.

The platform does not read this file. After a change here, the same change has to be made in the form: Junction platform, "Your Submissions", open "Lanvi", edit, "Save Draft". The saved draft on the platform was brought in line with this file on Friday 13 Nov, late night, after the change to the Lanvi game design.

**Deadline:** Sunday 15 Nov, 10:00. Before then the draft must be set to final with "Submit Final". The form closes by itself.

## State of the form

| Field | Limit | Value now |
|---|---|---|
| Project name | 30 characters | Lanvi |
| Punchline | 200 characters | See below (181 characters) |
| Description | 5,000 characters | See below (4,986 characters) |
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
- ARKit face tracking, as numbers only: smiles, blinks and, new, brief twitches of the mouth corners in millimetres from the Face ID sensor. Gemini reads, code checks: 41 of 41 planted smiles found, nothing invented.
- The mind: rules notice, two AI models in two layers weigh (the clinic's own, then Gemini), code guards, and it learns which small step helps each person. Tested on 40 cases: worse never meant lower, 0 of 107.
- Real people: in public data of 1,390 Fitbit wearers our movement hypothesis holds within a person, and it is small.
- Not shown: that any of it follows depression in a patient. That is the study.

COULD IT HELP PEOPLE STAY WELL AT HOME?

When someone drifts from their own normal for days, their name moves to the top of the clinic's list and, if it is serious, the clinic gets a message the same day. When someone writes that they need help, help numbers open on the phone at once and the clinic is told, with no model in between. Lanvi is not a crisis service; the help wording still needs a clinician's review. Then one small offer: sense, respond, learn.

WOULD SOMEONE RECOVERING FROM DEPRESSION USE IT EVERY DAY?

One thing a day, 90 seconds or less: a game, a minute of breathing together, three good things in the evening. No score, no streak, nothing to set up, and a bad day costs nothing. After a week away the fox says "I kept the light on for you." The camera is optional.

SMART SENSING: WHAT THE PHONE MEASURES

During the game and the breathing, ARKit turns the front camera into 52 numbers about how the face moves and three head angles, thirty times a second. No photo or video leaves the phone. Gemini gets a reduced stream of numbers, no name or date, with consent (that screen is not built yet). The server computes 18 measures: smiles and whether they reach the eyes, blinks, gaze, how much the face moves at all. Since Saturday night the app also sends a finer signal from the Face ID sensor: the face mesh reduced on the phone to twelve regions, in millimetres per frame (its noise is not measured yet). Two real sessions so far; nothing reads it. The game, Revontulet, borrows from published tasks, far shorter than the originals: an easy or a hard shot (effort for reward), a traced half circle (drawing speed), reaction to embers, slow strokes over the sleeping fox (swipe speed). Steps and walking speed come from Apple Health.

In the public PSYCHE-D data (1,390 people with a Fitbit and four PHQ-9 scores over a year), quarters with steps clearly below the person's own normal had a PHQ-9 0.4 points above their own other quarters: the direction we fixed in advance.

Two readers go through each face session: a fixed rule in code, and Gemini, whose every reported smile is checked against the numbers. On ten hard generated sessions, with talking, a moving phone and smiles planted at known places, the fixed rule found 20 of 28 clear smiles and none of 13 faint ones. A simple rule relative to the person's own rest found all but reported 22 things that were not smiles. Gemini found all 41 and nothing else. Gemini had been told what talking looks like.

We fixed 24 hypotheses before any data (three redefined when the game changed).

THE MIND, AND HOW WE TESTED IT

Plain rules we can explain notice a change and raise a flag. Two models weigh it: a small one on the clinic's own hardware sets how soon someone should look, and Gemini agrees, raises or lowers one step. Code guards both: help is always urgent, no model can lower what the rules call "needs review today", and the rules stand when no model answers. A clinician can add a rule for one person in plain words.

On 40 generated cases read by the real models, as it is, again, worse, and with a clinic rule:
Against the rules alone the models only lowered: 12 of 107 flags, one step. No level is yet compared with a clinician's.
The clinic rule was applied where it belonged in 20 of 20 cases, and nowhere else.
What does not flatter us: the same case read twice changed 7 of 107 flags, and Gemini agreed in 369 of 372 readings.

WHAT IS REAL AND WHAT IS NOT

Live: the server, the clinician page, both models, the alert; one team member's iPhone sent real games, face numbers and Apple Health days through the whole path. The other people on the page are generated examples. Nothing is tested with patients, and the face and game measures are not shown to follow depression. That is the study we want to run with Aalto: 20 to 30 people after TMS, twelve weeks, each compared only with themselves.

The research and the mind in depth: lanvi.app/demo#/blueprint.
```

## Rules for the wording

- Say "notices" and "needs review". Do not say "diagnoses" or "detects depression".
- Write like a person. No lists of absolute promises ("never", "always"); say what the thing does.
- Say only what works. A reviewer may open the demo and the code.
- Say that the demo data is example data.
- No names of existing companies of ours anywhere in the submission.
