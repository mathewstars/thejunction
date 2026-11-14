# Research proposal (draft)

**Do face and activity measures taken at home move with depressive symptoms after TMS? A within-person feasibility study.**

Status: a draft written at the hackathon, to show what we would study with Aalto. It has not been reviewed by a clinician or a statistician. The references are named as lines of research and still have to be checked paper by paper. Nothing here is a result.

## Why

After a course of TMS the clinic visits end. Relapse is common, and at home nobody measures anything. A phone can measure a few things every day without effort from the person: movement, and during a short activity, how the face moves and how fast the person reacts. Research on depression reports less smiling, less facial movement, slower reactions and less movement when symptoms are worse. Most of that work compares groups of people in a lab or a clinic interview. Whether the same measures follow one person's symptoms over weeks at home, on a phone, is not known.

## Question

Within one person, over 12 weeks after TMS, do the measures Lanvi collects move in the expected direction when that person's depressive symptoms get worse?

Second question: do any of them move before the symptom rating does?

## What is measured

| Source | Measures |
|---|---|
| Front camera during the focus game and the breathing minute (ARKit, numbers only) | Time spent smiling, smiles per minute, smile intensity, smiles that reach the eyes, smiling after a pleasant moment and its delay, overall facial movement, brows drawn down, inner brows raised, blink rate and length, time looking down, head angle, head movement |
| Focus game | Reaction time, its variability, errors |
| Evening check-in | Good things named, plans carried out |
| Phone and watch | Steps, walking speed, sleep hours, heart-rate variability |
| Reference | PHQ-9 every week, in the app or at the clinic. A clinician's global rating at visits. |

No photo, video or face shape leaves the phone. The phone sends the raw numbers ARKit gives for each frame and the server computes every measure, so the frames can be read again whenever a rule changes (`docs/face-raw.md`). The full list, with the expected direction for each measure and how well supported it is, is in `engine/clinic_engine/data/association_hypotheses.json`. It was written on 13 November 2026, before any data (commit d19df2e), so it works as a list of hypotheses fixed in advance. One exception: on 14 November, after the first real games, the game changed from Sparks and snow to Revontulet, and three rows were redefined for it. Reaction time is now the middle of at most six ember taps a game (its support went from stronger to weaker), errors became embers missed out of embers shown, and the variability of reaction time is kept in the list but a game gives too few taps for it. Their expected directions did not change. It is not registered anywhere outside this repository.

## Design

- **Who:** 20 to 30 adults who finished a TMS course for depression, recruited through the clinic. Each person is their own control.
- **How long:** 12 weeks. One short activity a day is offered; nothing is required.
- **Consent:** separate consent for the camera measures. The app works without them.
- **Analysis per person:** Spearman correlation between each measure and the reference, with a bootstrap interval, a permutation test, and a correction for the number of measures tested. With a daily reference, lags of up to three days in both directions; with one rating a week no lag is tested, because a week is too coarse to say which moved first. For weekly ratings the page also gives, for each measure, the correlation of the changes from one rating to the next, since two series that only drift over the same weeks correlate in level. All of this is done by code.
- **Appraisal:** a language model on the clinic's own hardware reads the table of statistics, never the raw data or any text from the person. It names caveats, judges the overall pattern and proposes the next step. Code checks each judgement against the numbers and replaces any that the numbers do not support. The prompt is in `engine/clinic_engine/data/association_prompt.txt`.
- **Across people:** how many participants show the expected direction for each measure, and a mixed model as the confirmatory analysis. To be specified with a statistician.

## First step: check the readers on real recordings

No team can collect real recordings from patients in a weekend, and we did not try to fake them. What we tested so far is on sessions we generated, with smiles planted at known places (`docs/face-raw.md`, "The reference set"). The study starts by replacing that with real data:

