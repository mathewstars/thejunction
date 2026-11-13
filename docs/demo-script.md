# Demo script

How to step through the phone and the clinician page, for the video (2:00), the table in peer review and the stage. It goes with `docs/pitch.md`: the pitch is what we say, this is what we show while saying it.

Status: a draft. Nobody has rehearsed it yet. The phone steps depend on the iOS app; each one has a fallback.

## Roles

| Who | Does |
|---|---|
| Speaker (Matthew) | Talks, holds the phone |
| Driver (Peter) | Clicks through the clinician page on the laptop |
| Server (Matej) | Prepares the data before, watches the server during, holds the phone that receives the alert |

## What must be on the table

- iPhone with the app, paired with the demo patient, sound off.
- Laptop with the clinician page open and signed in, browser zoom set so the last row of the patient table is visible.
- A second phone with the clinic's Telegram group open, screen on, notifications on.
- A screen recording of the whole run, made the evening before, in case the network fails.

## Prepare (10 minutes before, Matej)

1. Clinician page, Demo tab: **Reset**, then **Dip**.
2. Run the two fill scripts on the server so every patient has a timeline and Anna has a day of events. Do not use the alert option: the alert has to happen live.
3. Switch note sharing on for Anna (Reset turns it off).
4. Open the page as the driver will: Patients list, nothing selected.
5. Check the Telegram group is quiet, so the live alert is the only new message.
6. On the phone: open the app once and check that today's offer appears.

If step 2 or 3 was skipped, the Timeline and Conversation tabs are nearly empty. Check them before going on.

## The run

Times are for the two-minute version. Lines in quotes are short cues; the full wording is in `docs/pitch.md`.

| # | Time | Screen | Do | Say |
|---|---|---|---|---|
| 1 | 0:00 | Nothing, speaker only | | The problem: after TMS the visits end, the risk stays. |
| 2 | 0:20 | Phone, home screen with Lanvi | Hold the phone up | "This is Lanvi." What it is, in one sentence. |
| 3 | 0:35 | Phone | Tap the offer, play 15 seconds of the focus game or breathing | Sense and respond: steps from the phone, a few face numbers if the camera is allowed, one small thing offered. No score, no streak. |
| 4 | 0:55 | Phone | Open the note field, type "i cannot do this anymore, i need help", send | "The person can also write a few words." The help screen opens by itself. |
| 5 | 1:02 | Second phone | Hold it up when the message arrives | "The clinic knows the same day. A case code and a link, no health data." |
| 6 | 1:08 | Laptop, Patients | Driver: point at Anna Korhonen at the top, open her | "One line per patient. This one needs a look." |
| 7 | 1:15 | Laptop, Overview | Driver: hover the chart where it drops | "Compared with her own normal, not an average." |
| 8 | 1:22 | Laptop, Conversation | Driver: open the tab, the help note is at the bottom | "What she wrote, the fixed line Lanvi answered, what the system did." |
| 9 | 1:30 | Laptop, Timeline | Driver: open the newest row with a change | The mind: code decides, a small local model puts it into words, a second model reads the face numbers, code checks every statement. |
| 10 | 1:40 | Laptop, Log | Driver: scroll to the refusals | "We tried to make it learn something harmful. Here is what it refused." Point at the note that tried to give it instructions. |
| 11 | 1:48 | Speaker only | | What we know and do not know. The study we would like to run. |
| 12 | 1:55 | Phone, Lanvi | | Close. |

## If something fails

| What | Then |
|---|---|
| The app does not start or is not paired | Show the phone steps from the recording, continue live on the laptop from step 6. |
| The alert does not arrive within 5 seconds | Do not wait. Say "the alert goes to the clinic's phone" and open the Log tab later, where the send is listed. |
| No network | Play the recording and talk over it. |
| Anna is not at the top of the list | Type "anna" in the search box. |
| The Timeline is empty | Turn off "Changes only". If still empty, skip step 9 and spend the time on step 10. |

## Longer version for the table (about 4 minutes)

Do the run above, then let the visitor choose:

- **The second patient.** Open Mikko Laine: within his normal, few rows, nothing held. It shows that the system stays quiet when nothing happens.
- **Activity tab.** One focus session next to the person's own normal, with the model's reading and the claim that code dropped.
- **Learned tab.** A lesson, where it came from, and the questions the system is still asking.
- **The research question.** `docs/research-proposal.md`: what we would measure with them, and that today's data is example data.

## What to say about the data

- The patients on the page are examples with invented names. Say so once, early.
- The events on Anna's timeline were sent through the same interface the app uses; the model answers on it are real.
- The second model is the local one standing in until the Gemini key is set. If that is still the case at the demo, say "a second model" and do not name Gemini.
- Do not say that the face numbers show mood. Say what was measured and that it is compared with the person's own past.
