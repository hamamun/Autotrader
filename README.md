# Autotrader

Fully automatic MT5 trading EA — pure MQL5. No Python, no training, no waiting.

**Motto:** out of every 100 directions (BUY/SELL/HOLD) the EA gives, ~98 should
end as successful trades (TP hit), with real, reachable entry and TP levels.

## Current status

**Phase 1 built — interface preview.** The panels are live and faithful to the
owner's reference screenshot; the direction engine arrives in Phase 2.

What works right now:

- MAIN panel — exact look/rows of the reference: title, Bid/Ask/Spread, Regime,
  SIGNAL (BUY/SELL/HOLD with arrows + colors), Confidence % + label, Entry /
  Stop Loss / Take Profit (with USD estimates and points), Risk:Reward,
  Session | Expected Duration, STATUS line, Today / All Time counters.
- LIVE TRADING panel — appears while a trade is "open" (preview shows a sample
  order): order info, Entry → Now with floating P/L, **Stop Loss journey**,
  Break-Even state, Trail Stop (phase 2), TP1/TP2/TP3 ladder (60/80/100) with
  live status, manager STATUS line.
- Soft eye-friendly look: dark-grey body (not black), **Segoe UI** font —
  **12pt for every row, 14pt for the SIGNAL row only** — in one soft light-grey
  colour. **Only the SIGNAL and STATUS rows are coloured** (BUY soft green /
  SELL soft red / HOLD muted grey; STATUS soft amber, red for alerts); nothing
  else carries colour.
- Drag: press-and-drag either panel's **title bar** (the lighter grey bar with
  the title text in it) — the whole unit moves together; the chart underneath
  does not scroll while you drag.
- Auto-size: panels measure every row at its real drawn size (including the
  14pt SIGNAL row) and grow wider/taller to fit — **no truncation, no overlap.**
- Auto-detects chart timeframe: on anything other than M5/M15/M30 the panel
  shows labels only + "Incompatible chart" status.
- Preview cycle: sample BUY → HOLD → SELL states rotate every ~20 seconds so
  all looks can be reviewed. **These are UI samples, not trading signals.**
  The STATUS line says "PHASE 1 UI PREVIEW" to make that unambiguous.

## Install (MT5)

1. In MT5: **File → Open Data Folder**.
2. Copy the contents of this repo's `MQL5/` folder into the terminal's `MQL5/`
   folder (merge `Experts/` and `Include/`).
3. Open `MQL5/Experts/Autotrader/Autotrader.mq5` in **MetaEditor** and press
   **Compile** (F7). Zero errors expected.
4. In MT5: open a chart of any symbol at **M5, M15 or M30**, drag
   `Autotrader` onto the chart, enable **Algo Trading**.

The only input is **Auto Trading** ON/OFF. Everything else self-configures.

## Roadmap (see PLAN.md for the full design)

| Phase | Deliverable | Status |
|-------|-------------|--------|
| 1 | Panels (MAIN + LIVE TRADING), drag, auto-size, preview states | **built** |
| 2 | Symbol Intelligence + Regime engine | next |
| 3 | Direction engine (M30→M15→M5) + confidence % | |
| 4 | Trade engine: entries, SL logic, TP ladder, break-even | |
| 5 | Safety layer (news, spread, daily loss, restart-restore) | |
| 6 | Auto-execution + Win/Loss/BE logging + counters | |
| 7 | Tester + demo validation toward the 98% motto | |
| 8 | Trailing stop | later |

Win/Loss rule (owner's): closed at any positive value = **Win**,
closed at any negative value = **Loss**, closed at exactly zero = **BE**.
