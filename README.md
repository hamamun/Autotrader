# Autotrader

MT5 trading EA — pure MQL5, with one owner-facing input: Auto Trading ON/OFF.

**Research target, not a result:** the project aims for a high rate of successful
trades, but the 98% motto is unverified. Code review and synthetic checks do not
establish profitability or real-money readiness.

## Current status

**Core phases 1–6 are implemented; the two-sided display, audit, and pending-order
freshness improvements are applied in code but still need native MT5 validation.** The EA reads three timeframes and may
place orders when Auto Trading is enabled. Strategy Tester, walk-forward, and
demo-forward validation have not established its performance; keep it on demo
until those checks are completed and reviewed.

> The one input is still **Auto Trading** ON/OFF. Phases 3–6 added **no** new
> settings — every number is measured from the market or derived from the
> symbol's own profile.

What works right now:

- **MAIN panel** — exact look/rows of the reference: title, Bid/Ask/Spread,
  Regime, a latched SIGNAL or a clearly-labelled BUY/SELL BIAS (not a trade
  signal), two-sided evidence scores and a qualitative tier, Entry / Stop Loss /
  Take Profit with USD estimates and points,
  Risk:Reward, Session | Expected Duration, STATUS,
  Today / All Time counters.
- **Direction engine (Phase 3, live).** The SIGNAL row is real. The engine
  always reads **M30 (bias) → M15 (setup) → M5 (trigger)** whatever chart it
  sits on, and the chart's own timeframe decides which product is shown and
  traded (Option A: M5 = scalping, M15 = short-term, M30 = intraday).
- **2026 evidence stack (Phase 3, live).** Non-repainting Nadaraya–Watson kernel
  regression with an adaptive envelope, Ehlers Super Smoother / Decycler /
  Laguerre RSI with adaptive gamma, Kalman trend line with ATR-derived noise,
  Smart-Money Concepts (structure, BOS/CHoCH, order blocks, fair value gaps,
  liquidity sweeps, zones), volume flow (CVD-style delta, participation ratio,
  session volume profile POC/VAH/VAL, session + rolling VWAP), plus Wilder ATR
  and the EMA stack. All hand-written MQL5.
- **Two-sided direction engine.** BUY and SELL are each scored from the same
  eight regime-weighted evidence groups; opposing M30, structure, momentum,
  trigger, zone, and volume evidence therefore weighs against that side. A
  visible bias can be labelled weak / developing / moderate / strong / very
  strong even while execution is waiting or blocked. These are uncalibrated
  evidence indices, not probabilities. A bias is never an auto-trade signal;
  execution still requires the configured score threshold, regime and quote
  gates, a valid price plan,
  safety permission, and risk checks. The existing hard execution safeguards
  remain in place, and signals stay latched to avoid flicker.
- **Hard gates**: M5/M15 may never fight M30; VOLATILE / QUIET / TRANSITION /
  range-middle stand aside; a trend is only continued, a range is only faded at
  its TOP/BOTTOM; the stop must not be absurd, risk:reward must not be thin, the
  target must be reachable inside the lane's window, the spread must not be
  expensive, the quote must be fresh. Every rejection is written in plain words
  on the STATUS row and in the audit log.
- **Real, reachable numbers.** Entry is a limit at a real zone edge (or the
  confirmation quote), the stop is structural + ATR buffer or a volatility stop
  and always respects the broker's stops level and the spread, TP = the symbol's
  own dial × its own wiggle, and Expected Duration is computed from the target
  distance and this symbol's real speed — not a fixed phrase.
- **Trade engine (Phase 4, live).** Risk-sized lots from equity × the risk dial,
  a **hard broker-side stop on every order**, broker-side TP3, the ladder
  TP1 60% → close 50%, TP2 80% → close 30%, TP3 100% → close the rest,
  **break-even (stop moved to Entry) the moment TP1 banks**, a time exit when a
  trade stalls, and repair of any protection that goes missing.
- **LIVE TRADING panel (Phase 4, live).** No longer a preview: it appears only
  while a real position or pending entry exists and shows the real ticket, lot,
  open time, Entry → Now with floating P/L, the stop's journey
  (`initial` → `moved to Entry`), Break-Even state, Trail Stop (Phase 8), the
  TP1/TP2/TP3 ladder with live status and the manager's STATUS line.
