"""Market data in and out.

Three ways to get M5 candles:

1. `from_mt5()`    - direct pull through the MetaTrader5 python package
                     (Windows, MT5 terminal installed and logged in).
2. `load_csv()`    - any CSV with time/open/high/low/close (MT5 "Export"
                     from the History Center or from an MQL5 script).
3. `make_synthetic()` - offline smoke test data, never used for real models.
"""

from __future__ import annotations

import io
import os

import numpy as np
import pandas as pd

OHLC = ["open", "high", "low", "close"]
COLMAP = {
    "date": "time", "<date>": "time", "datetime": "time", "timestamp": "time",
    "unnamed: 0": "time", "index": "time",
    "tickvol": "tick_volume", "tick_volume": "tick_volume", "volume": "volume",
    "vol": "tick_volume", "spread": "spread",
}


def _normalise(df: pd.DataFrame) -> pd.DataFrame:
    df = df.rename(columns={c: COLMAP.get(str(c).strip().lower(), str(c).strip().lower())
                            for c in df.columns})
    df = df.loc[:, ~df.columns.duplicated()]
    if "time" not in df.columns:
        raise ValueError("CSV needs a time/date column")
    df["time"] = pd.to_datetime(df["time"], errors="coerce", utc=False)
    df = df.dropna(subset=["time"])
    missing = [c for c in OHLC if c not in df.columns]
    if missing:
        raise ValueError(f"CSV missing columns: {missing}")
    for c in OHLC:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    if "tick_volume" not in df.columns:
        df["tick_volume"] = 0.0
    df = df.dropna(subset=OHLC).sort_values("time").drop_duplicates("time")
    df = df.set_index("time")
    minutes = int(pd.Series(df.index).diff().dropna().dt.total_seconds().median() // 60) or 5
    df["bar_minutes"] = minutes
    return df[[*OHLC, "tick_volume", "bar_minutes"]]


def load_csv(path: str, bar_minutes: int | None = None) -> pd.DataFrame:
    """Read a candle CSV. Separator and column names are auto detected."""
    with open(path, "r", encoding="utf-8-sig", errors="ignore") as fh:
        raw = fh.read()
    sep = "\t" if raw.count("\t") > raw.count(",") else (";" if raw.count(";") > raw.count(",") else ",")
    df = pd.read_csv(io.StringIO(raw), sep=sep)
    out = _normalise(df)
    if bar_minutes:
        out["bar_minutes"] = bar_minutes
    return out


def save_csv(df: pd.DataFrame, path: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    df.to_csv(path, index_label="time")


def from_mt5(symbol: str, timeframe: str = "M5", bars: int = 200_000) -> pd.DataFrame:
    """Pull candles from the running MT5 terminal (Windows only)."""
    try:
        import MetaTrader5 as mt5  # type: ignore
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "MetaTrader5 package not available. On Linux/Mac use load_csv() "
            "with an M5 CSV exported from MT5."
        ) from exc

    tf_map = {
        "M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15, "M30": mt5.TIMEFRAME_M30,
        "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4, "D1": mt5.TIMEFRAME_D1,
    }
    if not mt5.initialize():
        raise RuntimeError(f"mt5.initialize failed: {mt5.last_error()}")
    try:
        rates = mt5.copy_rates_from_pos(symbol, tf_map[timeframe], 0, bars)
        if rates is None or len(rates) == 0:
            raise RuntimeError(f"no data for {symbol} {timeframe}: {mt5.last_error()}")
        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        df["tick_volume"] = df.get("tick_volume", df.get("real_volume", 0))
        return _normalise(df)
    finally:
        mt5.shutdown()


def resample(m5: pd.DataFrame, minutes: int) -> pd.DataFrame:
    """Build M15 / M30 candles from M5 candles on the exchange clock."""
    rule = f"{minutes}min"
    agg = {"open": "first", "high": "max", "low": "min", "close": "last",
           "tick_volume": "sum"}
    out = m5.resample(rule, origin="epoch", label="left", closed="left").agg(agg).dropna()
    out["bar_minutes"] = minutes
    return out


def make_synthetic(bars: int = 20_000, seed: int = 7, start: str = "2024-01-01",
                   price: float = 2000.0, point: float = 0.01) -> pd.DataFrame:
    """Regime switching random walk, only for smoke tests."""
    rng = np.random.default_rng(seed)
    idx = pd.date_range(start, periods=bars, freq="5min")

    # volatility and drift switch every few hundred bars
    n_regimes = max(1, bars // 400)
    states = rng.choice([-1, 0, 1], size=n_regimes)
    drift = np.repeat(states * 0.6 * point, 400)[:bars]
    drift = np.pad(drift, (0, max(0, bars - len(drift))), constant_values=0.0)

    steps = rng.normal(0.0, 6.0 * point, size=bars) + drift
    close = price + np.cumsum(steps)
    open_ = np.concatenate([[price], close[:-1]])
    wick = np.abs(rng.normal(0.0, 4.0 * point, size=bars))
    high = np.maximum(open_, close) + wick
    low = np.minimum(open_, close) - wick

    df = pd.DataFrame(
        {"open": open_, "high": high, "low": low, "close": close,
         "tick_volume": rng.integers(50, 500, size=bars).astype(float)},
        index=idx,
    )
    df["bar_minutes"] = 5
    return df
