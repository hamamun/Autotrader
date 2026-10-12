# The feature contract (version 1.0.0)

The model gets **24 numbers**. The order is frozen. If Python and MQL5 ever
disagree about this list or the order, the model silently gets garbage, so:

* `python/autotrader/config.py :: FEATURE_NAMES` is the single source of truth
* `mql5/Include/Autotrader/SignalEngine.mqh :: BuildFeatures()` must match it
* changing either one means: bump `FEATURE_CONTRACT_VERSION`, retrain, retest

## Layout

8 features per timeframe × 3 timeframes, in this order:

| index | timeframe | role |
|---|---|---|
| 0–7 | M5 | scalping trigger |
| 8–15 | M15 | short term setup |
| 16–23 | M30 | intraday bias |

## The 8 features (same for every timeframe)

| # | name | formula | what it captures |
|---|---|---|---|
| 1 | `ema_spread_atr` | (EMA9 − EMA21) / ATR | trend direction and strength |
| 2 | `ema_fast_slope_atr` | (EMA9[t] − EMA9[t−3]) / ATR | is the trend accelerating |
| 3 | `ema_slow_slope_atr` | (EMA21[t] − EMA21[t−3]) / ATR | slow trend backing the fast one |
| 4 | `stretch_bias_atr` | (close − EMA50) / ATR | over-extension, mean reversion risk |
| 5 | `adx_norm` | ADX / 100 | trend vs chop |
| 6 | `di_diff_norm` | (+DI − −DI) / 100 | who is pushing, buyers or sellers |
| 7 | `rsi_centered` | (RSI − 50) / 50 | momentum balance |
| 8 | `macd_hist_change_atr` | (2·hist[t] − hist[t−1]) / ATR | momentum acceleration |

Everything is normalised by ATR so the same model works on XAUUSD, EURUSD
or an index without rescaling — and so the numbers stay in a small range
which is what neural networks like.

## Timing rules

* All values come from the **closed** bar (`shift 1` in MQL5 terms).
* Higher timeframe values are the **last bar that had closed** at that
  moment — a 15 minute bar that closes exactly when the M5 bar closes *is*
  usable (Python: `merge_asof(..., allow_exact_matches=True)`).
* The signal fires when the M5 bar closes; the order goes in on the next
  tick. Labels in `labels.py` assume the fill is the **next bar's open**.

## Proving parity on your own data

A model is only as honest as its inputs. To verify that the MQL5 side and
the Python side compute identical numbers on *your* symbol and broker feed:

1. Export M5 candles to CSV (MT5 → History Center, or the CLI `fetch`).
2. Attach `Scripts/Autotrader/ExportFeatures` to an M5 chart; it writes
   `MQL5/Files/autotrader_features_<SYMBOL>.csv`.
3. Run:

```bash
python -m autotrader.cli parity --mt5-csv autotrader_features_XAUUSD.csv --csv data/xauusd_m5.csv
```

A pass looks like `max abs diff < 0.001`. Anything larger means the two
sides disagree — fix that **before** trusting any backtest number.