- **Safety layer (Phase 5, live).** Trading permissions, stale-quote and weekend
  detection, the symbol's own spread limit, HIGH-impact news freeze (MQL5
  economic calendar) for the symbol's currencies, gap-shock freeze, daily-loss
  stand-down (3% of the day-start equity), equity floor (15% off the high-water
  mark). It only stops **new** trades — open trades keep being managed.
- **Restart-restore (Phase 5, live).** After a restart, reconnection or
  re-attach, every open trade is rebuilt from the broker's own data plus two
  terminal global variables per ticket; if those are gone the ladder state is
  inferred from the remaining volume and whether the stop already sits at Entry.
- **Scoreboard + decision audit.** The CSV now records a two-sided assessment
  per closed lane bar (BUY/SELL scores, gap, evidence breakdown, spread, plan
  levels, and trade-eligibility reason), then records latched signals and
  eventual outcomes by position ID. Closed-trade net includes opening and
  closing commission, swap, and fees; gross P/L and each cost component are
  preserved for review. The existing Win/Loss/BE display still groups deals by
  position so partial closes count as one trade. Start Phase 7 runs with a fresh
  log file; do not append older-build logs to the corrected 16-column schema.
- **Pending-order freshness.** Pending entries are rechecked against current
  signal qualification, Auto Trading, and safety permission, and expire after
  at most three chart bars (bounded by expected duration, with a 10-minute
  minimum). The same expiry is sent to brokers that support specified expiry;
  local cancellation covers GTC-only symbols.
- **Symbol Intelligence + Regime engine (Phase 2, live)** — unchanged and now
  feeding real decisions: attach to any symbol and the EA studies it and sets its
  own hidden dials; the Regime row stays specific
  (`▲ TRENDING UP — Strong`, `↩ PULLBACK in UPTREND`, `↔ RANGING — price at
  range BOTTOM`, `⚠ VOLATILE`, `● QUIET`, `? TRANSITION`, …).
- **Interface (Phase 1, live)** — soft dark-grey body, Segoe UI, 12pt everywhere
  and 14pt for the SIGNAL row only, colour on SIGNAL and STATUS alone, drag by
  the title bar, auto-size with no truncation, and the incompatible-chart view on
  anything other than M5/M15/M30. Since Phase 3 the panels also redraw only when
  a row's text actually changed, so the heavier maths never fights the UI.

## Install (MT5)

1. In MT5: **File → Open Data Folder**.
2. Copy the contents of this repo's `MQL5/` folder into the terminal's `MQL5/`
   folder (merge `Experts/`, `Include/` and `Scripts/`). Keep the directory
   structure: `MQL5/Include/Autotrader/Validation.mqh` must be present alongside
   the other `.mqh` files, and `MQL5/Scripts/Autotrader/Phase7_Report.mq5`
   must be under `Scripts/`. Nothing else in this repo is needed by MT5 —
   `tools/` and the docs stay here.
3. Open `MQL5/Experts/Autotrader/Autotrader.mq5` in **MetaEditor** and press
   **Compile** (F7). Zero errors expected.
4. In MT5: open a chart of any symbol at **M5, M15 or M30**, drag `Autotrader`
   onto the chart, enable **Algo Trading**.
5. **Use a demo account until Phase 7 has proven the numbers.**

**If Phase7_Report says `file 'Include\\Autotrader\\Validation.mqh' not found`:**
this header is already in the repo at `MQL5/Include/Autotrader/Validation.mqh`;
copy it to the **same terminal data folder** used by the MetaEditor compiling
`Phase7_Report.mq5` (MT5 → File → Open Data Folder → `MQL5/Include/Autotrader/`).
Do not put it in `Scripts/Autotrader/` or copy just the `.mq5` script. The
`#include <Autotrader/Validation.mqh>` line searches the terminal's `MQL5/Include`
folder; changing slashes or the script's location won't replace the missing
header. If several MT5 installations are open, check the data folder for the
instance whose MetaEditor you used, then compile again.

