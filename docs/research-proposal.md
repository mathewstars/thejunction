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
