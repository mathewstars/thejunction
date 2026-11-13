# Pitch

The two-minute pitch for the jury, and the questions we expect. Matthew owns the wording and the delivery. It follows `docs/game-design.md` (Lanvi the fox, three activities, face measurements) and what the server does.

The jury are researchers. So: every claim can be checked, the demo is the real app, and we say what we have not shown before they ask.

## Lengths

| Where | Length |
|---|---|
| Video in the submission | At most 2:00, strict. Aim for 1:50. |
| Table pitch in peer review, Sunday 10:30 to 14:00 | Not stated. Prepare 60 to 90 seconds with the phone in hand. |
| Stage pitch, top 5 only | Exactly 3:00, then 3:00 of questions. The microphone is cut at 3:00. |

## The pitch (two minutes)

**Problem (0:00 to 0:20)**

> TMS works for many people with severe depression, but it needs daily clinic visits. When the visits end, the risk of relapse stays, and at home there is no scan and no psychiatrist. Your brief says no good maintenance solution exists yet. We built one piece of it.

**What it is (0:20 to 0:35)**

> Lanvi is a small Arctic fox on the phone that grows as the person takes care of themselves. Behind it is a system that notices when that person drifts from their own normal, and answers with one small thing.

**How it works (0:35 to 1:20)**

> Sense. The phone already records steps and walking speed. If the person allows the camera, two short activities also give a few numbers about how the face moves. No photo or video leaves the phone. Everything is compared with that person's own normal, never with an average.
>
> Respond. Lanvi offers one small thing: forty-five seconds of a focus game, one minute of breathing together, or an evening check-in with three good things. [show one live] There is no score and no streak. A bad day never costs anything.
>
> The person can also write a few words. If they suggest a need for help, the help screen opens at once.
>
> Learn. The system remembers what was followed by better days and offers that first next time.
>
> The clinician sees one line per patient. Urgent cases do not wait in a dashboard: an alert reaches the clinician the same day, with a case label and a link, and no health data in it.

**The mind and the models (1:20 to 1:40)**

> What Lanvi offers comes from a short list we wrote ourselves, and plain code picks from it. A small model on the clinic's hardware puts it into words. Gemini reads the face numbers from the camera and says what changed, and our code checks every statement before it counts. We tried to make the system learn something harmful. Here is the log of what it refused.

**What we know and do not know (1:40 to 1:52)**

> This is a prototype, not a validated measure. In 36 hours we showed [what we really measured]. Whether these signals track mood after TMS is the study we would like to run with you.

**Close (1:52 to 2:00)**

> You did the hard part. Lanvi helps it last.

## What must be true before we say it

- One activity runs live on the phone. Without it the middle of the pitch falls.
- The refusal log exists on the clinician page and shows real refusals.
- The bracket in "what we know" is filled only with something we measured ourselves.
- The alert really arrives on a phone during the demo.
- Face measurements and the Gemini reading are in the pitch only if they really run. If they do not, drop those sentences.
- The demo data is example data, and we say so out loud.

## Words to keep and words to avoid

| Say | Never say |
|---|---|
| notices a change | detects depression |
| compared with their own normal | below average |
| needs review today | emergency |
| a few numbers about how the face moves | reads emotions, knows you are sad |
| offers one small thing | treats, therapy |

## Questions we expect

| Question | Short answer |
|---|---|
| How do you know these signals reflect mood? | We do not yet. Slower movement and slower reactions are recognised signs of low mood, which is why we chose them. |
| What about false alarms? | It prompts a look, never a diagnosis, and only on a clear change from the person's own normal. |
| What if someone is in crisis? | The app is not a crisis service. The help screen is one tap away and opens by itself when a note suggests it. The wording comes from clinicians. |
| How is it different from Soihtu's game? | Their game is the treatment. Lanvi is what the app offers after the phone noticed a change, and it adapts to the person. |
| Why a camera on someone recovering from depression? | It is opt-in, nothing is saved or sent except a few numbers, and everything works without it. |
| Where does the data go? | It stays on the clinic's server. One optional step can send an anonymous trace to an outside model, only with consent. |
| What stops the AI from saying something harmful? | It doesn't write freely to a patient. Lanvi's lines come from a fixed set, and code checks what the models return. |
| How would a clinic start using it? | The clinic gives the patient a pairing code; entering it is the consent to share. The next step is a pilot with one clinic. |

## Sixty-second version for the table

> After TMS the clinic visits end and people are at home alone, with a real risk that the depression returns. Lanvi is a small fox on the phone that grows as you take care of yourself. Behind it, the phone's own movement data is compared with your own normal. When you drift, Lanvi offers one small thing: a short focus game, a minute of breathing, an evening check-in. [hand over the phone] The system learns what helps you. Your clinician sees one line per patient, and urgent cases reach them the same day. What it offers comes from a list we wrote, and here is the log of what our checks refused. It is a prototype, and the study is what we would like to do next.
