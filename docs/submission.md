# Junction submission

The text and links of our submission on the Junction platform, so they can be edited here. Matthew owns the wording.

The platform does not read this file. After a change here, the same change has to be made in the form: Junction platform, "Your Submissions", open "Lanvi", edit, "Save Draft". The saved draft on the platform was brought in line with this file on Friday 13 Nov, late night, after the change to the Lanvi game design.

**Deadline:** Sunday 15 Nov, 10:00. Before then the draft must be set to final with "Submit Final". The form closes by itself.

## State of the form

| Field | Limit | Value now |
|---|---|---|
| Project name | 30 characters | Lanvi |
| Punchline | 200 characters | See below (155 characters) |
| Description | 5,000 characters | See below (4,997 characters) |
| Challenge | one | Aalto University, Beyond the Clinic |
| Tech challenge | any number | Google DeepMind, Best Use of Gemini API |
| Project demo | link | https://lanvi.app/demo (no login, read only; https://lanvi.app itself needs a login, which is no longer published) |
| Source code | link | https://github.com/mathewstars/thejunction |
| Video | public link, at most 2:00 | the film is ready (1:49); the link is missing until it is uploaded |
| Other link | link | empty |
| Presentation | PDF or slides, at most 20 MB | deck ready as a PDF (8 slides, 1.1 MB); not uploaded yet |

Still to do before Sunday 10:00:

- The video. At most 2:00, and they are strict about it. Aim for 1:50. It must be public, for example on YouTube.
- The pitch deck as a PDF.
- The description below is the one version. "What is real and what is not" was filled in on Saturday evening from the server side. Still to check with Peter before the final submission: that the phone build really sends Apple Health days and the face numbers from a real iPhone, since the description says so.
- Team name on the platform stays "coderama" (Matej's decision, 15 Nov); the project name is Lanvi.
- Check the Gemini tech challenge is still true: it stays only if Gemini really runs in the demo.

## Punchline

```
Lanvi helps people stay well at home after depression treatment. It learns each person's own normal, notices a slide early and answers with one small step.
```

## Description

Plain text on purpose. The form says it supports markdown, but we keep it without markdown symbols so it reads the same everywhere. Rewritten on Saturday night at Matej's word: brief on the clinic software, long on the AR research and on how the mind was tested; the film carries the whole prototype.

```
IN SHORT

After TMS treatment for depression the clinic visits end and nobody is looking. Lanvi is a small Arctic fox on the phone that asks for one small thing a day. Behind it the phone keeps count in numbers only, each person is compared with their own normal, and a clinic page shows who has drifted. The film shows the whole prototype. This text is about the two parts we tested hardest: what the camera and the game measure, and the mind that decides what the clinic hears.

THE AR RESEARCH

During the 90-second game and the breathing minute, ARKit turns the front camera into 52 numbers about how the face moves and three head angles, thirty times a second. No photo or video leaves the phone. The server computes 18 measures from them: smiles and whether they reach the eyes, blinks, gaze down, brows, lip corners, how much the face moves at all.

The game, Revontulet, is built from tasks with a study behind them: a choice between an easy and a hard shot (effort for reward), a traced half circle (drawing speed and lifts), reaction time to embers, and slow strokes over the sleeping fox (swipe speed). Each number is compared only with that person's own earlier games.

Two readers go through every face session: a fixed rule in code, and Gemini, whose every reported smile is checked against the numbers. We tested both on sessions we generated with smiles planted at known places. On ten hard sessions, with talking and a moving phone, the fixed rule found 20 of 28 clear smiles and none of 13 faint ones. A simple rule relative to the person's own rest found them all but also reported 22 things that were not smiles. Gemini found all 41 and reported nothing else; across 50 sessions it did the same. Gemini had been told what talking looks like and the rules had not, and generated data is cleaner than a face. Step one of the study is the same count on real recordings marked by two people.

We fixed 24 hypotheses before any data: which way each measure should move when symptoms are worse (three were redefined when the game changed). For each person the server computes a rank correlation between every measure and their PHQ-9, one observation per rating, with a bootstrap interval, a permutation test and a correction for many measures. For an example person whose score stayed stable, the page says there is too little change to tell.

TESTING THE MIND

The mind has three layers. Plain rules we can explain notice a change and raise a flag. Two models weigh it: a small one on the clinic's own hardware sets how soon someone should look, and Gemini, as second reader, agrees, raises or lowers by one step. Plain code guards both: a request for help is always urgent and waits for no model, no model can lower a flag the rules hold at "needs review today", and the rules' level stands when no model answers. A clinician can write a rule for one person in plain words; the clinic's own model reads it and the words never leave the clinic's server.

We checked it on 40 generated cases read by the real models: each as it is, a second time, strictly worse, and with a clinic rule.

Worse never meant lower: 0 of 107 flags.
The models respond to severity: of 88 flags the rules level the same in both cases, they set 33 higher and none lower.
Where they differ from the rules as the cases stand, they only lower: 12 of 107, by one step.
The clinic rule was applied to the flag it was about in 20 of 20 cases and named on no other.
What does not flatter us: the same case read twice changed on 7 of 107 flags, and Gemini agreed in 369 of 372 readings, so far a second signature more than a second opinion.

The check earned its place the night before the deadline. On a case with six open flags the local model ignored a clinic rule, 0 of 4. We changed one paragraph of its instruction, got 6 of 6, and the full check then showed our first, larger rewrite had made the model more timid everywhere else, so we kept the small change. The check's output is in the repository.

THE CLINIC SOFTWARE, BRIEFLY

One page: a line per patient, those who drifted on top, every flag with what the rules, the local model and Gemini each said, a timeline of every decision with exactly what was sent to a model, and the research page. It is open at lanvi.app/demo with no login, read only. Signing in is needed only to change something.

WHAT IS REAL AND WHAT IS NOT

A weekend prototype, not a validated measure. Live: the server, the clinician page, both models, the same-day alert. One team member's iPhone has sent real games, face numbers and Apple Health days through the whole path. The other people on the page are generated examples and the page says so. Nothing is tested with patients, and nothing here shows these measures follow depression. That is the study we want to run with Aalto: about thirty people after TMS, twelve weeks, each compared only with themselves.

BUILT WITH

Swift, SwiftUI, ARKit face tracking, HealthKit, Python, FastAPI, a local open model, the Gemini API.
```

## Rules for the wording

- Say "notices" and "needs review". Do not say "diagnoses" or "detects depression".
- Write like a person. No lists of absolute promises ("never", "always"); say what the thing does.
- Say only what works. A reviewer may open the demo and the code.
- Say that the demo data is example data.
- No names of existing companies of ours anywhere in the submission.
