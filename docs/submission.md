# Junction submission

The text and links of our submission on the Junction platform, so they can be edited here. Matthew owns the wording.

The platform does not read this file. After a change here, the same change has to be made in the form: Junction platform, "Your Submissions", open "Lanvi", edit, "Save Draft". The saved draft on the platform was brought in line with this file on Friday 13 Nov, late night, after the change to the Lanvi game design.

**Deadline:** Sunday 15 Nov, 10:00. Before then the draft must be set to final with "Submit Final". The form closes by itself.

## State of the form

| Field | Limit | Value now |
|---|---|---|
| Project name | 30 characters | Lanvi |
| Punchline | 200 characters | See below (155 characters) |
| Description | 5,000 characters | See below (about 2,432 characters) |
| Challenge | one | Aalto University, Beyond the Clinic |
| Tech challenge | any number | Google DeepMind, Best Use of Gemini API |
| Project demo | link | https://lanvi.app |
| Source code | link | https://github.com/mathewstars/thejunction |
| Video | public link, at most 2:00 | missing |
| Other link | link | empty |
| Presentation | PDF or slides, at most 20 MB | missing |

Still to do before Sunday 10:00:

- The video. At most 2:00, and they are strict about it. Aim for 1:50. It must be public, for example on YouTube.
- The pitch deck as a PDF.
- The description below is the one version. Before the final submission, check every sentence in it is true of the demo (Gemini reading, camera numbers, the alert) and fill in what we measured.
- The team is still named "coderama" on the platform's Team page. That is the name of an existing company; rename it.
- Check the Gemini tech challenge is still true: it stays only if Gemini really runs in the demo.

## Punchline

```
Lanvi helps people stay well at home after depression treatment. It learns each person's own normal, notices a slide early and answers with one small step.
```

## Description

Plain text on purpose. The form says it supports markdown, but we keep it without markdown symbols so it reads the same everywhere.

```
THE PROBLEM

TMS helps many people with severe depression, but it means daily clinic visits. When they end, the risk of relapse stays, and at home there's no scan and no psychiatrist. Relapse rarely starts with a crisis. It starts with a few quieter days: fewer steps, slower walking, broken sleep. Nobody notices them in time.

THE RECOVERY CYCLE

Lanvi stays with the person through good weeks and dips, and steps in early.

1. It learns their normal. Steps, walking speed and sleep come from Apple Health, and every day is compared with that person's own last four weeks, not with anyone else.
2. It notices the drift: three low days out of five, going quiet, or skipping what it suggests.
3. It answers with one small thing, picked from the person's own preferences and what helped them before.
4. It brings in the clinic when needed. If the dip keeps going, the clinic gets one short "needs review" message with no personal data in it.
5. It lets go when they're back. Attention only closes after three days in a row near their normal, or once a clinician has looked.
6. It remembers what worked, so next time it starts with that.

THE MIND

Lanvi isn't a chatbot on a timer. Behind the fox is what we call the mind: attention, memory and learning. Every new day, activity or note is checked by small watchers that decide whether something needs attention, and once something does, Lanvi holds on to it until things really recover. One good day doesn't make it forget a slow slide.

It has two kinds of memory: the person's own rules, like "not before 9", which always come first, and the lessons it learns about what helps them. Every lesson is checked against the person's real data, and they can see each one and say "not true".

WHAT THE PERSON SEES

A small Arctic fox called Lanvi whose tail glows. In Finland the northern lights are called fox fires. Lanvi grows as the person looks after themselves and never makes them feel guilty, even after a week away. The activities take a minute or less:

Sparks and snow, a short focus game.
Breathe with Lanvi, one minute of slow breathing.
Evening check-in, three good things from today and one for tomorrow.

During the first two, if the person allows it, the front camera notices how much their face moves and how often they smile and blink. No photo or video is ever saved.

FOR THE CLINICIAN

One page with a line per patient. The people who have drifted from their normal are on top, with a short plain summary and how their recovery is going. Urgent cases don't sit in a dashboard until morning: the clinician gets an alert the same day, with a case label and a link and no health data in the message. For each patient the clinician can also read, step by step, why the system did what it did.

HOW IT USES AI

Two models work behind Lanvi, and neither of them is in charge. A small model on the clinic's own hardware does the everyday work: it puts Lanvi's suggestion into words and sorts a typed note into a few labels.

Gemini does the harder reading. During the focus game and the breathing minute, ARKit turns the front camera into a handful of numbers about how the face moves. Gemini looks at those numbers across a session, next to the same person's earlier sessions, and says what changed in a fixed vocabulary: steady, slower, less expressive, and where it began. Our code then checks each of those statements against its own calculation and keeps only the ones that hold up.

SAFETY

What Lanvi offers comes from a short list we wrote ourselves, and plain code picks from it. The models describe and suggest, but everything they return is checked before it is used, and whatever fails the check is logged where the clinician can read it. Lanvi's lines are fixed as well, so it can't drift into giving advice.

Typed notes stay on the clinic's server. What goes to Gemini is numbers only, under a random label that changes every time, and only if the patient agreed. If a note sounds like someone needs help, the help screen opens straight away and the clinic hears about it the same day. Lanvi doesn't diagnose. It tells the clinician that something changed.

WHAT IS REAL AND WHAT IS NOT

This is a weekend prototype, not a validated measure. Before the final submission we will say here what works live and what we measured ourselves. The demo runs on example data and says so.

BUILT WITH

Swift, SwiftUI, ARKit face tracking, HealthKit, Python, FastAPI, an S3-compatible object store, a local open model, the Gemini API.
```

## Rules for the wording

- Say "notices" and "needs review". Do not say "diagnoses" or "detects depression".
- Write like a person. No lists of absolute promises ("never", "always"); say what the thing does.
- Say only what works. A reviewer may open the demo and the code.
- Say that the demo data is example data.
- No names of existing companies of ours anywhere in the submission.
