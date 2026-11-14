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

> Sense. The phone already records steps and walking speed. If the person allows the camera, two short activities also send numbers about how the face moves. Numbers only: no photo or video ever leaves the phone. Everything is compared with that person's own normal, never with an average.
>
> Respond. Lanvi offers one small thing: forty-five seconds of a focus game, one minute of breathing together, or an evening check-in with three good things. [show one live] There is no score and no streak. A bad day never costs anything.
>
> The person can also write a few words. If they suggest a need for help, the help screen opens at once.
>
> Learn. The system remembers what was followed by better days and offers that first next time.
>
> The clinician sees one line per patient. Urgent cases do not wait in a dashboard: an alert reaches the clinician the same day, with a case label and a link, and no health data in it.

**The mind and the models (1:20 to 1:40)**

> What Lanvi offers comes from a short list we wrote ourselves, and plain code picks from it. A small model on the clinic's hardware puts it into words. Gemini reads the numbers of how the face moved in a session and describes the movement, and our code checks every item it reports. We tried to make the system learn something harmful. Here is the log of what it refused.

**What we know and do not know (1:40 to 1:52)**

> This is a prototype, not a validated measure. In 36 hours we showed [what we really measured]. Whether these signals track mood after TMS is the study we would like to run with you.

**Close (1:52 to 2:00)**

> "You did the hard part. Lanvi helps it last." That is the first line a patient sees in the app.

## The story cut: making the jury feel it first

Rescue videos work because of four beats: someone is left alone, somebody notices, small patient care, and you see them come back. We tell it in that order, about one person, before any architecture. Feeling first, proof second: researchers trust the proof more once they care about who it is for.

Rules for this version:

- One person, named, and declared as made up in the first seven words. Fiction declared early does not kill the feeling; fiction revealed late does. In the video the caption "Example patient, example data" is on screen from the first frame.
- Show, do not explain. Every beat is something on a screen.
- The buzz is the turn. The return is the peak. "I kept the light on for you." appears once, at the end, and nobody reads it aloud.
- Silence in four places: after the door, on the dark phone, after the buzz, and on the last line (the longest).
- The proof is short, three ideas, and comes before the return, so the last thing the jury holds is her, not a chart.

### Two minutes (the video runs 1:50)

**1. The door (0:00 to 0:12).** Speaker only, or the door shot. Two seconds of the door's sound before the first word.

> This is Anna. We made her up.
> For six weeks, every weekday, she went to the clinic, and every day somebody looked at her. On the last day they said: you did great. Then the door closed. [one second]

**2. Somebody stays (0:12 to 0:28).** Phone: Lanvi, the breathing minute.

> We could not give her a psychiatrist at home. We gave her a small fox who stays.
> He asks for one small thing a day. A game. A minute of breathing. Three good things about today.

**3. The slide (0:28 to 0:50).** Phone: the evening check-in with three, then two, then one; then a dark phone held for two seconds. Laptop: Anna's Overview for three seconds, as confirmation.

> Every evening in October, Anna told the fox three good things about her day.
> In November, two.
> Then one.
> Then, most evenings, nothing. [dark phone, two seconds]
> Nobody would have seen that. Her next appointment was weeks away.
> But her phone had noticed she was walking half as far, and at the clinic her name moved to the top of the list.

**4. The night (0:50 to 1:08).** Phone, then the second phone.

> One evening she did open it. [pause]
> I am going to type what a bad night can look like.
> [type in silence; the help screen opens; the second phone buzzes; hold it up; say nothing for three seconds]
> That is the clinic's phone. She sees the help numbers at once. The clinic knows today, not at her next appointment.

**5. The proof (1:08 to 1:30).** Laptop: Elina's Research, then one face session recorded by one of us.

> This is example data. Here is Elina, who stayed well: same tool, and it refused to conclude.
> This session is one of ours. Gemini never saw the face, only how it moved, and code checked every line. [point] This one it got wrong.
> Whether any of this follows mood after TMS is the study we want to run with you.

**6. The return (1:30 to 1:45).** Phone only.

> [open the app after days away; "I kept the light on for you." is on the screen; say nothing for four seconds]

**7. Close (1:45 to 1:50).** Phone still in the hand, still showing the fox's line. Say only the first half; the screen says the rest. In the video, a dark card carries both sentences: "She did the hard part. We kept the light on."

