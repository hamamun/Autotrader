"""Frozen configuration shared by training, export and the MQL5 EA.

The feature order defined here MUST stay identical to
`mql5/Include/Autotrader/SignalEngine.mqh :: BuildFeatures()`.
If you change it, bump the contract version and retrain.
"""

FEATURE_CONTRACT_VERSION = "1.0.0"

# Timeframe order is fixed: index 0 = M5 (trigger), 1 = M15 (setup), 2 = M30 (bias)
TFS = [5, 15, 30]
TF_LABELS = {5: "M5", 15: "M15", 30: "M30"}

# 8 features per timeframe -> 24 inputs for the model
FEATURES_PER_TF = [
    "ema_spread_atr",      # (ema_fast - ema_slow) / atr
    "ema_fast_slope_atr",  # (ema_fast[t] - ema_fast[t-3]) / atr
    "ema_slow_slope_atr",  # (ema_slow[t] - ema_slow[t-3]) / atr
    "stretch_bias_atr",    # (close - ema_bias) / atr
    "adx_norm",            # adx / 100
    "di_diff_norm",        # (plus_di - minus_di) / 100
    "rsi_centered",        # (rsi - 50) / 50
    "macd_hist_change_atr",  # (2*hist[t] - hist[t-1]) / atr
]

FEATURE_NAMES = [
    f"{TF_LABELS[tf].lower()}_{name}" for tf in TFS for name in FEATURES_PER_TF
]
FEATURE_COUNT = len(FEATURE_NAMES)  # 24

# Class order used everywhere: 0 = UP (buy), 1 = HOLD, 2 = DOWN (sell).
# The ONNX model must output probabilities in exactly this order.
CLASS_UP, CLASS_HOLD, CLASS_DOWN = 0, 1, 2
CLASS_NAMES = ["UP", "HOLD", "DOWN"]

DEFAULT_INDICATORS = {
    "ema_fast": 9,
    "ema_slow": 21,
    "ema_bias": 50,
    "atr_period": 14,
    "adx_period": 14,
    "rsi_period": 14,
    "macd_fast": 12,
    "macd_slow": 26,
    "macd_signal": 9,
    "swing_lookback": 20,
}

# Label / trade geometry. Keep in sync with the EA inputs.
DEFAULT_TRADE = {
    "sl_atr_mult": 1.5,
    "tp1_rr": 1.5,
    "tp2_rr": 3.0,
    "max_bars_hold": 12,     # M5 bars -> 1 hour maximum holding time
    "hold_band_r": 0.25,     # timeout move smaller than this counts as HOLD
}
