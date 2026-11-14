# Checks of the mind, 14 November 2026

Outputs of `python -m clinic_engine.triage_check` (40 generated cases, read by the real models: each as it is, a second time, strictly worse, and with a clinic rule), and one smaller probe. No patient data.

| File | What it is |
|---|---|
| `triage-check-2026-11-14.json` | The afternoon run, with the instruction the local model had until the evening. |
| `triage-check-2026-11-14-evening.json` | The evening run, with the instruction that is live now. Its numbers are the ones quoted in the submission, the pitch and the mind page: 0 of 107 flags lower when the case got worse, 33 of 88 higher, 12 of 107 lowered against the fixed rules, 7 of 107 different on a second read, Gemini agreeing in 369 of 372 readings, the clinic rule applied in 20 of 20. |
| `triage-check-2026-11-14-rejected-rewrite.json` | The same check on a larger rewrite of the instruction that we did not keep: all cases were read and the clinic rule was applied, but only 9 of 88 flags went higher when the case got worse, against 33 with the instruction we kept. |
| `fine-check-2026-11-14.json` | `python -m clinic_engine.fine_check`: the fine facial movement rule on generated streams (how small a movement it finds at each noise, how many sessions it takes to see a change in a count). No face was recorded. Written up in `docs/research-proposal.md`. |
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

### Looking for a stronger signal in the same data

`psyched_explore.py` and `psyched-explore-2026-11-15.json`. People were split in two halves by a fixed rule; every choice was made on the first half (661 people) and the second half (729 people) was looked at once.

- 106 measures of steps and sleep that change from window to window were tried. The plain average of daily steps was the strongest on the first half (rank correlation -0.07 within person) and held on the second (-0.08).
- A combined score of the eight strongest measures looked better on the half it was chosen on (0.10) and was no better than steps alone on the half it had not seen (0.07, 95% interval 0.03 to 0.11). Two sleep measures that looked promising on the first half (how irregular bedtime is, sleep efficiency) did not hold.
- As a flag, the highest fifth of that score went with a PHQ-9 0.49 points above the person's own average on the second half (0.22 to 0.79), against 0.39 for the steps-only rule above.

So we did not find a better detector in this data: nothing beats plain steps compared with the person's own average, and the relation stays small (about 0.08). That is at three-month resolution with Fitbit summaries; daily data, the game and the face are not in this dataset.

### A second search in PSYCHE-D

`psyched_explore2.py`, `psyched-explore2-2026-11-15.json`. Choices made on the first half of the four-window people; checked on 1715 people with two or three windows that no earlier step had looked at.

| Idea | On the people not looked at before |
|---|---|
| Steps against own average, everyone | -0.06 (95% interval -0.10 to -0.02) |
| Only people who were ever at 10 or more on the PHQ-9 | -0.08 (-0.13 to -0.02), 838 people |
| Only people whose score moved by 5 points or more | -0.09 (-0.16 to -0.04), 597 people |
| Both | -0.10 (-0.17 to -0.04), 479 people |
| Change from one window to the next: steps against PHQ-9 | -0.05 (-0.10 to -0.01) |
| A learned combination of all 111 passive step and sleep measures (gradient boosting) | 0.04, weaker than steps alone on the same people (0.06) |

The relation is a little stronger where it should be: in people in the clinical range whose score really moved, about -0.10 against -0.06 for everyone, and the same pattern shows in all three sets of people. The intervals overlap, so this is a direction, not a finding. Nothing here turns it into a strong signal, and a model fed everything does worse than plain steps.

## The movement rule as it runs, on real daily data (LifeSnaps)