- **Weeks 1 to 2, before any analysis of symptoms:** every session's raw frames are kept. A sample of about 200 sessions from the first participants is labelled by two people who mark smiles and blinks on a plot of the numbers (never on video; there is none).
- **Three readers against those labels:** the fixed rule in the product, the rule relative to the person's own resting level, and Gemini reading the reduced stream. For each: smiles found, smiles reported that the labellers did not mark, and agreement between the two labellers as the ceiling.
- **Calibration:** the fixed rule's thresholds, today estimates, are set from these recordings and frozen before the 12 weeks are analysed. Because the frames are stored, every earlier session is computed again with the frozen rule.
- **What decides whether Gemini stays:** it must find faint smiles the rules miss, or report fewer things that are not smiles (talking, the phone moving), on real recordings. If a rule does as well, the rule is used and the model is dropped from this step.
- **The same check for the levels:** the two models now set how soon the clinic should look at a flag (Blueprint, "The mind"). On generated pictures they never rated a worse picture lower, but nobody has compared their levels with a clinician's. Two clinicians rate the same pictures (`engine/clinic_engine/triage_check.py` makes them) and, later, real ones. What decides whether the models stay in this step: their levels must agree with the clinicians' more often than the fixed rules' levels do, and the second reader must change something a clinician agrees with. Otherwise the fixed rules set the levels, which is one setting.
- **The same check for the daily data:** stretches of lower movement or sleep named by code and by Gemini, against the clinician's notes of when the person was unwell.

## A finer signal we would try next (built; two test sessions of our own recorded)

Peter's idea, written down on 14 November. Since that evening the whole path exists in code: the app turns the face mesh into movement numbers on the phone, the server checks, stores and sums them up, and the clinician page shows one session beside the person's own earlier sessions (`docs/face-fine.md`). **It ran on a real iPhone for the first time on the night of 14 November:** two sessions on the team's test profile, the mesh reduced to twelve regions in millimetres, 30 frames a second, 1,314 and 963 frames, The phone also sent a number it called noise, 0.9 and 1.9 mm. That build measured the wrong thing: how far the regions sat from rest in the first second and a half, not how much their numbers jump from frame to frame. So we do not yet know the noise. The streams are stored, and the spread can be computed from them. The two sessions show that the path works from the sensor to the clinician page, and nothing more. Everything else that can be seen is generated. Since 15 November one flag reads one of these numbers: "less facial movement" compares how far the face moves over the last five sessions with the person's own usual. It is set on ten real games from one team member who was well; at the spread those games showed, it would see a drop to a third in about 7 of 10 cases and speak up for an unchanged person in about 1 look in 20. No level or model reads the numbers. Whether the reach falls when a person gets worse is not known: that is the experiment we would run, not a result.

**The idea.** What we use today are ARKit's blend shapes: about fifty numbers per frame that Apple computes for animating faces. They are smoothed, and each one sums up a whole region. The same sensor that Face ID uses (the TrueDepth camera) gives an app two finer things through Apple's public interfaces: the fitted face mesh, about 1,200 points per frame, and the depth map itself. With those we could look for movements a blend shape averages away: a brief twitch on one side, how fast a smile rises and how fast it fades, small tremor, a face that moves less in one region than the other.

**Why it could matter.** Slowed and reduced facial movement is reported with worse depressive symptoms. If that shows first in small, fast movements, a coarse measure would see it late or not at all. That is a hypothesis; we have no data for it, and the literature for it still has to be read paper by paper like the rest.

**What limits it.** These are our expectations and have to be measured on the device before anything else:

- Time. Face tracking gives up to 60 frames a second and the depth map 30; the app sends 30. With our rule at 30 frames a second a movement shorter than about 0.15 seconds is mostly not counted, so the very shortest micro-expressions are out of reach.
- Depth noise. At phone distance we expect noise of around a millimetre for a single depth point. A twitch has to be several times larger than the noise to be told from it (about five times in the simulation below).
- Head movement. The head moves far more than any muscle. It has to be removed first, and what is left is small.
- The mesh may add nothing. ARKit builds the mesh from the same fit as the blend shapes, so it may show little that the blend shapes do not. The depth map is the independent measurement, and the first experiment has to show which of the two is worth keeping.
- It is not a hidden sensor. Apps cannot read the infrared dot pattern Face ID itself uses; only the mesh and the depth map that Apple derives from it.

