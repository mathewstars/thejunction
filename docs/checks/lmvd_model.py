"""A face score fitted on LMVD: how well do our measures, together, tell the two groups apart?

Input is the per-video table made by `lmvd_check.py features` (our measures, one row per
video). A plain logistic regression on the standardised measures, scored only on videos it
was not fitted on (10 folds, repeated 5 times). This is a research number, not part of the
server: the measures here come from OpenFace on video logs, the server's come from ARKit
during a game, and a weight fitted on one does not carry over to the other.

    python lmvd_model.py per_video.csv [--out result.json]        (pandas, scikit-learn)
"""

import json
import sys

import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import RepeatedStratifiedKFold, cross_val_predict
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

ALL = ["smile_time_share", "smile_rate_per_min", "smile_intensity", "eye_smile_share", "facial_activity",
       "brow_down_share", "inner_brow_up_share", "blink_rate_per_min", "blink_duration_ms",
       "look_down_share", "head_pitch_deg", "head_movement"]
# Without the two that depend on where the camera stands.
NO_CAMERA = [m for m in ALL if m not in ("look_down_share", "head_pitch_deg")]
# Only the three hypotheses we rated as best supported before any data.
STRONGEST = ["smile_time_share", "smile_rate_per_min", "facial_activity"]


def score(df: pd.DataFrame, cols: list[str]) -> dict:
    x = df[cols].fillna(df[cols].median())
    y = df["label"].astype(int)
    model = make_pipeline(StandardScaler(), LogisticRegression(max_iter=1000))
    aucs = []
    for seed in range(5):
        cv = RepeatedStratifiedKFold(n_splits=10, n_repeats=1, random_state=seed)
        p = cross_val_predict(model, x, y, cv=cv, method="predict_proba")[:, 1]
        aucs.append(roc_auc_score(y, p))
    model.fit(x, y)
    pred = cross_val_predict(model, x, y, cv=RepeatedStratifiedKFold(n_splits=10, n_repeats=1, random_state=0), method="predict_proba")[:, 1]
    cut = pred >= 0.5
    w = dict(zip(cols, model[-1].coef_[0].round(2).tolist()))
    return {"measures": len(cols), "auc_on_unseen_videos": round(float(np.mean(aucs)), 3),
            "auc_range_over_repeats": [round(float(min(aucs)), 3), round(float(max(aucs)), 3)],
            "accuracy_at_half": round(float((cut == (y == 1)).mean()), 3),
            "weights_on_standardised_measures": dict(sorted(w.items(), key=lambda kv: -abs(kv[1])))}


if __name__ == "__main__":
    df = pd.read_csv(sys.argv[1])
    df = df[df["smile_time_share"].notna() & df["label"].isin([0, 1])]
    res = {"dataset": "LMVD per-video measures (see lmvd_check.py)", "videos": int(len(df)),
           "all_twelve": score(df, ALL), "without_camera_dependent": score(df, NO_CAMERA),
           "three_best_supported_only": score(df, STRONGEST)}
    print(json.dumps(res, indent=1))
    if "--out" in sys.argv:
        json.dump(res, open(sys.argv[sys.argv.index("--out") + 1], "w"), indent=1)
