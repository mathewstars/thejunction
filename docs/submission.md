# Junction submission

The text and links of our submission on the Junction platform, so they can be edited here. Matthew owns the wording.

The platform does not read this file. After a change here, the same change has to be made in the form: Junction platform, "Your Submissions", open "Lanvi", edit, "Save Draft". The saved draft on the platform was brought in line with this file on Friday 13 Nov, late night, after the change to the Lanvi game design.

**Deadline:** Sunday 15 Nov, 10:00. Before then the draft must be set to final with "Submit Final". The form closes by itself.

## State of the form

| Field | Limit | Value now |
|---|---|---|
| Project name | 30 characters | Lanvi |
| Punchline | 200 characters | See below (155 characters) |
| Description | 5,000 characters | See below (4,919 characters) |
| Challenge | one | Aalto University, Beyond the Clinic |
| Tech challenge | any number | Google DeepMind, Best Use of Gemini API |
| Project demo | link | https://lanvi.app |
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

Plain text on purpose. The form says it supports markdown, but we keep it without markdown symbols so it reads the same everywhere.

```
THE PROBLEM

TMS helps many people with severe depression, but it means daily clinic visits. When they end, the risk of relapse stays, and at home there's no scan and no psychiatrist. Relapse rarely starts with a crisis. It starts with a few quieter days: fewer steps, slower walking, broken sleep. Nobody notices them in time.

THE RECOVERY CYCLE

Lanvi stays with the person through good weeks and dips, and steps in early.

1. It learns their normal. Steps, walking speed and sleep come from Apple Health, and each day is compared with that person's own last four weeks.
2. It notices the drift: three low days out of five, going quiet, or skipping what it suggests.
3. It answers with one small thing, picked from what the person prefers and what helped before.
4. It brings in the clinic when needed: one short "needs review" message.
5. It lets go when they're back: after three days in a row near their normal, or once a clinician has looked.
6. It remembers what worked and starts with that next time.

THE MIND

Behind the fox is what we call the mind, in three layers. Plain rules that we can explain notice when something changes and raise a flag. Two models then weigh how much it matters: a small one on the clinic's own hardware sets the level and Gemini, as the second reader, agrees, raises or lowers. Plain code guards both: every answer has a fixed form, a request for help is always urgent and never waits for a model, and the rules' own level stands whenever no model answers. A clinician can also write a rule for one person in their own words ("planned rest after surgery, lower movement only needs watching"); the clinic's own model follows it, and the words never leave the clinic's server. Attention, memory and learning: Small watchers check every new day, activity or note, and once something needs attention Lanvi holds on to it until things really recover. One good day doesn't make it forget a slow slide.

It has two kinds of memory: the person's own rules, like "not before 9", which come first, and the lessons it learns about what helps them. Each lesson is checked against the person's real data, and they can see it and say "not true".

WHAT THE PERSON SEES

A small Arctic fox called Lanvi whose tail glows. In Finland the northern lights are called fox fires. Lanvi grows as the person looks after themselves and never makes them feel guilty, even after a week away. The activities take a minute or less:

Sparks and snow, a short focus game.
Breathe with Lanvi, one minute of slow breathing.
Evening check-in, three good things from today and one for tomorrow.

During the first two, if the person allows it, the front camera notices how their face moves. No photo or video is saved.

FOR THE CLINICIAN

One page with a line per patient. Those who have drifted from their normal are on top, with a short plain summary. For urgent cases the clinician gets an alert the same day, with a case label and a link and no health data in it. For each patient the clinician can also read, step by step, why the system did what it did.

HOW IT USES AI

Two models work behind Lanvi, and neither is in charge. A small model on the clinic's own hardware does the everyday work: it words Lanvi's suggestion and sorts a typed note into a few labels.

Gemini does the harder reading. ARKit turns the front camera into numbers about how the face moves; no picture leaves the phone. Plain code counts smiles and blinks with a fixed rule. Gemini reads the same numbers and reports each smile with its start and end, judged against that person's own resting level. Code then checks every item Gemini reports. On 50 sessions we generated with smiles planted at known places, Gemini reported every planted smile and nothing else. That shows how the readers handle a known signal, not how well they read a person. Gemini reads the last weeks of daily Apple Health numbers the same way and names the stretches that changed, including a slow slide that never crosses our fixed rule on a single day. Code checks each one. When Gemini catches something the fixed rules missed and code confirms it in the numbers (a slow decline in the daily numbers, or smiles that have become faint), the clinic gets a low-level flag: noticed by the model, confirmed by code.

SAFETY

What Lanvi offers comes from a short list we wrote ourselves, and plain code picks from it. Everything a model returns is checked before it is used, and what fails is logged where the clinician can read it. Lanvi's lines are fixed, so it can't drift into giving advice.

Gemini gets numbers only, with no name, date or text, and only when the patient's record allows outside processing (the clinic sets that with the patient). Typed notes stay on the clinic's server, except in an optional chat mode, off by default, where a note that does not ask for help goes to Gemini without any name or id. If a note sounds like someone needs help, the help screen opens straight away and the clinic hears the same day. Lanvi doesn't diagnose. It tells the clinician that something changed.

WHAT IS REAL AND WHAT IS NOT

This is a weekend prototype, not a validated measure. Live at lanvi.app: the server and clinician page, the rules with their record of every decision, the local model, Gemini reading the face and daily numbers, and the same-day alert. The patients on the page are examples with invented names and simulated histories, and the page says so; the model answers shown are real. Nothing has been tested with patients, and nothing here shows that these measures follow depression. That is the study we would like to run with Aalto: about thirty people after TMS, twelve weeks, each compared only with themselves.

BUILT WITH

Swift, SwiftUI, ARKit face tracking, HealthKit, Python, FastAPI, a local open model, the Gemini API.
```

## Rules for the wording

- Say "notices" and "needs review". Do not say "diagnoses" or "detects depression".
- Write like a person. No lists of absolute promises ("never", "always"); say what the thing does.
- Say only what works. A reviewer may open the demo and the code.
- Say that the demo data is example data.
- No names of existing companies of ours anywhere in the submission.