The only input is **Auto Trading** ON/OFF. Everything else self-configures.
Turn it OFF and the EA keeps analysing and displaying directions but sends no
orders.

### Reading the panel while it learns a symbol

For the first moments on a symbol with little downloaded history the STATUS row
says `Calibrating — studying this symbol, collecting price history`; the engine
needs 120 closed bars on each of M30, M15 and M5 before it can assess direction.

When there is a directional lead but no executable signal, row 3 shows `BIAS:
BUY/SELL (not a trade signal)`. The evidence row shows both sides and the lead,
for example `BUY 62 / SELL 47 | BUY leads by 15 (moderate; score is not
probability; trade threshold 88)`. If the scores are too close, it shows
`DIRECTION: MIXED / WAIT` and keeps both scores visible. Any displayed indicative
entry/stop/target plan is not an order. STATUS separately explains whether the
EA is waiting for score, blocked by a market gate, frozen by safety, or has a
qualified signal. The evidence tiers have not been calibrated against outcomes.

A real latched `SIGNAL: BUY/SELL` is still distinct from a display bias. It may
only trade if the analytical execution gates and the separate safety/risk checks
all pass. A pending limit is cancelled if the signal, Auto Trading permission,
or safety permission is no longer valid, and otherwise has a bounded freshness
window.

## Roadmap (see PLAN.md for the full design)

| Phase | Deliverable | Status |
|-------|-------------|--------|
| 1 | Panels (MAIN + LIVE TRADING), drag, auto-size | **built** |
| 2 | Symbol Intelligence + Regime engine | **built** |
| 3 | Two-sided direction engine (M30→M15→M5) + uncalibrated evidence tiers | **implemented; requires MT5 validation** |
| 4 | Trade engine: entries, SL logic, TP ladder, break-even | **built** |
| 5 | Safety layer (news, spread, daily loss, restart-restore) | **built** |
| 6 | Auto-execution + Win/Loss/BE logging + counters | **implemented; pending freshness and audit extended** |
| 7 | Tester, walk-forward, PBO/Deflated Sharpe, permutation test, demo forward (pure MQL5, see PLAN 6C) | **not yet validated; must be run and reviewed** |
| 8 | Trailing stop | later |

Win/Loss rule (owner's): closed at any positive value = **Win**,
closed at any negative value = **Loss**, closed at exactly zero = **BE**.
Success % = Win ÷ (Win + Loss) — that is the number Phase 7 must push to ~98.

## Development checks (not part of the EA)

This workspace has no MetaEditor, so three small Python checkers were used while
writing the MQL5; they live in `tools/` and are never copied into MT5:

- `python3 tools/mql5_lint.py` — brackets, include guards, duplicate
  definitions, declared-vs-defined class methods, EA calls that do not exist,
  and a blocklist of MQL5 functions and constants that do not exist. Since the
  14 Oct 2026 compile it also checks every ALL-CAPS name used (it must be one
  of our `#define`s / enums / glyphs or a verified MQL5 constant), the property
  argument handed to `OrderGetDouble` / `PositionGetDouble` / `HistoryDealGet*`
  / `AccountInfo*`, and the `TRADE_RETCODE_*` family — the three mistakes that
  compile reported.
- `python3 tools/score_sim.py` — mirrors the weights, two-sided bias selection,
  evidence tiers, independent trade threshold, hard regime gates, risk sizing,
  TP ladder, pending-order lifetime, and full deal-cost aggregation. These are
  arithmetic/static checks only, not backtest or profitability evidence.
- `python3 tools/volume_profile_sim.py` — re-states the session volume-profile
  walk of `VolumeFlow.mqh` (from the POC, grow outward until 70% of the volume
  is inside) and runs it over 20,000 synthetic sessions plus the spike shapes
  that used to kill it. Added after the 14 Oct 2026 runtime report
  `Autotrader (EURUSDm,M15) array out of range in 'VolumeFlow.mqh' (200,38)`,
  which only some symbols produced: it reproduces the old `dn++` walk that left
  the bin array (13% of ordinary sessions, 40% of spike-shaped ones) and asserts
  that the patched walk never forms an out-of-range index, never counts a bin
  twice, always keeps VAL <= POC <= VAH and always reaches 70% of the volume.
