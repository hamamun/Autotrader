"""Triple barrier labels: what actually happened after each signal.

For every decision bar we assume the trade is opened at the OPEN of the
next bar (that is what the EA does: signal on bar close, order a second
later) and we then walk forward:

* TP1 touched first  -> class UP   (0)
* SL touched first   -> class DOWN (2)
* time limit reached -> class UP/DOWN/HOLD depending on the small move

If a single bar touches both the stop and the target we assume the STOP
was hit first. That is the pessimistic assumption, and it is the only
honest way to build a scalping model - the optimistic version inflates
win rate by 10-20 points and then fails live.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from .config import CLASS_DOWN, CLASS_HOLD, CLASS_UP, DEFAULT_TRADE


@dataclass
class LabelResult:
    labels: pd.DataFrame          # label, realized_r, gross_r, mfe_r, mae_r, bars_held
    stats: dict


def triple_barrier(
    m5: pd.DataFrame,
    atr_series: pd.Series,
    trade: dict | None = None,
    cost_r: float = 0.0,
) -> LabelResult:
    """Label every M5 bar using the triple barrier method.

    Parameters
    ----------
    m5          : OHLC frame indexed by bar OPEN time.
    atr_series  : ATR aligned on the same index.
    trade       : geometry (sl_atr_mult, tp1_rr, max_bars_hold, hold_band_r).
    cost_r      : round trip cost expressed in R (spread + commission).
    """
    cfg = {**DEFAULT_TRADE, **(trade or {})}
    o = m5["open"].to_numpy(float)
    h = m5["high"].to_numpy(float)
    l = m5["low"].to_numpy(float)
    c = m5["close"].to_numpy(float)
    a = atr_series.to_numpy(float)
    n = len(m5)

    labels = np.full(n, -1, dtype=int)
    gross_r = np.zeros(n)
    realized_r = np.zeros(n)
    mfe_r = np.zeros(n)
    mae_r = np.zeros(n)
    bars_held = np.zeros(n, dtype=int)

    sl_mult = cfg["sl_atr_mult"]
    tp_rr = cfg["tp1_rr"]
    max_bars = int(cfg["max_bars_hold"])
    band = cfg["hold_band_r"]

    for i in range(n - 1):
        if not np.isfinite(a[i]) or a[i] <= 0.0:
            continue
        entry = o[i + 1]
        risk = sl_mult * a[i]
        tp_dist = risk * tp_rr
        tp = entry + tp_dist
        sl = entry - risk
        up, down = True, True
        outcome = None
        best = -np.inf
        worst = np.inf

        last = min(i + max_bars, n - 1)
        for j in range(i + 1, last + 1):
            if h[j] >= tp:
                up = True
            else:
                up = False
            if l[j] <= sl:
                down = True
            else:
                down = False
            best = max(best, (h[j] - entry) / risk)
            worst = min(worst, (l[j] - entry) / risk)

            # pessimistic: stop first when a bar touches both
            if l[j] <= sl:
                outcome = ("sl", j)
                break
            if h[j] >= tp:
                outcome = ("tp", j)
                break

        if outcome is None:
            r = (c[last] - entry) / risk
            outcome = ("timeout", last)
            gross = r
            if abs(r) < band:
                cls = CLASS_HOLD
            elif r > 0:
                cls = CLASS_UP
            else:
                cls = CLASS_DOWN
        else:
            if outcome[0] == "tp":
                gross = tp_rr
                cls = CLASS_UP
            else:
                gross = -1.0
                cls = CLASS_DOWN

        labels[i] = cls
        gross_r[i] = gross
        realized_r[i] = gross - cost_r
        mfe_r[i] = best
        mae_r[i] = worst
        bars_held[i] = outcome[1] - i

    frame = pd.DataFrame(
        {
            "label": labels,
            "gross_r": gross_r,
            "realized_r": realized_r,
            "mfe_r": mfe_r,
            "mae_r": mae_r,
            "bars_held": bars_held,
        },
        index=m5.index,
    )
    frame = frame[frame["label"] >= 0]

    counts = frame["label"].value_counts().to_dict()
    total = int(len(frame))
    stats = {
        "rows": total,
        "up": int(counts.get(CLASS_UP, 0)),
        "hold": int(counts.get(CLASS_HOLD, 0)),
        "down": int(counts.get(CLASS_DOWN, 0)),
        "base_rate_up": counts.get(CLASS_UP, 0) / total if total else float("nan"),
        "base_rate_down": counts.get(CLASS_DOWN, 0) / total if total else float("nan"),
        "base_rate_hold": counts.get(CLASS_HOLD, 0) / total if total else float("nan"),
        "avg_bars_held": float(frame["bars_held"].mean()) if total else float("nan"),
    }
    return LabelResult(frame, stats)