> She did the hard part.

### Three minutes on stage

The extra minute goes to the fox and the slide, not to more exhibits. The proof is capped at 35 seconds.

**1. The door (0:00 to 0:20).**

> This is Anna. We made her up.
> For six weeks, every weekday, she went to the clinic. Every day somebody looked at her, asked how she slept, noticed if she was quiet. On the last day they said: you did great. Then the door closed. [two seconds]

**2. Somebody stays (0:20 to 0:50).** Phone: Lanvi, then one activity live.

> We could not give her a psychiatrist at home. We gave her a small fox who stays.
> He asks for one small thing a day. A game of forty-five seconds. A minute of breathing together. [show it] Three good things about today.
> There is no score and no streak. A bad day never costs her anything.

**3. The slide (0:50 to 1:25).** Phone: check-ins. Laptop: Overview for three seconds.

> Every evening in October, Anna told the fox three good things about her day.
> In November, two.
> Then one.
> Then, most evenings, nothing. [dark phone, two seconds]
> He offered her a short walk. Three times. She did not take it.
> Nobody would have seen that. Her next appointment was weeks away.
> But her phone had noticed she was walking half as far, and at the clinic her name moved to the top of the list.

**4. The night (1:25 to 1:50).**

> One evening she did open it. [pause]
> I am going to type what a bad night can look like.
> [type in silence; the help screen opens; the second phone buzzes; three seconds]
> That is the clinic's phone. She sees the help numbers at once. The clinic knows today, not at her next appointment.

**5. The proof (1:50 to 2:25).** Laptop: Elina, one face session of ours, the refusal log.

> This is example data. Here is Elina, who stayed well: same tool, and it refused to conclude.
> This session is one of ours. Gemini never saw the face, only how it moved, and code checked every line. [point] This one it got wrong, and code threw it out. [point] And this small smile our own rule missed. Gemini caught it.
> We also tried to make the system learn something harmful. This is the log of what it refused.
> Whether any of this follows mood after TMS is the study we want to run with you.

**6. The return (2:25 to 2:45).** Phone only.

> [open the app after days away; "I kept the light on for you."; say nothing for four seconds]

**7. Close (2:45 to 2:50).**

> She did the hard part.

### Sixty seconds at the table

> This is Anna. We made her up. Six weeks of clinic visits, then the door closes and nobody is looking. [phone] This fox stays: one small thing a day. In October she told him three good things every evening. In November two, then one, then, most evenings, nothing. [type the note; second phone buzzes; wait] That is the clinic's phone. They know today, not at her next appointment. [laptop] Example data. For a patient who stayed well, it refuses to conclude. The study is what we want to do with you. [hand them the phone showing "I kept the light on for you."]

### What makes it land

- **The single image:** a phone in a hand in the dark, with "I kept the light on for you." The door only opens the piece.
- **Three, two, one, dark.** The slide is told through her evenings, not through the chart. The chart is on screen for three seconds.
- **The buzz.** The second phone must be on the table, screen up, on vibrate.
- **The model's mistake.** Showing an item Gemini reported and code dropped is what makes "we check it" believable.
- **Held silences.** The text gets to a lump in the throat. Whether eyes get wet depends on holding the four silences and on the buzz working live.

### Delivery (the text reaches a lump in the throat; this is the rest)

Speaker:

- Tell the story at about two-thirds of normal pace and the proof at normal pace. The change of speed tells the room the register changed.
- "We made her up." Flat, no smile, eyes on the jury. Then a full breath.
- "Two." "Then one." Each gets its own breath and a falling tone. Look at the phone, not at the jury.
- Dark phone: turn the screen to the room and count two seconds silently.
- Type the note at real typing speed, eyes on the phone. Do not read it aloud. Keep it short, with no method and no detail, and check beforehand that it opens the help screen.
- When the second phone buzzes, whoever holds it lifts it without speaking. Count three.
- The return: phone at chest height, screen out, count four. It will feel like ten. Lower the voice for "She did the hard part", then stop. No "thank you" for two seconds.
- Rehearse with a stopwatch at least three times. Silences are the first thing nerves delete.

Video:

