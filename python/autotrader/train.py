"""Training: gradient boosting teacher -> walk forward check -> distilled
student that MT5 can run.

All evaluation is walk forward (train on the past, test on the future).
A random split on time series data is the single most common way people
fool themselves into a 90% "accuracy" that dies in live trading.
"""

from __future__ import annotations

import json

import numpy as np
import pandas as pd

from .config import CLASS_DOWN, CLASS_HOLD, CLASS_NAMES, CLASS_UP
from .model import SoftmaxNet


# ----------------------------------------------------------------------
def make_teacher(seed: int = 0, n_estimators: int = 300, learning_rate: float = 0.05):
    """Prefer LightGBM, fall back to sklearn so the repo always runs."""
    try:
        from lightgbm import LGBMClassifier

        return LGBMClassifier(
            objective="multiclass",
            num_class=3,
            n_estimators=n_estimators,
            learning_rate=learning_rate,
            num_leaves=31,
            min_child_samples=100,
            subsample=0.8,
            subsample_freq=1,
            colsample_bytree=0.8,
            reg_lambda=1.0,
            random_state=seed,
            n_jobs=-1,
            verbose=-1,
        )
    except Exception:  # pragma: no cover
        from sklearn.ensemble import HistGradientBoostingClassifier

        return HistGradientBoostingClassifier(
            max_iter=n_estimators, learning_rate=learning_rate,
            max_leaf_nodes=31, min_samples_leaf=100, random_state=seed,
        )


def class_weights(y: np.ndarray) -> np.ndarray:
    """Balance the classes so HOLD does not swallow everything."""
    counts = np.bincount(y, minlength=3).astype(float)
    counts[counts == 0] = 1.0
    w = counts.sum() / (3.0 * counts)
    return w


def walk_forward_probs(
    X: pd.DataFrame,
    y: pd.Series,
    n_splits: int = 5,
    gap: int = 50,
    teacher_kwargs: dict | None = None,
    verbose: bool = True,
):
    """Out-of-fold probabilities with expanding window, no shuffling."""
    Xv, yv = X.to_numpy(float), y.to_numpy(int)
    n = len(Xv)
    fold = n // (n_splits + 1)
    oof = np.full((n, 3), np.nan)
    reports = []

    for k in range(1, n_splits + 1):
        tr_end = fold * k
        te_start = tr_end + gap
        te_end = min(n, fold * (k + 1) + gap)
        if te_start >= te_end:
            break

        model = make_teacher(**(teacher_kwargs or {}))
        w = class_weights(yv[:tr_end])
        try:
            model.fit(Xv[:tr_end], yv[:tr_end], sample_weight=w[yv[:tr_end]])
        except TypeError:  # sklearn fallback has no sample_weight kwarg
            model.fit(Xv[:tr_end], yv[:tr_end])
        probs = model.predict_proba(Xv[te_start:te_end])
        oof[te_start:te_end] = probs

        rep = evaluate(yv[te_start:te_end], probs)
        rep["fold"] = k
        rep["train_rows"] = int(tr_end)
        rep["test_rows"] = int(te_end - te_start)
        rep["test_from"] = str(X.index[te_start])
        reports.append(rep)
        if verbose:
            print(f"  fold {k}: train {tr_end:>7,}  test {te_end - te_start:>6,}  "
                  f"acc {rep['accuracy']:.3f}  dir-acc {rep['directional_accuracy']:.3f}")

    mask = ~np.isnan(oof[:, 0])
    return oof, mask, reports


# ----------------------------------------------------------------------
def evaluate(y_true: np.ndarray, probs: np.ndarray) -> dict:
    from sklearn.metrics import log_loss

    pred = probs.argmax(axis=1)
    non_hold = y_true != CLASS_HOLD
    pred_dir = pred != CLASS_HOLD
    both = non_hold & pred_dir

    return {
        "accuracy": float((pred == y_true).mean()),
        "balanced_accuracy": float(np.mean([
            (pred[y_true == c] == c).mean() if (y_true == c).any() else np.nan
            for c in range(3)
        ])),
        "directional_accuracy": float((pred[both] == y_true[both]).mean()) if both.any() else float("nan"),
        "coverage": float(pred_dir.mean()),
        "log_loss": float(log_loss(y_true, probs, labels=[0, 1, 2])),
        "class_balance": {CLASS_NAMES[c]: float((y_true == c).mean()) for c in range(3)},
    }


# ----------------------------------------------------------------------
def distil(
    X: pd.DataFrame,
    oof_probs: np.ndarray,
    mask: np.ndarray,
    hidden=(64, 32),
    epochs=600,
    seed=0,
    verbose=True,
) -> SoftmaxNet:
    """Train the small student on the teacher's out-of-fold probabilities."""
    net = SoftmaxNet(hidden=hidden, seed=seed)
    # No class weighting here: the teacher's probabilities are already
    # calibrated, and multiplying soft targets by class weights pushes the
    # student into predicting the rare class for everything (measured:
    # accuracy collapsed from 0.51 to 0.10 on synthetic data).
    net.fit(
        X.to_numpy(float)[mask],
        oof_probs[mask],
        epochs=epochs,
        verbose=verbose,
    )
    return net


def feature_importance(X: pd.DataFrame, y: pd.Series, top: int = 12) -> list[dict]:
    model = make_teacher()
    w = class_weights(y.to_numpy(int))
    try:
        model.fit(X.to_numpy(float), y.to_numpy(int), sample_weight=w[y.to_numpy(int)])
    except TypeError:
        model.fit(X.to_numpy(float), y.to_numpy(int))
    imp = getattr(model, "feature_importances_", None)
    if imp is None:
        return []
    order = np.argsort(imp)[::-1][:top]
    return [{"feature": X.columns[i], "importance": float(imp[i])} for i in order]


def save_report(path: str, report: dict) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, default=str)
