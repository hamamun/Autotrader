# The dashboard (interface) specification

The panel is drawn with chart objects (`OBJ_RECTANGLE_LABEL`, `OBJ_LABEL`,
`OBJ_BUTTON`) in `mql5/Include/Autotrader/Panel.mqh`. That choice matters:
chart objects work in every MT5 build, are clickable, and the whole look is
controlled from one palette block at the top of the file.

## Current layout

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ AUTOTRADER  v0.1.0                                 XAUUSD   M5 / M15 / M30   │
│ Balance 10,000.00  Equity 10,120.00  Floating 120.00   12:34:05  spr 1.8  LONDON+NY │
├──────────────────────────────────────────────────────────────────────────────┤
│  OVERALL   BUY ^                      CONFIDENCE 82%     TF AGREEMENT 3/3     │
├──────────────────────────────────────────────────────────────────────────────┤
│  TF      SIGNAL      CONF    ENTRY      SL       TP1      R:R    LOT   CHECKLIST │
│  M30       BUY         78   2345.10  2338.20  2355.45   1:1.5   0.12    10/10 │
│  M15       BUY         71   2345.10  2339.05  2354.18   1:1.5   0.15     9/10 │
│  M5        HOLD        44       --       --       --      --      --     7/10 │
├──────────────────────────────────────────────────────────────────────────────┤
│  Note: no edge (score below threshold)                                        │
│  Measured signal hit rate:  M5 61% (n=143)  M15 57% (n=98)  M30 52% (n=61)    │
├──────────────────────────────────────────────────────────────────────────────┤
│ [ AUTO ] [ SIGNAL ONLY ] [ CLOSE ALL ]           Risk 0.50%  Day P/L +0.00    │
│                                            Trades 3  Positions 1   [ HIDE ]   │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Field by field

| section | field | meaning |
|---|---|---|
| header | symbol, timeframes | which market the panel is reading |
| header | balance / equity / floating | live account state |
| header | server time, spread, session | the market conditions the decision was taken in |
| banner | OVERALL | the verdict across all three timeframes (majority + conviction) |
| banner | CONFIDENCE | 0–100, blend of score strength and checklist result |
| banner | TF AGREEMENT | how many timeframes agree with the verdict |
| row | TF / role | M30 = intraday bias, M15 = short term setup, M5 = scalping trigger |
| row | SIGNAL | BUY / SELL / HOLD for that timeframe, colour coded |
| row | CONF | 0–100 confidence for that timeframe |
| row | ENTRY | suggested entry (ask for buy, bid for sell) |
| row | SL / TP1 | stop and first target, ATR based, swing-aware |
| row | R:R | reward to risk of the TP1 |
| row | LOT | risk-based position size for the current balance |
| row | CHECKLIST | how many of the 10 gates passed — a trade needs 10/10 |
| status | Note | why a row is HOLD / blocked |
| stats | measured hit rate | real outcome of past signals, per timeframe |
| footer | mode buttons | AUTO / SIGNAL ONLY, CLOSE ALL, HIDE |
| footer | Risk, Day P/L, Trades, Positions | the risk state of the session |

## Matching your old interface exactly

The panel is intentionally built as a **skin over a fixed data model**, so
matching your previous tool is a layout job, not a rewrite. To do it
pixel-for-pixel I need the reference:

* the screenshot itself (it did **not** arrive with the request — nothing was
  attached to the conversation), **or**
* a list of the exact labels, their order, and which are columns vs rows.

Once I have it, the work is confined to two places:

1. `CAtPanel::Init()` — geometry: panel size, section heights, column
   fractions (`frac[AT_COLS]`), fonts.
2. the palette block — `AT_C_BG`, `AT_C_HEADER`, `AT_C_BUY`, `AT_C_SELL`, …

No other file changes, because `Panel::Update()` already receives every
value your old interface displayed. If your reference shows extra fields
(RSI value, ADX value, a candle timer, an account number, a broker name),
tell me which — the data is already computed in the signal engine and only
needs a label.

## Extras already available to add to any layout

* per-row `TP2` and trailing-stop status
* indicator readouts (ADX, RSI, ATR in points) per timeframe
* the pending-signal count and the journal file path
* next-candle countdown (from the M5 close time)
* last trade result and running daily win/loss