- No music. Room tone only. Two designed sounds: the door at 0:00 and the buzz, recorded for real on a wooden table.
- Voice recorded close and quiet, in a small room.
- Check-in screens: three static shots of the real app, same framing, hard cuts. The dark phone is the same framing with the screen off, two seconds, sound near silence.
- The buzz: one continuous shot of the second phone, no cut for three seconds after it lights.
- The return: a real hand, a dim real room, the screen as the only light, focus on the text. Four seconds, no voice, no movement. Then the dark card for three seconds.
- Caption "Example patient, example data", small, bottom left, first frame to last. "Generated footage" on the door shot.
- No transition animations and no zooms.

### What not to do

- No sad music, no stock photos of people holding their heads. It reads as manipulation to this jury.
- Do not say Lanvi "saved" anyone. He stays; the clinic helps.
- Do not show a sad or neglected fox. In the app a bad day never costs anything, and the pitch must not suggest otherwise.
- Do not present the typed note as Anna's words. The speaker types it and says so.
- Do not name an hour of the night or say "now". The alert reaches the clinic's group the same day; the app is not a crisis service.
- Do not say the example data is a reason to believe. It shows what the clinic would see.
- No generated shot of Anna "walking again". We have not shown a recovery. End on the real phone.

## What must be true before we say it

- One activity runs live on the phone. Without it the middle of the pitch falls.
- Anna's example data really shows three good things in October, then two, then one, then most evenings no check-in, a walk offered three times and not taken, and her steps at about half of her normal. Check the clinician page before saying the numbers.
- The app shows `welcome_back.1` in the demo. The set has three lines, so the demo must force this one.
- The alert really arrives on a phone during the demo, and the help screen on the demo server shows 112 and an example clinic contact, not a placeholder.
- Gemini runs on the demo server (key and model set, the patient allowed outside processing), and one session recorded by one of us shows an item that code dropped and a faint smile that Gemini found below the fixed rule. Never call that session Anna's. If not, drop the Gemini sentence.
- The refusal log exists on the clinician page and shows real refusals.
- The bracket in "what we know" is filled only with something we measured ourselves.
- The demo data is example data, and we say so out loud.

## Words to keep and words to avoid

| Say | Never say |
|---|---|
| notices a change | detects depression |
| compared with their own normal | below average |
| needs review today | emergency |
| numbers about how the face moves, never a picture | reads emotions, knows you are sad |
| offers one small thing | treats, therapy |

## Questions we expect

| Question | Short answer |
|---|---|
| How do you know these signals reflect mood? | We do not yet. Slower movement and slower reactions are recognised signs of low mood, which is why we chose them. |
| What about false alarms? | It prompts a look, never a diagnosis, and only on a clear change from the person's own normal. |
| What if someone is in crisis? | The app is not a crisis service. The help screen is one tap away and opens by itself when a note suggests it. The wording is a draft and needs a clinician's review; that is one thing we ask you for. |
| How is it different from Soihtu's game? | Their game is the treatment. Lanvi is what the app offers after the phone noticed a change, and it adapts to the person. |
| Why a camera on someone recovering from depression? | It is opt-in and everything works without it. Numbers only, never a picture; the movement numbers are kept on the clinic's server. |
| Where does the data go? | It stays on the clinic's server. With the patient's consent, a stream of numbers with no name, no date and no text goes to Gemini. A second optional switch (chat mode, off by default) sends a note that does not ask for help to Gemini so it can write Lanvi's reply, also only with consent. |
| What stops the AI from saying something harmful? | It doesn't write freely to a patient. Lanvi's lines come from a fixed set, and code checks what the models return. |
| Her name was at the top of the list. What did the clinic do? | The clinic gets one "needs review" message when a dip keeps going. What happens next is the clinic's decision, and that workflow is something we want to design with you. |
| How would a clinic start using it? | The clinic gives the patient a pairing code; entering it is the consent to share. The next step is a pilot with one clinic. |

## Sixty-second version for the table

> After TMS the clinic visits end and people are at home alone, with a real risk that the depression returns. Lanvi is a small fox on the phone that grows as you take care of yourself. Behind it, the phone's own movement data is compared with your own normal. When you drift, Lanvi offers one small thing: a short focus game, a minute of breathing, an evening check-in. [hand over the phone] The system learns what helps you. Your clinician sees one line per patient, and urgent cases reach them the same day. What it offers comes from a list we wrote, and here is the log of what our checks refused. It is a prototype, and the study is what we would like to do next.