**What it changes for privacy.** A mesh and a depth map are the shape of a face, and our rule is that no face shape leaves the phone (`ios/SENSORS.md`). So this would be the one place where the phone computes before it sends: for each region, how far it moved after the head's movement and the person's own resting shape are taken out. Only those movement numbers would leave. That gives up, for this signal only, the ability to recompute everything on the server later, and it would need its own line in the consent.

**The first experiment, before any patient.**

1. Noise floor: record a still face and a rigid object, and measure how much each region's number jumps from frame to frame when nothing moves, and how smooth that noise is in time.
2. Known movements: one of us makes small movements on cue (one mouth corner, one brow, a short twitch). Does the mesh show them where the blend shape shows nothing?
3. Decide by the numbers: if the finer signal adds nothing over the blend shapes on these recordings, it is dropped.

If it stays, its measures and their expected directions are written into the hypothesis list before any patient data is looked at, the same as the others.

**What a simulation tells us.** We generated streams with brief movements of a known size planted at known places and let our counting rule find them (`python -m clinic_engine.fine_check`, results in `docs/checks/fine-check-2026-11-14.json`). This says how the rule behaves on numbers we made. It says nothing about a real face or the real sensor. An automated review (a language model asked to act as a sceptical statistician, not a person) went through the first version of this part and its code; the harder cases below (smooth noise, a wrongly stated noise, a smoothly shaped movement, a rate that varies) were added because of that review, and they made the picture worse.

*How small a movement can be counted.* Share of planted movements found, at 30 frames a second, 2,400 movements per cell. Each movement lasts 0.1 to 0.3 seconds and holds its top like a block, which is the easiest shape to find:

| Noise | 0.3 mm | 0.5 mm | 0.75 mm | 1 mm | 1.5 mm | 2 mm |
|---|---|---|---|---|---|---|
| 0.05 mm | 0 % | 10 % | 98 % | 100 % | 100 % | 100 % |
| 0.1 mm | 0 % | 23 % | 97 % | 100 % | 100 % | 100 % |
| 0.2 mm | 0 % | 11 % | 71 % | 97 % | 100 % | 100 % |
| 0.3 mm | 0 % | 1 % | 11 % | 53 % | 97 % | 100 % |
| 0.5 mm | 0 % | 0 % | 1 % | 3 % | 31 % | 81 % |

"Noise" here is how much one region's number jumps from frame to frame while the face is still. Near the line, up to 8 in 100 planted movements were reported at a place that overlapped the planted one too little; the table counts them as not found.

- The rule counts next to nothing under half a millimetre, because its floor is half a millimetre or three times the noise, whichever is larger.
- Above the floor it needs a movement of about five times the noise to find nearly all of them. That is not a discovery about faces. It follows from the rule, which asks for three times the noise over two frames, and from the block shape we planted.
- A movement that rises and falls smoothly has to be longer. At noise of 0.1 mm the rule found a smooth 1 mm movement of 0.1 seconds 1 time in 100, and one of 0.17 seconds every time. So at 30 frames a second, read "about 0.15 seconds and longer", not 0.1.
- If one region's number were as noisy as a full millimetre, the rule found 3 mm movements 3 times in 10 and needed 5 mm to find nearly all. Those are ordinary expressions, which the blend shapes already show. A region is an average over many points, so its noise may be well below that of a single depth point. Step 1 measures it.

*What the rule reports when nothing moved.* Per 45-second session of twelve regions:

| The noise | Reported, though nothing was planted |
|---|---|
| Independent from frame to frame, and the rule is told its exact size | 0 to 0.04 |
| Smooth from frame to frame, 0.2 to 0.3 mm, exact size told | about 3 |
| 0.3 mm, but the rule is told 0.2 mm | about 7 |
| 0.3 mm, but the rule is told 0.15 mm | about 33 |

Only the first row is harmless, and it is the kindest noise there is. ARKit smooths its output, so the second row is the likely one if the noise is 0.2 mm or more (at 0.1 mm the rule's half-millimetre floor still kept it out), and three invented movements a session is as many as the real ones we assume below. So step 1 has to measure not only how large the noise is but how it moves in time, and the phone has to state it correctly. (The app's first version stated a different number, the average distance from rest; it now sends the frame-to-frame spread.)

