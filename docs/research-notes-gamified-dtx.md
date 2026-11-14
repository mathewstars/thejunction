# Research notes: gamified digital therapeutics and Lanvi

What the published evidence on game-based tools for depression asks for, what Lanvi already does, and where the gaps are. Written so the pitch and the clinician page only lean on sources we have read ourselves. Three sources, all open access on PubMed Central; the verification notes at the end say what each one does and does not show.

## What the evidence asks for, and what Lanvi does

| Evidence says | Lanvi today | Where |
|---|---|---|
| A genuine smile is the mouth corners up (AU12) together with the cheeks raised (AU6). Automated detection of these two units works on depressed outpatients. [2] | `eye_smile_share`: the share of smiles with a cheek raise, from `mouthSmile` and `cheekSquint`. | `engine/clinic_engine/mind/face_features.py` |
| In studies of treatment response, less lip tightening and less downward lip pull went with a better outcome; the frown muscle (corrugator) and the smile muscle (zygomatic) carried signal too. [1] | `brow_down_share` (corrugator, AU4). Not measured: downward lip pull and lip tightening. The phone already sends the matching ARKit values (`mouthFrown`, `mouthPress`) and the server keeps them in the raw frames, so two measures could be added later. They are not in the face summary or in the hypothesis list: that list was fixed on 13 November, before any data, and is not extended during the hackathon. | same file |
| Improvement is generally accompanied by more facial activity, such as smiling. [1] | `facial_activity`, `smile_rate_per_min`, `smile_time_share`, `smile_intensity`, each compared with the person's own normal. | same file; `docs/face-raw.md` |
| Slower, more monotonous touch during casual mobile games goes with higher PHQ-8 scores. [3] | The focus game records every reaction time, misses and wrong taps. No swipe speed or pressure yet. | `ios/Lanvi/Screens/Focus/FocusEngine.swift` |
| Reactivity to pleasant events is a core feature of anhedonia. (General finding; see `association_hypotheses.json`.) | `smile_response_share` and `smile_response_latency_s`: a smile within 2.5 s of a marked pleasant moment in the game (`moments_ms`). | `face_features.py`; `FaceSense.mark()` on the phone |
| Nothing is lost, nothing is punished. | "A missed spark just fades, nothing is lost." XP never goes down, no streaks, Lanvi never looks sad because of the person. | `docs/game-design.md` |
| Short, bounded sessions. | Sparks and snow 45 s, Breathe 1 min, check-in 1 min. | `docs/game-design.md` |

## Gaps

1. **Touch kinematics.** The phone records reaction times only. Swipe speed and pressure variance [3] would need a swipe mechanic in the game and two new fields on the activity record. Not started.
2. **Live reaction to the smile.** Lanvi's face loop is one-way: the phone records, the server scores later. A companion that reacts to a smile within half a second would mean the phone computing something from the face, against the rule in `docs/face-raw.md`. A design decision, not a quick change.
3. **Effort choice.** Offering an easy path and a harder path with a bigger reward (effort-for-reward tasks) is a common suggestion in this literature. It pulls against Lanvi's rule "XP is for showing up, never for playing well". Not planned.

## Caveats, in one place

- **None of our measures is validated.** The thresholds in `thresholds.py` are estimates; the docs say so. Nothing here shows that these measures follow depression in any person.
- **The lip findings come from one observer-rated study** inside a systematic review [1], not from a camera or EMG. We are measuring a related thing with ARKit, not the same thing.
- **The swipe study did not correct for multiple comparisons** and the authors call it exploratory [3]. Correlations of about 0.4 in young adults playing casual games are a reason to try, not a result.
- **Looking down and a lowered head are confounded by the phone**: people look down at a screen. The hypotheses file already says this.
- **Every face value is compared only with the same person's earlier sessions.** We never compare two people.

## Sources

1. Plevin D, Hartmann S, Schubert KO, Chen L, Clark SR. *Facial expression and predicting and monitoring response to depression treatment: a systematic review.* Digital Biomarkers. 2026;10(1):41–52. https://pmc.ncbi.nlm.nih.gov/articles/PMC12916120/
   Twelve studies, 389 participants. Pre-treatment corrugator and zygomatic activity, and lower levels of lip tightening and downward lip movement, were linked to better outcomes. Lips down OR 0.43 (95% CI 0.21–0.89), tight lips OR 0.44 (95% CI 0.21–0.91), from Fiquer et al. 2018, observer-rated. The authors rate the evidence preliminary: small, mostly female samples, mostly fair quality.

2. Cohn JF. *Advances in behavioral science using automated facial image analysis and synthesis.* IEEE Signal Processing Magazine. 2010;27(6):128–133. https://pmc.ncbi.nlm.nih.gov/articles/PMC12312643/
   Automated detection of AU6 and AU12 reached an area under the ROC curve of 0.90 or more without occlusion in the GFT dataset (0.90 and 0.75 with partial occlusion). On the Spectrum dataset of depressed outpatients, the ten most frequent action units averaged 0.794. The method is an active appearance model, not ARKit; we cite it for the feasibility of AU6+AU12 detection in this population, nothing more.

3. Chitale V, Henry JD, Matthews B, Cobham V, Baghaei N. *Leveraging swipe gesture interactions from mobile games as indicators of anxiety and depression: exploratory study.* JMIR Mental Health. 2025;12:e70577. https://pmc.ncbi.nlm.nih.gov/articles/PMC12246760/
   Young adults played three casual games for 15 minutes each. In the puzzle game, mean swipe speed correlated with PHQ-8 at ρ = −0.405 (P < .001); variance in swipe end pressure at −0.425. No correction for multiple comparisons.

Checked against the PMC pages on 14 November 2026. Claims from other sources that were in an earlier draft (a small gamified cognitive-training pilot, paediatric screen-time statistics) were left out because the samples were too small or the population was the wrong one.
