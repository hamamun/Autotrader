# Autotrader — architecture

## The one idea

A trading robot has two completely different jobs, and they must live in
two different places:

| job | where it runs | why there |
|---|---|---|
| **Decide** (buy / sell / hold, entry, SL, TP) | researched in Python, exported as a small ONNX file | you need data, backtests, statistics, retraining — none of that exists inside MT5 |
| **Execute** (lot size, orders, stops, spread checks, risk limits) | MQL5 Expert Advisor inside MT5 | it must run 24/5 on your terminal/VPS with the broker connection, and it must never depend on a Python process being alive |

So: **Python is the brain factory, the EA is the brain.** The EA ships with
a complete rule engine, so it works even before any model is trained, and
gets sharper once you have a model.

## Layered view

```
 ┌────────────────────────────────────────────────────────────────────┐
 │ 4. INTERFACE          mql5/Include/Autotrader/Panel.mqh            │
 │    per timeframe: direction, confidence, entry, SL, TP, R:R, lot,  │
 │    checklist  +  one overall verdict  +  account strip             │
 ├────────────────────────────────────────────────────────────────────┤
 │ 3. RISK / EXECUTION   mql5/Include/Autotrader/RiskManager.mqh      │
 │    risk% lot size, broker stop distance, spread gate, daily loss   │
 │    limit, max trades/day, break even, ATR trailing stop            │
 ├────────────────────────────────────────────────────────────────────┤
 │ 2. AI BRAIN (optional) mql5/Include/Autotrader/OnnxBrain.mqh       │
 │    ONNX model, 24 inputs -> P(up), P(hold), P(down)                │
 │    trained in python/, exported by python -m autotrader.cli run    │
 ├────────────────────────────────────────────────────────────────────┤
 │ 1. SIGNAL ENGINE      mql5/Include/Autotrader/SignalEngine.mqh     │
 │    M30 bias  +  M15 setup  +  M5 trigger, closed bars only         │
 │    3 votes per timeframe: trend, momentum, structure               │
 │    higher timeframe veto, 10 point checklist per timeframe         │
 └────────────────────────────────────────────────────────────────────┘
```

## Decision flow for one signal

```
 M5 bar closes
      │
      ├─ feature vector: 24 numbers (8 per timeframe, frozen order)
      │
      ├─ rule engine (always)  ── trend + momentum + structure votes
      │        └─→ score -100..+100  ─→ BUY / HOLD / SELL per timeframe
      │
      ├─ ONNX model (if present)
      │        └─→ P(up), P(hold), P(down)  ─→ trade only if
      │            P(direction) >= min_model_prob
      │
      ├─ HTF veto: M5 and M15 may not fight the M30 bias
      │
      ├─ checklist (10 gates): ADX, volatility floor/ceiling, spread,
      │  session, news window, distance from EMA50, direction, HTF align
      │
      └─ all three timeframes tradeable + same direction
               └─→ ATR stop, TP1 = 1.5R, TP2 = 3R
                    lot = risk% of balance / stop distance
```

Nothing in this chain repaints: every value comes from **closed bars**
(`shift >= 1`). A signal that changes its mind after the fact is worse than
no signal.

## Why these technology choices

| choice | reason |
|---|---|
| **MQL5 EA, not a Python bot** | you asked for it to live in MT5. It also removes an entire class of failures: no socket, no DLL, no external process to babysit on a VPS. |
| **ONNX inside MT5** (build 3620+) | MetaTrader 5 has an ONNX Runtime built in. We export a plain `MatMul/Relu/Softmax` network, so it runs on every build that supports ONNX at all. No `ai.onnx.ml` domain, no tree-ensemble ops. |
| **Small distilled network, not the big model** | The LightGBM model is the *teacher* (used for research and feature importance). A distilled 24→64→32→3 network is ~15 KB, runs in microseconds, and is easy to keep identical across Python and MQL5. |
| **Pure MQL5 rule engine as the floor** | If the model file is missing, corrupt, or you simply don't trust it, the EA still gives directions, levels and lot sizes. No dependency chain to break. |
| **Triple-barrier labels** | The model learns the thing you actually get paid for: did price reach TP before SL. Not "will the next candle be green". |
| **Walk-forward + untouched holdout** | Time series cannot be randomly split. Every number in the report comes from data that was in the future when the model was fitted. |

## Repo map

```
mql5/
  Experts/Autotrader/Autotrader.mq5     <- attach this to a chart
  Include/Autotrader/Types.mqh          settings + shared structs
  Include/Autotrader/SignalEngine.mqh   the multi timeframe engine
  Include/Autotrader/RiskManager.mqh    sizing, guards, order execution
  Include/Autotrader/OnnxBrain.mqh      ONNX inference inside MT5
  Include/Autotrader/Panel.mqh          the on-chart dashboard
  Scripts/Autotrader/ExportFeatures.mq5 parity check: writes the 24 inputs
python/
  autotrader/config.py      frozen feature contract
  autotrader/features.py    indicator + feature maths (mirrors MQL5)
  autotrader/labels.py      triple barrier labelling
  autotrader/model.py       student network + ONNX export/verify
  autotrader/train.py       teacher, walk forward, distillation, metrics
  autotrader/backtest.py    honest event backtest with costs
  autotrader/cli.py         the entry point
  tests/                    contract tests (pytest)
docs/                        this folder
```

## What is deliberately NOT here yet

* News calendar pulling (MT5's calendar functions exist but broker coverage
  varies) — the current filter is a manual time window.
* Multi-symbol portfolio logic — the engine is per chart today.
* Reinforcement learning for entry timing — meaningless until the
  directional layer is proven on your data.
