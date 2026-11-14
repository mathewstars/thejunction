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

## The story cut: making the jury feel it first

Rescue videos work because of four beats: someone is left alone, somebody notices, small patient care, and you see them come back. Our project already has all four. We only have to tell it in that order, about one person, before any architecture. Feeling first, proof second: researchers trust the proof more once they care about who it is for.

Rules for this version:

- One person, named, from the first sentence. Anna is an example and we say so once, plainly. No invented quotes from real patients.
- Show, do not explain. Every beat is something on a screen.
- Three seconds of silence after the alert arrives. Do not talk over it.
- Then turn to the evidence, so nobody can call it a sob story.

### Two minutes

**1. Left alone (0:00 to 0:20).** Speaker only, no screen.

> Six weeks, every day, Anna went to the clinic. Somebody looked at her every day. On the last day they said: you did great. Then the door closed, and there was nobody.
> Anna is an example. The door is real: after TMS, relapse is common, and at home no one is watching.

**2. Somebody stays (0:20 to 0:40).** Phone: Lanvi on the home screen.

> We could not give her a psychiatrist at home. We gave her a small fox who stays.
> He asks for one small thing a day. A game, a minute of breathing, three good things.
> [open the app after a few days away] And when she disappears for a while, he never says "you missed three days". He says: [let them read it] "I kept the light on for you."

**3. The slide nobody sees (0:40 to 1:00).** Laptop: Anna's Overview.

> Then November comes. [point at the drop] She walks less. In the game her face moves less and she reacts more slowly. Nobody would see this. Her phone does, because it knows what is normal for her.

**4. The night (1:00 to 1:20).** Phone, then the second phone.

> And one night, just before one o'clock, she writes this. [type it slowly] "i cannot do this anymore, i need help."
> [the help screen opens; then the second phone buzzes; hold it up; say nothing for three seconds]
> That was her clinician's phone. Not tomorrow. Not at the next appointment in six weeks. Now.

**5. Why you can trust it (1:20 to 1:45).** Laptop: Anna's Research, then Elina's.

> Here are twelve weeks of Anna. [point] When her PHQ-9 was higher, she smiled less often, reacted more slowly and walked less. Same weeks, same shape.
> And here is Elina, who stayed well. [switch] Same tool, and it says: too little change to tell. It does not find patterns that are not there.
> A model reads the numbers and code checks everything it says. This is example data. The real study is what we want to run with you.

**6. Close (1:45 to 2:00).** Phone: Lanvi.

> You did the hard part: you got her well. We built the one who keeps the light on after the door closes.

### Sixty seconds at the table

> Six weeks of daily clinic visits, then the door closes and there is nobody. [phone] This fox stays. One small thing a day, and when you vanish for a week he says "I kept the light on for you". [laptop] Meanwhile the phone notices what nobody sees: she walks less, smiles less, reacts more slowly. [type the note; second phone buzzes; wait] Her clinician knows tonight, not in six weeks. [Research] And this is why you can believe it: twelve weeks, the measures follow her PHQ-9, and for a patient who stayed well it refuses to conclude. Example data. The study is what we want to do with you.

### What makes it land

- **The door.** Open and close with the same image.
- **"I kept the light on for you."** Let the jury read it on the phone themselves. Do not read it aloud first.
- **The buzz.** The second phone must be on the table, screen up, sound on vibrate. This is the moment people remember.
- **Elina.** For researchers the honest "we cannot tell" is the emotional peak of the second half. Do not skip it to save time.

### What not to do

- No sad music, no stock photos of people holding their heads. It reads as manipulation to this jury.
- Do not say Lanvi "saved" anyone. He stays; the clinician helps.
- Do not show a sad or neglected fox. In the app a bad day never costs anything, and the pitch must not suggest otherwise.
- Do not let the story run past 1:20. Without the last 40 seconds it is only a story.

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
| Where does the data go? | It stays on the clinic's server. One optional step can send an anonymous trace to an outside model, only with consent. A second optional switch (chat mode, off by default) sends a note that does not ask for help to Gemini so it can write Lanvi's reply, also only with consent. |
| What stops the AI from saying something harmful? | It doesn't write freely to a patient. Lanvi's lines come from a fixed set, and code checks what the models return. |
| How would a clinic start using it? | The clinic gives the patient a pairing code; entering it is the consent to share. The next step is a pilot with one clinic. |

## Sixty-second version for the table

> After TMS the clinic visits end and people are at home alone, with a real risk that the depression returns. Lanvi is a small fox on the phone that grows as you take care of yourself. Behind it, the phone's own movement data is compared with your own normal. When you drift, Lanvi offers one small thing: a short focus game, a minute of breathing, an evening check-in. [hand over the phone] The system learns what helps you. Your clinician sees one line per patient, and urgent cases reach them the same day. What it offers comes from a list we wrote, and here is the log of what our checks refused. It is a prototype, and the study is what we would like to do next.
