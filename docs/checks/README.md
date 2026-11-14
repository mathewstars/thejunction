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
