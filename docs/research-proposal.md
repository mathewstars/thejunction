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

No photo, video or face shape leaves the phone. The full list, with the expected direction for each measure and how well supported it is, is in `engine/clinic_engine/data/association_hypotheses.json`. It was written before any data, so it works as a list of hypotheses fixed in advance.

## Design

- **Who:** 20 to 30 adults who finished a TMS course for depression, recruited through the clinic. Each person is their own control.
- **How long:** 12 weeks. One short activity a day is offered; nothing is required.
- **Consent:** separate consent for the camera measures. The app works without them.
- **Analysis per person:** Spearman correlation between each measure and the reference, with a bootstrap interval, a permutation test, and a correction for the number of measures tested. Lags of up to three days in both directions. All of this is done by code.
- **Appraisal:** a language model on the clinic's own hardware reads the table of statistics, never the raw data or any text from the person. It names caveats, judges the overall pattern and proposes the next step. Code checks each judgement against the numbers and replaces any that the numbers do not support. The prompt is in `engine/clinic_engine/data/association_prompt.txt`.
- **Across people:** how many participants show the expected direction for each measure, and a mixed model as the confirmatory analysis. To be specified with a statistician.

## What would count as a finding

- A measure is worth keeping if it moves in the expected direction in clearly more than half of the participants, with an interval that excludes zero in a meaningful share of them.
- A measure is dropped if it is unusable at home (poor tracking, too dependent on how the phone is held) or shows no relation.
- An early signal is claimed only if the lead holds across people, not in one person.

## What we have today

- The collection path works end to end: phone to server, compared with the person's own normal, shown to a clinician.
- The statistics and the appraisal run on the server.
- The data so far is example data and a few sessions recorded by ourselves. It shows that the pipeline works. It shows nothing about depression.

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
