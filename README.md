# Autotrader

Fully automatic MT5 trading EA — pure MQL5. No Python, no training, no waiting.

**Motto:** out of every 100 directions (BUY/SELL/HOLD) the EA gives, ~98 should
end as successful trades (TP hit), with real, reachable entry and TP levels.

## Current status

**Phases 1–6 built.** The EA now decides and trades by itself: it reads three
timeframes at once, judges the evidence, says HOLD most of the time, and when it
does speak it opens a real order with a real stop and walks it through the
60/80/100 TP ladder. What is left is **Phase 7 — proving the 98%**, so until
then it belongs on a **demo account**.

> The one input is still **Auto Trading** ON/OFF. Phases 3–6 added **no** new
> settings — every number is measured from the market or derived from the
> symbol's own profile.

What works right now:

- **MAIN panel** — exact look/rows of the reference: title, Bid/Ask/Spread,
  Regime, SIGNAL (BUY/SELL/HOLD with arrows + colors), Confidence % + label
  (and the threshold it must beat), Entry / Stop Loss / Take Profit with USD
  estimates and points, Risk:Reward, Session | Expected Duration, STATUS,
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
- **Eight evidence groups**, each weighted by the current regime, blended into
  the Confidence % — M30 bias, structure, M5 trigger, zone quality, momentum,
  volume, volatility fitness, quote quality. It speaks only at or above the
  symbol's own auto-set threshold (~85 calm forex → ~90+ crypto) and says HOLD
  the rest of the time. Signals are **latched** (hysteresis) so nothing flickers.
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
- **Scoreboard + audit trail (Phase 6, live).** Today / All Time
  `Num of Signal, Win, Loss, BE` come from the broker's deal history with closing
  deals grouped per position, so one trade = one result and the owner's rule
  applies exactly (positive = Win, negative = Loss, zero = BE). Every signal,
  open, cancel, failure and close is appended to `MQL5\Files\Autotrader_log.csv`,
  and the Experts log gets one audit line per closed bar with the full score
  breakdown and the reason for the answer.
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
   folder (merge `Experts/` and `Include/`). Nothing else in this repo is needed
   by MT5 — `tools/` and the docs stay here.
3. Open `MQL5/Experts/Autotrader/Autotrader.mq5` in **MetaEditor** and press
   **Compile** (F7). Zero errors expected.
4. In MT5: open a chart of any symbol at **M5, M15 or M30**, drag `Autotrader`
   onto the chart, enable **Algo Trading**.
5. **Use a demo account until Phase 7 has proven the numbers.**

The only input is **Auto Trading** ON/OFF. Everything else self-configures.
Turn it OFF and the EA keeps analysing and displaying directions but sends no
orders.

### Reading the panel while it learns a symbol

For the first moments on a symbol with little downloaded history the STATUS row
says `Calibrating — studying this symbol, collecting price history`; the engine
needs 120 closed bars on each of M30, M15 and M5 before it will speak. After
that, STATUS always tells the truth: `Watching — HOLD (M5/M15 would fight the
M30 bias)`, `Watching — HOLD (score 78 below the 90 needed)`,
`Signal armed — latched, score 92 vs 90 needed`, `Waiting — entry order placed
at the zone edge`, `Trading — position open, managing the ladder`,
`Frozen — news freeze — USD news`, `Stand-down — daily loss limit reached`.

## Roadmap (see PLAN.md for the full design)

| Phase | Deliverable | Status |
|-------|-------------|--------|
| 1 | Panels (MAIN + LIVE TRADING), drag, auto-size | **built** |
| 2 | Symbol Intelligence + Regime engine | **built** |
| 3 | Direction engine (M30→M15→M5) + confidence % | **built** |
| 4 | Trade engine: entries, SL logic, TP ladder, break-even | **built** |
| 5 | Safety layer (news, spread, daily loss, restart-restore) | **built** |
| 6 | Auto-execution + Win/Loss/BE logging + counters | **built** |
| 7 | Full validation toward the 98% motto: tester, walk-forward, PBO/Deflated Sharpe, permutation test, demo forward (pure MQL5, see PLAN 6C) | **built — owner runs the tests and the demo** |
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
- `python3 tools/score_sim.py` — re-states the decision and money arithmetic and
  asserts the weights sum to 1.00, that random noise never clears the threshold
  (HOLD really is the default), that all 15 regime/direction gates behave as
  designed, that risk sizing never overshoots the dial, that the 50/30/20 ladder
  always closes exactly the opening volume after volume-step rounding, and that
  the owner's Win/Loss/BE rule reproduces PLAN §1's four worked cases.
- `python3 tools/volume_profile_sim.py` — re-states the session volume-profile
  walk of `VolumeFlow.mqh` (from the POC, grow outward until 70% of the volume
  is inside) and runs it over 20,000 synthetic sessions plus the spike shapes
  that used to kill it. Added after the 14 Oct 2026 runtime report
  `Autotrader (EURUSDm,M15) array out of range in 'VolumeFlow.mqh' (200,38)`,
  which only some symbols produced: it reproduces the old `dn++` walk that left
  the bin array (13% of ordinary sessions, 40% of spike-shaped ones) and asserts
  that the patched walk never forms an out-of-range index, never counts a bin
  twice, always keeps VAL <= POC <= VAH and always reaches 70% of the volume.
