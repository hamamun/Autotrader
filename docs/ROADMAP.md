# Roadmap

Status of the build, in the order that actually reduces risk.

## P0 — what is in this repo now (working, compiles, tested)

* [x] Multi-timeframe engine: M30 bias / M15 setup / M5 trigger, closed bars only
* [x] Three votes per timeframe (trend, momentum, structure) → score → BUY/HOLD/SELL
* [x] Higher timeframe veto (M5/M15 may not fight M30)
* [x] 10-point checklist per timeframe (ADX, volatility window, spread, session,
      news window, over-extension, direction, HTF alignment)
* [x] ATR-based SL, TP1 = 1.5R, TP2 = 3R, swing-aware stop tightening
* [x] Risk % position sizing, broker min/max/step volume, stops-level respected
* [x] Break-even + ATR trailing stop, daily loss cap, trades/day cap, max open
* [x] Dashboard panel with the full information set (see `PANEL_SPEC.md`)
* [x] Signal journal: every displayed signal is written and scored against real bars
* [x] ONNX inference inside MT5 (24 inputs → P(up), P(hold), P(down))
* [x] Python research pipeline: features → triple-barrier labels → walk-forward
      LightGBM teacher → distilled network → ONNX → honest backtest → report
* [x] Python/MQL5 feature parity checker (`cli parity`)
* [x] Contract tests (`pytest`), 8 passing

## P1 — the next two weeks

* [ ] Pixel-match the dashboard to your reference interface (needs the screenshot)
* [ ] Run `cli parity` on your broker and fix any drift
* [ ] Train v1 on 2–5 years of your symbol, 3 brokers for comparison
* [ ] Signal-only forward test: 200+ signals, journal vs backtest comparison
* [ ] Add the M5 close countdown + pending-signal counter to the panel (data is ready)

## P2 — after the journal confirms the backtest

* [ ] Partial exits (50% at 1R, trail the rest) with the journal measuring both halves
* [ ] Optional limit-order entry mode and measure real slippage vs assumption
* [ ] Push live journal stats to a small local dashboard (same numbers, browser view)
* [ ] Per-session and per-weekday hit rate in the journal report; disable the worst buckets
* [ ] Correlation guard so two symbols cannot double one market risk

## P3 — genuinely advanced (only if P2 holds up)

* [ ] Sequence model (GRU/TCN) over the raw M5 window instead of a flat feature vector,
      exported the same way through ONNX.
* [ ] Volatility-regime clustering with a separate model per regime
* [ ] Economic calendar integration via `CalendarValueHistory` (broker-dependent)
* [ ] Portfolio allocation across 2–5 uncorrelated symbols with one risk budget

## Explicitly out of scope

* Guaranteeing a fixed accuracy number. The journal exists so the number is
  discovered, not promised. See `ACCURACY_AND_RISK.md`.
* Grid / martingale / no-stop recover-everything logic. It is the standard
  way retail EAs die.
