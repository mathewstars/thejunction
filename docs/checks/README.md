# Checks of the mind, 14 November 2026

Outputs of `python -m clinic_engine.triage_check` (40 generated cases, read by the real models: each as it is, a second time, strictly worse, and with a clinic rule), and one smaller probe. No patient data.

| File | What it is |
|---|---|
| `triage-check-2026-11-14.json` | The afternoon run, with the instruction the local model had until the evening. |
| `triage-check-2026-11-14-evening.json` | The evening run, with the instruction that is live now. Its numbers are the ones quoted in the submission, the pitch and the mind page: 0 of 107 flags lower when the case got worse, 33 of 88 higher, 12 of 107 lowered against the fixed rules, 7 of 107 different on a second read, Gemini agreeing in 369 of 372 readings, the clinic rule applied in 20 of 20. |
| `triage-check-2026-11-14-rejected-rewrite.json` | The same check on a larger rewrite of the instruction that we did not keep: all cases were read and the clinic rule was applied, but only 9 of 88 flags went higher when the case got worse, against 33 with the instruction we kept. |
| `clinic_rule_probe.py` | The probe that found the fault: one generated person with a movement drop and six open flags, one clinic rule, the real local model, a memory store. Run from `engine/` with `PYTHONPATH=.`. |

## The clinic-rule fault and its fix (evening of 14 November)

A clinic rule ("Planned two-week rest after knee surgery. Less movement is expected and only needs watching.") was added for an example person with six open flags. The local model did not apply it.

| Instruction | Rule applied to the movement flag | Rule named on another flag | Answers not read |
|---|---|---|---|
| As it was | 0 of 4 | 0 | 0 |
| Larger rewrite (a glossary of every flag kind, rules handled first) | 6 of 6 | 0 | 0 in the probe; in the full check, answers without a rule were thrown away until the answer check was made tolerant of a made-up rule name |
| One paragraph changed (it names the flag kind a rule about movement is about); this is live | 6 of 6, and 3 of 3 with the rule written in Slovak | 0 | 0 |

An unrelated rule ("She is allergic to penicillin.") changed nothing in 3 of 3 runs. These probe counts were read off the terminal that evening; only the script is kept here, not its output.

## The movement rule on real recordings (Depresjon)

`depresjon-check-2026-11-14.json` is the output of `python -m clinic_engine.depresjon_check <data folder>` on the public Depresjon dataset (Garcia-Ceja et al., MMSys 2018, https://datasets.simula.no/depresjon/): wrist-worn movement counts of 23 patients in a depressive episode and 32 healthy controls, with a MADRS rating at the start and end of each patient's recording. The dataset is free for research and education and is not in this repository. Wrist counts stand in for steps; nobody in the recordings is known to relapse.

| Question | Result |
|---|---|
| Can the rule be scored as it runs on the server (own normal from 14 or more days that end 5 days back)? | No. The dataset counts at most 18 measured days for a patient and 20 for a control, so not one day can be scored. |
| With a shorter history (7 or more days, ending 2 days back; this check only), how often is a real day "clearly low"? | 9 of 89 scored days in controls (10%) and 4 of 52 in patients (8%). A bell curve would give about 7%. |
| Does that version raise a movement flag (3 of the last 5 scored days clearly low) on people who are not known to be changing? | On none of 27 controls and on 1 of 15 patients. Each person has only about three scored days, so the rule had little room to fire. |
| Our hypothesis fixed in advance, less movement when symptoms are worse: within a patient, did movement rise when the rating fell? | Not shown: rank correlation -0.04 (95% interval -0.55 to 0.53, 19 patients); of the 15 whose rating changed, 11 moved in the expected direction. Two ratings and two weeks are too little to tell. |
| Do the patients move less than the controls? | Yes, as the dataset's authors report: a median of about 256,000 counts a day against 397,000, about a third less (permutation p about 0.0003). This is a difference between people, not the within-person change our rule looks for. |

One thing the check found about the data and not about the rule: many files run on for days or weeks after the device came off. Counted as days, those rows made more than half of the controls' days look like a collapse. The check uses only the number of days the dataset itself gives for each person.

## The movement hypothesis on real people (PSYCHE-D)

`psyched-check-2026-11-15.json` is the output of `psyched_check.py` (in this folder; it needs pandas and pyarrow) on the public PSYCHE-D dataset (Evidation's DiSCover Project, https://zenodo.org/records/5085146, CC BY-NC 4.0): about 10,000 adults in the United States who wore a Fitbit for a year and filled in the PHQ-9 every three months. One row is one person and one three-month window, with the PHQ-9 at its start and end and summaries of the steps in it. The data is not in this repository. It has no daily series, so the own-normal rule cannot be run on it as it runs on the server; what it can test is the hypothesis the rule rests on, fixed on 13 November before any data: within one person, less movement goes with worse symptoms.

| Question, always within one person | Result |
|---|---|
| Across a person's windows (1,390 people with four windows each): when they walked less than their own average, was their PHQ-9 above their own average? | Yes, weakly: rank correlation -0.08 (95% interval -0.10 to -0.05), about 0.13 PHQ-9 points for every 1,000 fewer steps a day. Taking out what all people share in a study month (season, getting used to the questionnaire) leaves it unchanged (-0.08). |
| As a rule in the spirit of ours: in a window with steps clearly below the person's own normal (1.5 of their own spreads under their own median, from their other three windows), how was their PHQ-9 against their own other windows? | 0.4 points higher than otherwise (0.30 against -0.09; 95% interval of the difference 0.18 to 0.62; 1,218 such windows in 923 people). In 45.5% of those windows the score was above the person's own, against 41.2% of the others. |
| Inside one window (10,829 windows, 4,027 people): did the change of the PHQ-9 over the three months go with the trend of the steps in it? | No. The rank correlation is +0.03 (0.02 to 0.05), very small and in the other direction. |

What this says: on real people the direction we fixed in advance holds within a person, and it is small. A quarter with clearly fewer steps goes with less than half a point on a scale of 27. It does not say that a phone can warn of a relapse: the windows are three months long, a "normal" from three other windows is crude (it calls 22% of windows clearly low), and one of the three questions came out slightly the other way. Intervals come from resampling people, not rows.