`python -m clinic_engine.lifesnaps_check <folder>`, output `lifesnaps-check-2026-11-15.json`. LifeSnaps (Yfantidou et al., Scientific Data 2022, https://zenodo.org/records/7229547, open) followed 71 volunteers for about four months with a Fitbit, a short daily mood report and the PANAS every week. They are not patients and there is no depression scale. The data is not in this repository. Each person's daily steps went through the server's own code and thresholds, unchanged.

| Question | Result |
|---|---|
| How often is a real day "clearly low" (1.5 of the person's own spreads under their own normal)? | 304 of 3254 scored days, 9.3%. A bell curve would give about 7%. |
| How many healthy volunteers get a movement flag (3 of the last 5 days clearly low) at some point in about three scored months? | 23 of 67. The flag was held on 91 days in all. |
| What did people report on their clearly low days, against their own other days (23 people with enough of both)? | Less often alert (-0.058, 95% interval -0.091 to -0.029) and more often rested (+0.085, 0.006 to 0.170); less often happy but not clearly (-0.067, -0.151 to 0.012); sad no different (+0.004, -0.034 to 0.048). |
| In weeks with a flag, the weekly PANAS against the person's own other weeks (12 flagged weeks, 11 people)? | Positive affect -1.9 points (-6.2 to 1.9), negative affect +1.7 (-2.1 to 4.8): the expected directions, and the intervals include zero. |

What this says about our rule, and it is not flattering: in healthy people a low-step day is mostly a rest day. They are less alert and more rested, not sadder, and about one in three gets a movement flag within three months without anything being wrong. That is why the rule alone opens a flag at "attention" and not at "needs review today", and why the pilot has to measure how often a flag in a patient means something. This dataset cannot answer that: nobody in it is ill.

## Our face hypotheses on real faces (LMVD)

`lmvd_check.py` (in this folder; it needs pandas), output `lmvd-check-2026-11-15.json`. LMVD (He et al. 2024, https://github.com/helang818/LMVD, figshare 25698351, Apache 2.0) holds OpenFace features, frame by frame, of 1,823 video logs from about 1,475 people on four platforms: half by people who say they have depression, half by others. No video and no audio: action units, gaze and head pose. The data (16 GB) is not in this repository. Each video was reduced to the same kind of numbers our server computes from ARKit, by fixed rules written before looking at the result; 1684 videos had enough tracked frames (872 depression, 812 others, about 165 hours).

The question: do the face measures we fixed a direction for on 13 November differ between the two groups in that direction? The last number is the chance that a video from the depression group has the higher value; 0.50 means no difference.

| Measure | Expected in depression | Median, depression | Median, others | Chance the depression video is higher | Result |
|---|---|---|---|---|---|
| Time spent smiling | lower | 0.0631 | 0.1551 | 0.35 (0.32 to 0.37) | as expected |
| Smiles per minute | lower | 3.6114 | 7.7205 | 0.35 (0.33 to 0.38) | as expected |
| Smile intensity | lower | 1.065 | 1.1034 | 0.48 (0.45 to 0.51) | no clear difference |
| Smiles that reach the eyes | lower | 0.2799 | 0.3644 | 0.44 (0.42 to 0.47) | as expected |
| Overall facial movement | lower | 1.4605 | 1.7957 | 0.34 (0.31 to 0.36) | as expected |
| Brows drawn down | higher | 0.1971 | 0.2546 | 0.48 (0.45 to 0.51) | no clear difference |
| Inner brows raised | higher | 0.2713 | 0.3174 | 0.38 (0.36 to 0.41) | opposite |
| Blink rate | mixed | 23.0292 | 21.4605 | 0.50 (0.47 to 0.54) | no direction fixed |
| Blink length | higher | 258.1818 | 255.6479 | 0.54 (0.51 to 0.57) | as expected |
| Time looking down | higher | 0.3934 | 0.5768 | 0.43 (0.41 to 0.46) | opposite |
| Head angle | higher | 4.2572 | 8.2687 | 0.38 (0.35 to 0.40) | opposite |
| Head movement | lower | 38.2696 | 52.3019 | 0.31 (0.29 to 0.33) | as expected |

**6 of 11 as expected, 3 opposite, 2 with no clear difference.** The three we rated as best supported all hold, and clearly: people in the depression group smile for less of the time (6% of frames against 16%), smile less often (3.6 a minute against 7.7) and move the face less. Head movement is lower too, and fewer of their smiles reach the eyes.

What went against us: inner brows raised, time looking down and head angle came out opposite. The last two depend on where the camera stands, and a vlog camera is not a phone held in the hand, so we read little into them; inner brows raised is simply not supported here. Smile intensity and brows drawn down show nothing.

What this does and does not show. It is the first evidence on real faces that the measures Lanvi computes carry the signal we chose them for. It is a comparison between people, not the change within one person that the product looks for. The two groups also differ in what they talk about, how they film and which platform they use, and a person talking about their depression smiles less for that reason alone. The videos are not one per person. OpenFace on a vlog is not ARKit during a game.

## The movement rule as it runs, on a second set of daily data (MobileWell400+)

`python -m clinic_engine.mobilewell_check <folder>`, output `mobilewell-check-2026-11-15.json`. MobileWell400+ (https://zenodo.org/records/11060596, CC BY 4.0): 409 adults in Spain, 30 days, the phone's own activity recognition, a mood report several times a day (valence, energetic arousal, tense arousal, 0 to 100) and the PHQ-9 at the end. Volunteers, not patients. A day's movement is the minutes the phone labelled walking, on foot, running or cycling, turned into steps at 100 a minute. With 30 days, only about the last ten of each person can be scored.

| Question | Result |
|---|---|
| How often is a day clearly low? | 140 of 2892 scored days, 4.8%. |
| How many people get a movement flag in about ten scored days? | 12 of 330. |
| On a clearly low day against the person's own other days (68 people)? | Valence -1.9 points (95% interval -4.1 to 0.3), energetic arousal -2.3 (-5.0 to 0.5), tense arousal +2.4 (-0.0 to 5.0): each in the expected direction, none clear of zero. |
| Between people: PHQ-9 at the end against how much the person moved (198 people, 51 at 10 or more)? | Rank correlation -0.04, no relation (permutation p 0.60). |

Beside LifeSnaps this gives a second, lower false-alarm figure (about 4% of people in ten days against a third in three months; the two are not the same length), and the same picture for mood: low-movement days lean the expected way and do not stand out.

### A face score fitted on LMVD

`lmvd_model.py`, output `lmvd-model-2026-11-15.json`. A plain logistic regression on our measures of each video, scored only on videos it was not fitted on (10 folds, repeated 5 times). The number is the chance that the score ranks a video from the depression group above one from the other group; 0.50 is a coin, 1.00 is perfect.

| Measures used | On unseen videos |
|---|---|
| All twelve | 0.76 |
| Without the two that depend on where the camera stands (looking down, head angle) | 0.74 |
| Only the three hypotheses we rated best supported before any data (time smiling, smiles per minute, facial movement) | 0.69 |

The score leans most on how little the face and the head move, then on blinking and the brows; the smile measures add little once movement is in. Published models on this dataset that read the raw frame sequences reach roughly 0.72 to 0.77 accuracy; ours, from a dozen summary numbers, gets 0.70 at the same cut.

This score is not in the server and should not be: it was fitted on OpenFace numbers from video logs, the server computes its measures from ARKit during a game, and a weight fitted on one does not carry over to the other. It also learns whatever else separates the two groups of videos (topic, filming, platform). What it gives us is an order of magnitude for how much is in these measures on real faces, and which of them to look at first when our own recordings exist.

### LMVD through our fine-movement code

`lmvd_fine.py`, output `lmvd-fine-2026-11-15.json`. LMVD has no face mesh, but it has OpenFace's 68 face landmarks in every frame. The script lays each frame's landmarks over the video's own median face (using the eye corners and the bridge of the nose, which takes out where the head is and how far away), takes for nine regions how far the landmark sits from its own median place, turns pixels into millimetres by the distance between the outer eye corners, and hands that stream, unchanged, to `clinic_engine.mind.face_fine.summarize` (rules version 4): the same code that sums up the stream from the Face ID sensor. 1676 videos gave a summary (1066 good, 607 partly tracked); the noise the code measured from the streams has a median of 0.30 mm.

What we expected was written into the script before it ran: with depression, less reach, lower top speed and fewer brief movements.

| Measure | Expected in depression | Median, depression | Median, others | Chance the depression video is higher | Result |
|---|---|---|---|---|---|
| Reach (how far a region goes from rest), mm | lower | 4.247 | 6.605 | 0.29 (0.26 to 0.32) | as expected |
| Top speed, mm a second | lower | 36.56 | 45.07 | 0.35 (0.32 to 0.37) | as expected |
| Brief movements a minute, all regions | lower | 281.6 | 241.3 | 0.62 (0.59 to 0.64) | opposite |
| Brief movements of the mouth corners a minute | lower | 37.89 | 33.68 | 0.58 (0.55 to 0.61) | opposite |
| Left-right difference of the mouth | none | 0.071 | 0.069 | 0.50 (0.47 to 0.53) | no direction fixed |

- **Reach and speed hold, and strongly.** A region of the face travels about 4 mm from rest in the depression group against 6.6 mm in the other, and moves more slowly. Reach is the clearest single difference of anything we measured on this dataset.
- **Brief movements went the other way.** We expected fewer; there are more. The likely reason is in the rule, not in the faces: it counts a movement only if it is short, and in a face that moves less a syllable of speech is short and stands out, while in a livelier face the same moment is part of a longer expression and is not counted. So "brief movements per minute" does not mean what we hoped on people who are talking. It has to be tested on the game, where nobody speaks.
- **Does the fine signal add to the action units?** A score from the five fine measures alone ranks unseen videos at 0.71; the ten action-unit measures alone at 0.74; both together at 0.74. So on this data the fine signal carries most of the same information and adds almost nothing on top, which is the outcome the research proposal named as possible ("the mesh may add nothing").

Limits beyond those above: these are flat picture landmarks from compressed video, not a depth sensor; a head turned sideways leaks into the numbers; only the first 12,000 frames of a video are used; and the people are talking.

## How repeatable are our own face measures? (the team's test sessions, 15 November)

Not a public dataset: the sessions on the team's test profile, read on the server on the night of 15 November. Each session was cut in two halves and summed up twice with the server's own code. A measure is usable for following one person only if the two halves of one session agree better than two different sessions do.

| Measure | Sessions | The two halves differ by (median) | Sessions differ by (spread over mean) | Do the halves rank the sessions alike? |
|---|---|---|---|---|
| Fine movement: reach | 9 | 34% | 76% | +0.70 |
| Fine movement: top speed | 9 | 25% | 65% | +0.77 |
| Fine movement: brief movements a minute | 9 | 50% | 52% | +0.68 |
| Blend shapes: time smiling | 19 | 200% | 201% | +0.14 |
| Blend shapes: overall facial movement | 19 | 22% | 30% | +0.43 |
| Blend shapes: blink rate | 19 | 48% | 54% | +0.54 |
| Blend shapes: head movement | 19 | 33% | 34% | +0.48 |

Reach and top speed of the fine signal are the most repeatable numbers we have: sessions differ two to three times more than the halves of one session do. Brief movements are not (the halves differ as much as the sessions), which fits what the LMVD run showed about that rule. Of the blend-shape measures only overall facial movement is somewhat repeatable; time smiling is not, because in a game of a minute or so a smile is a rare event and falls in one half or the other.

Limits: few sessions, one evening, halves of 15 to 30 seconds, and the profile has seven paired phones, so some of the difference between sessions is a difference between people and phones, which makes the sessions look easier to tell apart than one person's days will be.

### LMVD: can the people with more than one video be found? (no)

`lmvd_people.py`, output `lmvd-people-2026-11-15.json`. LMVD has 1,823 videos from about 1,475 people and no person id. We tried to guess who is who from the shape of the face alone (the median place of the landmarks of the upper face, nose and eyes, with position, size and tilt taken out), to see whether one person's videos could be followed.

The test was fixed before looking: two videos of one person must carry the same label, so matched pairs should agree on the label nearly always; chance is one half. **The matching failed that test.** Among the 5% of videos with the closest match, the match carries the same label in 71%; among 131 mutual closest pairs, in 67%. So at best about four pairs in ten are really one person, and probably fewer, because the way a video was filmed shapes the landmarks too.

In those pairs, reach and speed agree far more than in two random videos with the same label (0.52 against about 0.1). We do not read that as "a person's face moves alike in their videos": two videos matched by landmark shape were probably filmed from a similar angle, and the angle alone moves these numbers.

And even a perfect matching could not show a life track here: a person's videos all carry one label and no date, so nobody's depression changes within this dataset. Following one person over time needs data we have to collect.