*How many sessions it takes to see a change.* A session is 45 to 90 seconds. We do not know how many brief movements a face makes in that time; we tried 2, 4, 8 and 16 a session. Blinks may well dominate the count, and the first recordings have to show that. We drew the counts in two ways: as if every movement came independently and the person's rate never changed (a Poisson distribution), and with a rate that differs from session to session, which is what counts of behaviour usually do.

| | Rate never changes | Rate differs from session to session |
|---|---|---|
| A person who does not change, 4 a session: one session shows "half the usual or less" | 1 session in 5 | 3 in 10 |
| The rate has truly halved: one session shows "half the usual or less" | under 6 in 10 | under 6 in 10 |
| Halving seen when the sessions before are compared with the sessions after, 10 on each side at 4 a session | 8 in 10 | 7 in 10 |
| The same comparison announces a fall when nothing changed | 1 in 25 | 1 in 8 |

The comparison in the last two rows is the most lenient one: it knows the day of the change and looks only for a fall. Looking in both directions it sees the halving 7 times in 10 at best. With 3 sessions on each side it sees it one time in three. When the rate never changes, what matters is the number of movements in total: about 40 before the change, whether that is 10 sessions at 4 or 5 sessions at 8. Once the rate varies between sessions that no longer holds, and this simple comparison gives too many false alarms: 1 in 8 at 4 a session, 1 in 4 at 16. It would have to be replaced.

So one session beside the usual value, which is what the clinician page shows today (the middle of at least three earlier sessions), cannot carry a conclusion: it is wrong in both directions too often. The page says so. A change in this count could only be looked for over weeks of play.

*What the rule gets wrong.*

- When the phone shifts in the hand, every region moves to a new level and stays there. In 5 generated sessions with such a step the rule missed 9 of 28 planted movements, because it takes the usual level over the whole session. Slow drift is not simulated.
- A short jolt of the whole face, left over after the head's movement is taken out, would be counted once in every region. The rule does not yet check whether all regions moved at once.
- The generated example exposed a fault: the top of a slow, small expression was counted as a brief movement. That is fixed for the slow expressions we generate (1.5 to 4 seconds). Movements of half a second to a second and a half are untested, and a brief movement on top of an expression in the same region is not seen.

*The mouth corners.* The brief movement we most want to look at is a pull at one corner of the mouth. The app now sends the two corners as their own small regions, and the server names each brief movement there by its side: left only, right only, or both together. A brief movement that most of the rest of the face makes at the same moment is set aside as a jolt of the head or the phone. This is the same counting rule with the same limits as above, tested on generated streams only; the corner regions have not yet been recorded on a phone.

*Not simulated.* How far a region reaches and how fast it moves, from one session to the next in the same person. Nothing is known about that variation, and any number we made up would decide the answer.

## What would count as a finding

- A measure is worth keeping if it moves in the expected direction in clearly more than half of the participants, with an interval that excludes zero in a meaningful share of them.
- A measure is dropped if it is unusable at home (poor tracking, too dependent on how the phone is held) or shows no relation.
- An early signal is claimed only if the lead holds across people, not in one person.

## What we have today

- The collection path works end to end: phone to server, compared with the person's own normal, shown to a clinician.
- The statistics and the appraisal run on the server.
- The two readers of the face numbers (code and Gemini, with code checking each item Gemini reports) run on the server, and were scored on 50 generated sessions with planted smiles.
- The data so far is example data, generated sessions and a few sessions recorded by ourselves. It shows that the pipeline works. It shows nothing about depression, and nothing yet about how well any reader reads a real face.

## Limits we already see

- The face measures depend on lighting, glasses, how the phone is held and the time of day.
- Medication can change facial movement, blinking and reaction time.
- People who feel worse may stop opening the app, so the worst days are the ones most likely to be missing.
- With many measures and one person, chance findings are likely. The correction and the pre-written hypotheses reduce this; they do not remove it.
- A weekly PHQ-9 is a coarse reference for daily measures.

## What we would ask Aalto for

- A clinician and a statistician to review the hypothesis list and the analysis plan.
- Advice on ethics approval and on the wording of the help screen.
- Access to a small group of patients after TMS for the 12 weeks.
