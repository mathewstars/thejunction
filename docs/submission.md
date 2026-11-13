# Junction submission

The text and links of our submission on the Junction platform, so they can be edited here. Matthew owns the wording.

The platform does not read this file. After a change here, the same change has to be made in the form: Junction platform, "Your Submissions", open "Lanvi", edit, "Save Draft". The saved draft was last brought in line with this file on Friday 13 Nov, late night, except for the sentence about urgent cases under FOR THE CLINICIAN, which is newer here.

**Deadline:** Sunday 15 Nov, 10:00. Before then the draft must be set to final with "Submit Final". The form closes by itself.

## State of the form

| Field | Limit | Value now |
|---|---|---|
| Project name | 30 characters | Lanvi |
| Punchline | 200 characters | See below (152 characters) |
| Description | 5,000 characters | See below (about 2,270 characters) |
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
- The description: replace the last section with what really works and what we measured.
- The team is still named "coderama" on the platform's Team page. That is the name of an existing company; rename it.
- Check the Gemini tech challenge is still true: it stays only if Gemini really runs in the demo.

## Punchline

```
Lanvi notices when someone recovering from depression starts moving less than their own normal, and answers with two minutes of light in their own room.
```

## Description

Plain text on purpose. The form says it supports markdown, but we keep it without markdown symbols so it reads the same everywhere.

```
THE PROBLEM

TMS helps many people with severe depression, but it needs daily clinic visits. When the visits end, the risk of relapse stays, and at home there is no scan and no psychiatrist. Nobody notices the first small changes.

WHAT LANVI DOES

Lanvi is a loop that runs at home: sense, respond, learn.

Sense. The phone already records how a person moves. Lanvi reads steps and walking speed from Apple Health and compares each day with that person's own normal, never with a population average. No questionnaire, no extra device.

Respond. On a clear change the app offers one small thing. The main one is a two-minute round in AR: lights appear in the person's own room and they walk to catch them. The round adapts to the person, and it can be played seated.

Learn. The app remembers what was followed by better days and offers that first next time. The person can see what it learned and say "not true".

The person can also write a few words. If they suggest a need for help, the help screen opens at once.

FOR THE CLINICIAN

One page, one line per patient, with those outside their own normal on top. Urgent cases do not wait in a dashboard. The clinician gets an alert the same day, with a case label and a link, and no health data in the message.

THE MIND

Lanvi is not a scheduled job that runs a prompt. It holds attention: a change opens an attention item that stays open, with a level, until the data recovers or a clinician has looked. It has memory: the person's own rules and the lessons it learned. And it learns only inside a fence: a lesson can change the order of what is offered, and nothing else.

SAFE BY DESIGN

A model never decides what a patient is offered. Code picks from a fixed list.
Every model call passes two gates: one decides what the model may see, one checks what it returned. Refusals are logged.
The app never chats freely with a patient. Replies come from a fixed set.
What a person types never leaves the clinic's server.
The app never diagnoses. It says "you moved less than usual", nothing more.

WHAT IS REAL AND WHAT IS NOT

This is a prototype being built this weekend, not a validated measure. This is a preliminary description; what works live and what we measured will be stated here before the final submission. The demo uses example data, marked as such.
```

## Sections to add when they are true

Add these to the description only when the thing runs in the demo.

```
HOW WE USE GEMINI

Gemini reads the movement of an AR round from an anonymous trace and describes it in a fixed vocabulary: steady, slowing, where it began, what was avoided. Code then checks every claim against its own numbers and drops what it cannot confirm. Everyday wording runs on a local open model.

BUILT WITH

Swift, ARKit, HealthKit, Python, FastAPI, an S3-compatible object store, a local open model, the Gemini API.
```

## Rules for the wording

- Never "diagnoses" or "detects depression". Always "notices" and "needs review".
- Say only what works. A reviewer may open the demo and the code.
- Say that the demo data is example data.
- No names of existing companies of ours anywhere in the submission.
