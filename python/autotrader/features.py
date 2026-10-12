"""Indicator maths and the 24 feature columns.

Everything here mirrors the MQL5 code bar for bar:

* MT5 smoothing for ATR / RSI / ADX is Wilder's smoothing (SMMA).
* MACD uses EMA seeds then standard EMA recursion.
* "last closed bar" = the bar at index i, the trade happens on bar i+1.

Run `python -m autotrader.cli parity --mt5-csv <file>` to prove the Python
and MQL5 feature values agree on your own broker data.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from .config import DEFAULT_INDICATORS, FEATURES_PER_TF, FEATURE_NAMES, TFS


# ----------------------------------------------------------------------
# building blocks
# ----------------------------------------------------------------------
def sma(series: pd.Series, period: int) -> pd.Series:
    return series.rolling(period, min_periods=period).mean()


def ema(series: pd.Series, period: int) -> pd.Series:
    """EMA seeded with the SMA of the first `period` values (MT5 behaviour)."""
    values = series.to_numpy(dtype=float)
    out = np.full(values.shape, np.nan)
    if len(values) < period:
        return pd.Series(out, index=series.index)
    seed = np.nanmean(values[:period])
    out[period - 1] = seed
    k = 2.0 / (period + 1.0)
    for i in range(period, len(values)):
        prev = out[i - 1]
        out[i] = values[i] * k + prev * (1.0 - k)
    return pd.Series(out, index=series.index)


def wilder(series: pd.Series, period: int) -> pd.Series:
    """Wilder's smoothing (RMA) as used by MT5 for ATR, RSI and ADX."""
    values = series.to_numpy(dtype=float)
    out = np.full(values.shape, np.nan)
    if len(values) < period:
        return pd.Series(out, index=series.index)
    out[period - 1] = np.nanmean(values[:period])
    for i in range(period, len(values)):
        out[i] = out[i - 1] + (values[i] - out[i - 1]) / period
    return pd.Series(out, index=series.index)


def true_range(df: pd.DataFrame) -> pd.Series:
    prev_close = df["close"].shift(1)
    a = df["high"] - df["low"]
    b = (df["high"] - prev_close).abs()
    c = (df["low"] - prev_close).abs()
    return pd.concat([a, b, c], axis=1).max(axis=1)


def atr(df: pd.DataFrame, period: int) -> pd.Series:
    return wilder(true_range(df), period)


def rsi(df: pd.DataFrame, period: int) -> pd.Series:
    delta = df["close"].diff()
    gain = delta.clip(lower=0.0)
    loss = (-delta).clip(lower=0.0)
    avg_gain = wilder(gain.fillna(0.0), period)
    avg_loss = wilder(loss.fillna(0.0), period)
    rs = avg_gain / avg_loss.replace(0.0, np.nan)
    out = 100.0 - (100.0 / (1.0 + rs))
    return out.fillna(100.0).where(avg_loss.notna())


def adx(df: pd.DataFrame, period: int):
    up_move = df["high"].diff()
    down_move = -df["low"].diff()
    plus_dm = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
    minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)
    tr = wilder(true_range(df), period)
    plus_di = 100.0 * wilder(pd.Series(plus_dm, index=df.index), period) / tr.replace(0.0, np.nan)
    minus_di = 100.0 * wilder(pd.Series(minus_dm, index=df.index), period) / tr.replace(0.0, np.nan)
    dx = 100.0 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0.0, np.nan)
    adx_line = wilder(dx.fillna(0.0), period)
    return adx_line, plus_di, minus_di


def macd_hist(df: pd.DataFrame, fast: int, slow: int, signal: int) -> pd.Series:
    line = ema(df["close"], fast) - ema(df["close"], slow)
    sig = ema(line.dropna(), signal).reindex(line.index)
    return line - sig


# ----------------------------------------------------------------------
# per timeframe features
# ----------------------------------------------------------------------
def timeframe_features(df: pd.DataFrame, cfg: dict | None = None) -> pd.DataFrame:
    """8 feature columns for one timeframe, indexed by bar CLOSE time."""
    cfg = {**DEFAULT_INDICATORS, **(cfg or {})}
    out = pd.DataFrame(index=df.index)

    a = atr(df, cfg["atr_period"]).replace(0.0, np.nan)
    ef = ema(df["close"], cfg["ema_fast"])
    es = ema(df["close"], cfg["ema_slow"])
    eb = ema(df["close"], cfg["ema_bias"])
    adx_line, plus_di, minus_di = adx(df, cfg["adx_period"])
    r = rsi(df, cfg["rsi_period"])
    hist = macd_hist(df, cfg["macd_fast"], cfg["macd_slow"], cfg["macd_signal"])

    out["ema_spread_atr"] = (ef - es) / a
    out["ema_fast_slope_atr"] = (ef - ef.shift(3)) / a
    out["ema_slow_slope_atr"] = (es - es.shift(3)) / a
    out["stretch_bias_atr"] = (df["close"] - eb) / a
    out["adx_norm"] = adx_line / 100.0
    out["di_diff_norm"] = (plus_di - minus_di) / 100.0
    out["rsi_centered"] = (r - 50.0) / 50.0
    out["macd_hist_change_atr"] = (2.0 * hist - hist.shift(1)) / a

    out = out[FEATURES_PER_TF]
    minutes = int(df["bar_minutes"].iloc[0]) if "bar_minutes" in df.columns else _infer_minutes(df)
    out.index = df.index + pd.to_timedelta(minutes, unit="m")
    return out


def _infer_minutes(df: pd.DataFrame) -> int:
    if len(df) > 1:
        delta = (df.index[1] - df.index[0]).total_seconds() / 60.0
        if delta > 0:
            return int(delta)
    return 5


def build_feature_frame(frames: dict[int, pd.DataFrame], cfg: dict | None = None) -> pd.DataFrame:
    """Merge M5/M15/M30 features onto the M5 decision clock.

    A feature row with index C means: "the M5 bar that closed at C has just
    closed, and every higher timeframe value used here was final at C".
    """
    m5 = frames[TFS[0]]
    base = timeframe_features(m5, cfg).rename(
        columns={c: f"m5_{c}" for c in FEATURES_PER_TF}
    )

    merged = base
    for tf in TFS[1:]:
        htf = timeframe_features(frames[tf], cfg).rename(
            columns={c: f"m{tf}_{c}" for c in FEATURES_PER_TF}
        )
        merged = pd.merge_asof(
            merged.reset_index().rename(columns={"index": "close_time"}),
            htf.reset_index().rename(columns={"index": "close_time"}),
            on="close_time",
            direction="backward",       # only fully closed HTF bars
            allow_exact_matches=True,   # a bar closing at C is usable at C
        ).set_index("close_time")

    merged = merged.reindex(columns=FEATURE_NAMES)
    return merged


def clean_features(x: pd.DataFrame) -> pd.DataFrame:
    """Drop warm up rows, clip absurd outliers caused by tiny ATR."""
    x = x.replace([np.inf, -np.inf], np.nan)
    x = x.dropna(how="any")
    return x.clip(-20.0, 20.0)
