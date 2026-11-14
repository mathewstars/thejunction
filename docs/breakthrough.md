# The breakthrough, for the pitch

For Matthew. A suggestion for how to say the one new thing we found on Saturday night. Wording and delivery are yours; the facts and their limits are below so that nothing said on stage can be taken apart in the questions.

## What it is, in one sentence

We took 1,676 real videos of people with and without depression, ran them through the same code that reads the Face ID sensor in our app, and the two numbers we had written down in advance came out as predicted: **with depression the face travels less far from rest and moves more slowly.** On our own phones those same two numbers are the most repeatable ones we measure.

## Why it matters

Until Saturday night everything about the face was a promise: we measure it, nobody has shown it means anything. Now there is one thing we predicted, tested on real faces and found, with our own code. It is the only result in the project that is about real people's faces.

## How to say it on stage (about 20 seconds)

> We wrote down what we expected before we had any data. Last night we tested it: sixteen hundred real videos of people with and without depression, through the same code that runs in this app. With depression, the face moves less far and more slowly. Four millimetres against six and a half. Exactly what we wrote down.
>
> That is not a diagnosis. It is the first sign that the thing this phone measures is worth measuring.

Say "four millimetres against six and a half" slowly. It is the number people will remember.

## Where it goes in the three minutes

In the research scene (scene 7), in place of the line about the 24 hypotheses and Elina. The scene keeps its length:

1. Point at the clinician row: it runs.
2. The breakthrough, as above.
3. "Nothing is tested with patients. That is the study we want to run with you."

To make room, drop from the voice: "We fixed twenty-four hypotheses before any data. For Elina, whose score stayed stable, the same tool refuses to conclude." The slide can still show it.

If you would rather not touch the three minutes the night before, keep the pitch as it is and use the breakthrough as your first answer in the questions. It works there too.

## What not to say

| Do not say | Because | Say instead |
|---|---|---|
| "We can detect depression from the face." | We compared two groups of different people. We did not follow anyone. | "On real faces, the measure differs the way we predicted." |
| "Our app found this in our users." | Our own sessions are the team's, and nobody on the team is a patient. They show the numbers are repeatable, not that they follow depression. | "On our own phones these are the most repeatable numbers we have." |
| "Micro-twitches show depression." | The twitch rule came out the opposite way and is not repeatable. Only reach and speed held. | "How far and how fast the face moves." |
| "The Face ID sensor proved it." | The videos have no depth sensor. We turned their face landmarks into the kind of stream the sensor gives, and used our code on that. | "Through the same code that reads the Face ID sensor." |

## The questions this invites, and short answers

**"These are different people. How do you know it follows one person's mood?"**
We don't. That is exactly the study: twenty to thirty people after TMS, twelve weeks, each compared only with themselves.

**"People in depression videos are talking about depression. Of course they smile less."**
Yes, and we say so. That is why we lead with how far and how fast the face moves, not with smiling, and why it is a reason to run the study, not a result of it.

**"A video is not your sensor."**
Right. On video the noise is about twenty times higher than on the phone. Our sensor should see this more clearly, not less; we have nine real sessions and they are stable.

**"Did you pick the measures after looking?"**
No. The directions were written into the script before it ran, and the three that went against us are in the repository beside the ones that held.

**"What went against you?"**
Brief twitches came out the wrong way, and so did three of the eleven coarser face measures. We publish all of it: `docs/research-studies.md`.

## The numbers, exactly

- 1,676 videos (872 from people who say they have depression, 804 others), about 165 hours, from the public LMVD dataset.
- Reach (how far a region of the face goes from rest): median 4.2 mm with depression, 6.6 mm without. A video from the depression group has the higher value only 29 times in 100.
- Top speed: 37 against 45 mm a second. 35 times in 100.
- A score from our five fine measures alone ranks unseen videos at 0.71; with the coarser measures, 0.75.
- On our own phones: for reach and speed, sessions differ two to three times more than the two halves of one session.

Where it is written up: `docs/checks/README.md` (the sections on LMVD and on repeatability), scripts `docs/checks/lmvd_fine.py` and `lmvd_check.py`.
