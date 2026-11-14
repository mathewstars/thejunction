# What we tested, and how

One page for a reader who wants to know what stands behind the numbers in the submission. Every check has its script and its full output in [`docs/checks/`](checks/), with a longer explanation in [`docs/checks/README.md`](checks/README.md). None of the datasets is in this repository; each script says where it comes from.

## The way we worked

1. **Hypotheses first.** On 13 November, before any data, we wrote down 24 measures and which way each should move when depressive symptoms are worse (`engine/clinic_engine/data/association_hypotheses.json`). Three were redefined on 14 November when the game changed.
2. **Our own code, unchanged.** Where a dataset has daily data, the movement rule ran exactly as it runs on the server, with the server's thresholds. Where it has face landmarks, they went through the server's fine-movement code. Nothing was tuned to a dataset.
3. **Decide before looking.** For each new measure the expected direction was written into the script before it ran. Where we searched for something better, every choice was made on one half of the people and checked once on people not looked at before.
4. **Say what failed.** Each check lists what went against us beside what held.

## The studies

| What we asked | Data | What came out |
|---|---|---|
| Do our face measures differ between people with and without depression, in the direction we wrote down? | LMVD: 1,684 video logs with face action units, half by people who say they have depression | 6 of 11 as expected, including all three we rated strongest (less time smiling, fewer smiles, less facial movement); 3 opposite (inner brows, and two that depend on where the camera stands); 2 nothing. |
| How much do those measures carry together? | The same videos | A plain score from our twelve measures ranks unseen videos at 0.76 (0.50 is a coin); the three strongest alone at 0.69. |
| What does our fine-movement code see on real faces? | The same videos, their face landmarks turned into the stream the Face ID sensor gives and handed to our code | With depression a region of the face travels about 4 mm from rest against 6.6 mm, and more slowly: as expected. Brief movements came out opposite to what we expected, because the rule counts speech. The fine measures add almost nothing over the action units here. |
| Within one person, does less movement go with worse symptoms? | PSYCHE-D: 1,390 people with a Fitbit and four PHQ-9 scores over a year | Yes, weakly. A quarter with steps clearly below the person's own normal had a PHQ-9 0.4 points above their own other quarters (95% interval 0.2 to 0.6). In people in the clinical range whose score moved, the relation is a little stronger (about -0.10 against -0.06). One of three tests went slightly the other way. |
| Can a stronger movement signal be found? | PSYCHE-D, chosen on half the people, checked on 1,715 not looked at before | No. Of 106 step and sleep measures, plain steps is the best; a learned combination does worse. |
| How often does our movement rule flag healthy people? | LifeSnaps: 67 volunteers, four months of daily steps and mood | 23 were flagged at least once in about three months. On their low-step days people were less alert and more rested, not sadder. |
| The same on a second set | MobileWell400+: 330 people, 30 days of phone activity and mood | 12 flagged in about ten days. Mood on low days leans the expected way and is not clear of zero. |
| Can the rule run on patients' recordings? | Depresjon: 23 patients, 32 controls, wrist movement | Not as it runs: the recordings are too short. Patients move about a third less than controls. |
| Are our own measures repeatable? | Our test sessions: 9 with the fine signal, 19 with blend shapes | Fine reach and speed agree between the two halves of a session (rank agreement about +0.7). Brief movements and time smiling in one short game do not. |
| Does Gemini read the face numbers better than a fixed rule? | 50 sessions we generated with smiles planted at known places | On the ten hard ones Gemini found all 41 planted smiles and reported nothing else; a fixed rule found 20 of 28 clear ones and no faint one. Code checks every item Gemini reports. |
| Does the mind behave? | 40 generated cases read by the real models, each as it is, again, worse, and with a clinic rule | Worse never meant lower (0 of 107 flags). The clinic rule was applied where it belonged in 20 of 20. The same case read twice changed 7 of 107 flags, and Gemini agreed in 369 of 372 readings. |

## What this adds up to

- **The measures were chosen well.** On real faces and real steps the directions we fixed in advance mostly hold, and the strongest ones hold clearly.
- **The effects are small or between people.** Nothing here shows that a phone can warn of one person's relapse. The face results compare different people talking to a camera; the step result is at three-month resolution.
- **The movement rule alone is noisy in healthy people.** A low-step day is usually a rest day. That is why the rule opens a flag at "attention" and never at "needs review today", and why other signals have to agree.
- **Two things to build on, two to rework.** Fine reach and speed, and overall facial movement, are repeatable. The brief-movement rule and the smile count in a single short game are not.

## What the study with patients has to show

Twenty to thirty people after TMS, twelve weeks, a weekly PHQ-9, each person compared only with themselves: whether these measures move with one person's symptoms over weeks, how often a flag in a patient means something, and whether a clinician would set the levels the models set. The plan is in [`docs/research-proposal.md`](research-proposal.md).
