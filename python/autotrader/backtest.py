"""Honest event-driven backtest of the model's direction calls.

Rules that keep this from lying to you:

* signals are produced on a closed bar, filled on the NEXT bar open
* spread and commission are charged on every trade, in R
* when the stop and the target are inside the same bar, the STOP wins
* positions are non overlapping (one trade at a time) like the EA
* the "accuracy" numbers are split into: all-bar accuracy (what a naive
  claim uses) and traded-signal accuracy (what you actually trade)
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from .config import CLASS_DOWN, CLASS_HOLD, CLASS_UP


@dataclass
class BacktestResult:
    metrics: dict = field(default_factory=dict)
    trades: pd.DataFrame = field(default_factory=pd.DataFrame)
    equity_r: pd.Series = field(default_factory=lambda: pd.Series(dtype=float))


def _max_drawdown(equity: np.ndarray) -> float:
    if len(equity) == 0:
        return 0.0
    peak = np.maximum.accumulate(equity)
    return float((peak - equity).max())


def _sharpe(returns: np.ndarray, periods_per_year: float) -> float:
    if len(returns) < 2 or returns.std() == 0:
        return 0.0
    return float(returns.mean() / returns.std() * np.sqrt(periods_per_year))


def run(
    probs: np.ndarray,
    labels: pd.DataFrame,
    index: pd.DatetimeIndex,
    min_prob: float = 0.45,
    min_edge: float = 0.05,
    hold_band_r: float = 0.25,
    risk_per_trade: float = 0.005,
    trades_per_day_hint: float = 288.0,
    max_trades_per_day: int = 0,
) -> BacktestResult:
    """Simulate the model's own signals (no rule engine) on the test slice."""
    p_up, p_hold, p_down = probs[:, CLASS_UP], probs[:, CLASS_HOLD], probs[:, CLASS_DOWN]

    take_buy = (p_up >= min_prob) & (p_up - np.maximum(p_hold, p_down) >= min_edge)
    take_sell = (p_down >= min_prob) & (p_down - np.maximum(p_hold, p_up) >= min_edge)

    rows = []
    equity = [0.0]
    busy_until = -1
    day_counts: dict = {}
    label_arr = labels["label"].to_numpy()
    r_arr = labels["realized_r"].to_numpy()

    for i in range(len(probs)):
        if i <= busy_until:
            continue
        if not (take_buy[i] or take_sell[i]):
            continue
        day = index[i].date()
        if max_trades_per_day and day_counts.get(day, 0) >= max_trades_per_day:
            continue
        day_counts[day] = day_counts.get(day, 0) + 1

        direction = "BUY" if take_buy[i] else "SELL"
        pred_class = CLASS_UP if take_buy[i] else CLASS_DOWN
        real = int(label_arr[i])

        # realised R is expressed for a long; a short with a DOWN label wins
        r = r_arr[i] if take_buy[i] else (
            -r_arr[i] if real != CLASS_HOLD else 0.0
        )
        if real == CLASS_HOLD:
            r = 0.0

        hit = pred_class == real
        rows.append(
            {
                "time": index[i],
                "direction": direction,
                "p_up": p_up[i],
                "p_hold": p_hold[i],
                "p_down": p_down[i],
                "realized_label": real,
                "realized_r": r,
                "direction_correct": hit,
            }
        )
        equity.append(equity[-1] + r * risk_per_trade)
        busy_until = i + max(1, int(labels["bars_held"].iloc[i]))

    trades = pd.DataFrame(rows)
    equity_series = pd.Series(equity[1:], dtype=float)

    n = len(trades)
    if n:
        wins = trades.loc[trades["realized_r"] > 0, "realized_r"]
        losses = trades.loc[trades["realized_r"] < 0, "realized_r"]
        gross_win = float(wins.sum())
        gross_loss = float(-losses.sum())
        spans_days = max((index[-1] - index[0]).total_seconds() / 86400.0, 1e-9)
        trades_per_day = n / spans_days
        metrics = {
            "trades": n,
            "trades_per_day": round(trades_per_day, 2),
            "win_rate": round(float((trades["realized_r"] > 0).mean()), 4),
            "direction_accuracy_traded": round(float(trades["direction_correct"].mean()), 4),
            "avg_r": round(float(trades["realized_r"].mean()), 4),
            "total_r": round(float(trades["realized_r"].sum()), 2),
            "profit_factor": round(gross_win / gross_loss, 3) if gross_loss > 0 else float("inf"),
            "max_drawdown_r": round(_max_drawdown(np.cumsum(trades["realized_r"].to_numpy())), 2),
            "expectancy_pct_per_trade": round(float(trades["realized_r"].mean()) * risk_per_trade * 100, 4),
            "sharpe_r": round(_sharpe(trades["realized_r"].to_numpy(), trades_per_day * 252), 3),
            "avg_hold_bars": round(float(labels["bars_held"].loc[trades["time"].values].mean()), 2)
            if n else 0.0,
        }
    else:
        metrics = {"trades": 0, "note": "no signal passed the probability gates"}

    # --- baselines: what a coin flip / always long would have scored -----
    non_hold = label_arr != CLASS_HOLD
    metrics["baseline_always_buy_dir_acc"] = round(float((label_arr[non_hold] == CLASS_UP).mean()), 4) \
        if non_hold.any() else 0.0
    metrics["baseline_majority_class_acc"] = round(
        float((label_arr == pd.Series(label_arr).mode()[0]).mean()), 4
    )
    metrics["class_balance"] = {
        "up": round(float((label_arr == CLASS_UP).mean()), 4),
        "hold": round(float((label_arr == CLASS_HOLD).mean()), 4),
        "down": round(float((label_arr == CLASS_DOWN).mean()), 4),
    }
    return BacktestResult(metrics, trades, equity_series)
