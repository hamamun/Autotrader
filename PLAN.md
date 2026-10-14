# AUTOTRADER — Master Build Plan v4 (pure MQL5)

> Status: Phase 1 (interface) built 12 Oct 2026; Phase 2 (Symbol Intelligence
> + Regime engine) built 13 Oct 2026; **Phases 3–6 (direction engine, trade
> engine, safety layer, auto-execution + scoreboard) built 14 Oct 2026.**
> The EA now gives real BUY/SELL/HOLD directions with real Entry/SL/TP and
> trades them by itself.
> Next step: **Phase 7 — prove it** (Strategy Tester + walk-forward + demo
> forward, threshold tuning toward the 98% motto). Until Phase 7 signs it off,
> it runs on a **demo account**.
> Note: the code cannot be compiled inside this workspace (no MetaEditor), so
> the first compile in MetaEditor (F7) is the owner's to run; `tools/` holds
> two Python checkers used while writing it (see section 6B.4).
> **14 Oct 2026 — first compile feedback (owner):** 17 errors, all from four
> names — `ORDER_PRICE_SL` / `ORDER_PRICE_TP` (the pending-order stop and
> target are `ORDER_SL` / `ORDER_TP`), `TRADE_RETCODE_TRADE_TIMEOUT` (it is
> `TRADE_RETCODE_TIMEOUT`, 10012) and one missing glyph macro `GLYPH_ARROW`
> (now `#define`d with the other glyphs in `Panel.mqh`). Fixed the same day,
> and `tools/mql5_lint.py` grew the three checks that would have caught them.

---

## 1. Our motto (exact definition)

> **Out of every 100 directions (BUY / SELL / HOLD) the EA gives,
> about 98 must end as SUCCESSFUL trades (TP hit),
> and the printed Entry / TP must be real and reachable.**

Rule of design: **only speak when the odds are extremely high,
and say HOLD the rest of the time.**

### Win / Loss counting — OWNER'S RULE (confirmed, simple)

> **Order closed at ANY positive value = Win.**
> **Order closed at ANY negative value = Loss.**
> Closed at exactly zero = BE (break-even) — rare, counted separately, not a loss.

Worked example (how it looks in practice):

Setup: BUY on XAUUSDm, Entry 2544.00, risk 1% (= USD 10) at Stop Loss.
TP ladder (60/80/100% of computed target D = 7 points):
TP1 = 2547.00 (close 50% of lot), TP2 = 2549.00 (close 30%), TP3 = 2551.00 (close 20%).
After TP1 → Stop Loss is moved to Entry (break-even) — the trade can no longer lose.

| Case | What happens | Result | Counter |
|------|--------------|--------|---------|
| 1 | TP1 (+3.5), TP2 (+3.0), TP3 (+2.4) all hit | **+USD 8.90 profit** | **Win +1** |
| 2 | TP1 hit (+3.5), then price comes back, rest closed at Entry (+0) | **+USD 3.50 profit** | **Win +1** |
| 3 | Price goes straight to Stop Loss | **−USD 10.00** | **Loss +1** |
| 4 | No TP hit, SL already at break-even, trade closed at Entry | **USD 0.00** | **BE +1** (neither Win nor Loss) |

- **Win** = closed at **any positive value** (owner's rule).
- **Loss** = closed at **any negative value** (owner's rule).
- **BE** = closed at exactly zero — rare, shown separately.
- **Success % = Win ÷ (Win + Loss). This is the number that must approach 98.**

---

## 1B. Break-Even — what it means and what it does (owner asked)

**Meaning in one line: moving the Stop Loss up to the Entry price.**

What it does, with the same example (BUY @ 2544.00, SL 2524.80, TP1 2547.00):

1. Trade opens. Risk = 10 points (SL 2524.80). If wrong now → −USD 10.
2. Price rises and hits TP1 (2547.00). We bank 50% of the lot = **+USD 3.50 locked.**
3. Now we move the Stop Loss from 2524.80 **up to 2544.00 = the Entry price → "break-even".**
4. From this moment the worst case is: price falls back, rest of the lot exits at
   2544.00 = USD 0. Total result of the trade = +USD 3.50 → **still a Win.**
   The best case: price keeps rising → TP2, TP3 → bigger Win.

**Why it is essential for the 98% motto:** after break-even, a trade **can never
turn into a Loss** (except broker slippage, which we guard against). It converts
"maybe a loss" into "small win or zero". This single mechanism does more for
the success rate than any indicator.

Panel life-cycle of the SL (visible in LIVE TRADING panel):
`Stop Loss: 2524.81 (initial)` → after TP1 → `Stop Loss: 2544.31 (moved to Entry)`.
(Trailing stop — the next step, phase 2 — keeps moving it further into profit later.)

---

## 2. Owner decisions (locked)

| # | Decision |
|---|----------|
| 1 | Pure MQL5. No Python, no training, no waiting. |
| 2 | Any **symbol**; chart **timeframe must be M5, M15 or M30** (see 4.4). |
| 3 | Zero inputs except one: **AutoTrading ON/OFF**. Everything else self-configures. |
| 4 | **No session blocking.** Trade whenever suitable conditions exist. Safety freezes only (news shock, quote failure, spread explosion, weekend gaps). |
| 5 | Fully automatic direction display AND fully automatic trading. |
| 6 | **TP ladder (owner's idea):** computed TP = D → TP1 = 60%·D, TP2 = 80%·D, TP3 = 100%·D. Partial close 50% / 30% / 20%. After TP1 → break-even. Trailing stop = later phase. |
| 7 | Interface: same information and look as owner's screenshot, **title = "Autotrader V1.0"**. |
| 8 | Indicators: 2026-modern stack (see section 5). |
| 9 | Two display states: **SIGNAL view** (no open order) and **LIVE TRADING panel** (appears when an order is placed). TP-ladder detail lives in the LIVE TRADING panel. |
| 10 | **Text must never truncate or overlap.** Panel auto-sizes to content and is **draggable**. |
| 11 | Counters: Win / Loss / BE exactly as section 1 example. |
| 12 | Interface style (13 Oct 2026): dark-**grey** body (not black), soft **Segoe UI**, **12pt all rows / 14pt SIGNAL row only**, soft muted colours, and **only SIGNAL + STATUS rows are coloured** — everything else one soft grey. Drag by the title bar; width auto-grows to the widest row. |
| 13 | **Symbol Intelligence (Phase 2):** zero extra inputs — the EA studies any symbol it is attached to (family, price format, normal wiggle, usual spread, current jumpiness) and auto-sets its hidden dials (stop/target distances, proof threshold, spread limit) relative to what is normal *for that symbol*. |
| 14 | **Regime labels must be SPECIFIC (13 Oct 2026):** never a bare TRENDING/RANGING. The row must say direction + strength, or where price sits in the range (full agreed list in 3.5). Regime row stays plain soft text (decision #12). |
| 15 | **Option A locked (14 Oct 2026):** one direction per chart. The panel reports the direction product of the chart's own timeframe (M5 = scalping, M15 = short-term, M30 = intraday) and trades only that lane. Three lanes wanted → three charts, each with its own panel, orders and counters. No extra panel rows were added. |
| 16 | **Full 2026 indicator stack locked (14 Oct 2026):** Nadaraya–Watson, Ehlers DSP family, Kalman, Smart-Money Concepts and volume-flow tools are all built as Phase 3 evidence — hand-written MQL5, no external library. |
| 17 | **Still zero inputs (reaffirmed 14 Oct 2026):** Phases 3–6 added *no* user settings. Every new number (weights, thresholds, distances, lot size, news window, daily-loss limit, equity floor) is either measured from the market or derived from the symbol's own profile. `Auto Trading` ON/OFF remains the only control. |
| 18 | **Demo until proven (14 Oct 2026):** because Phases 3–6 landed together, the EA runs on a demo account until Phase 7 (tester + walk-forward + demo forward) confirms the scoreboard. Real money only after that. |
| 19 | **First runtime report fixed (14 Oct 2026):** attaching to some symbols printed `Autotrader (EURUSDm,M15) array out of range in 'VolumeFlow.mqh' (200,38)` — the session volume-profile walk. The low-side pointer incremented (`dn++`) instead of walking down, so whenever the top of the session range held no volume it climbed from bin to bin until it ran off the end of `double bin[24]`; which symbols died depended only on their session profile, which is why others ran normally. The same neighbour read also leaned on a range guard written *inside* a `?:`, which does not bound a fixed-size array read. Fixed: `dn--`, both neighbour reads and the order-log ticket read in `TradeEngine.mqh` moved behind plain `if`s, and `tools/volume_profile_sim.py` now reproduces the old fault and pins the new behaviour. |

---

## 3. Interface design

### 3.1 Layout position (designed)

One visual unit, docked at the **top-left** of the chart (chart stays readable):

```
┌─────────────────────────────────────┐   ← drag by any header
│  MAIN PANEL (always visible)        │      (whole unit moves together)
└─────────────────────────────────────┘
┌─────────────────────────────────────┐
│  LIVE TRADING PANEL                 │   ← appears ONLY while a
│  (docked directly below, same size) │      position is open
└─────────────────────────────────────┘
```

- Chosen **bottom-docked** (not right side) so it never covers MT5's
  trade buttons or the chart's right-hand price axis.
- Both panels share the same width, stack vertically, zero overlap.
- The unit is **draggable** by its headers to anywhere on the chart,
  and **auto-sizes** to its content (longest text measured at runtime,
  padding scaled with DPI) — nothing is ever cut off.

### 3.2 MAIN PANEL — pixel-faithful to owner's screenshot (no open order state)

```
┌───────────────────────────────────────────────────────────┐
│ Autotrader V1.0 | ETHUSDm | TF: M30 | Auto Trading: ON     │
├───────────────────────────────────────────────────────────┤
│ Bid: 2555.65 | Ask: 2565.65 | Spread: 100 pts              │
├───────────────────────────────────────────────────────────┤
│ Regime: RANGING                                           │
├───────────────────────────────────────────────────────────┤
│ SIGNAL: ▲ BUY                                             │
│ Confidence: 61% — Confident                               │
├───────────────────────────────────────────────────────────┤
│ Entry: 2544.31 / gap est. +USD 3.95 (1234 pts away)        │
│ Stop Loss: 2524.81 / est. -USD 6.24 (1950 pts)             │
│ Take Profit: 2588.04 / est. +USD 13.99 (4373 pts)          │
│ Risk:Reward 1:2.2                                         │
├───────────────────────────────────────────────────────────┤
│ Session: London | Expected Duration: ~5-16 hours           │
├───────────────────────────────────────────────────────────┤
│ STATUS: No trade - fresh broker quote unavailable          │
├───────────────────────────────────────────────────────────┤
│ Today: Num of Signal: 1, Win: 1, Loss: 0, BE: 0            │
│ All Time: Num of Signal: 42, Win: 33, Loss: 1, BE: 8       │
└───────────────────────────────────────────────────────────┘
```

Rows, order and format are identical to the screenshot. Only changes:
- brand name "Autotrader V1.0" (owner decision),
- counters gain one extra field **BE** (needed for honest counting, owner decision #11),
- "Take Profit" row shows the **full** computed TP (= TP3). The ladder detail
  lives in the LIVE TRADING panel while a trade is open.

### 3.3 LIVE TRADING PANEL (owner's concept — designed)

Appears the moment an order is placed; disappears when no position remains.
Header row is the key: **"LIVE TRADING"**.

```
┌───────────────────────────────────────────────────────────┐
│ LIVE TRADING                                              │
├───────────────────────────────────────────────────────────┤
│ Order #84521 | BUY 0.10 lot | opened 14:32                 │
│ Entry: 2544.31 → Now: 2551.20  (floating +USD 6.89)        │
├───────────────────────────────────────────────────────────┤
│ Stop Loss : 2544.31  (started 2524.81 → moved to Entry)    │
│ Break-Even: LOCKED                                        │
│ Trail Stop: OFF (phase 2)                                 │
├───────────────────────────────────────────────────────────┤
│ TP1 2547.31 (60%) : ✓ HIT 14:51 — closed 50% of lot        │
│ TP2 2549.31 (80%) : pending — 68% progress to target       │
│ TP3 2551.31 (100%): pending                                │
├───────────────────────────────────────────────────────────┤
│ STATUS: Managing — running to TP2                          │
└───────────────────────────────────────────────────────────┘
```

Row spec:

| Row | Content |
|-----|---------|
| Order | ticket #, direction, lot size, open time |
| Mark | Entry → current price, floating P/L in USD (and pts) |
| **Stop Loss** | **the LIVE protective price — always visible. Shows current SL and its journey: `2524.81 (initial)` → `2544.31 (moved to Entry)` → later `trailing @ price`** |
| Break-Even | mechanism state: `not armed` → `ARMED (after TP1)` → `LOCKED` |
| Trail Stop | `OFF (later phase)` now; Phase 8: `ACTIVE — trailing @ price` |
| TP1/TP2/TP3 | ladder price + % of D, live status: `✓ HIT time — closed N%` / `pending — NN% progress` / `skipped (manual)` |
| STATUS | what the manager is doing: running to TP1 / moved SL to Entry / closed for time / closing… |

Note: the MAIN panel's "Stop Loss" row = the **planned** SL of the current signal.
The LIVE panel's "Stop Loss" row = the **live** SL of the open order (it changes:
initial → Entry → trailing). Both are always on screen.

This is where the owner's TP-ladder idea becomes visible and auditable in real time.

**Built (Phase 4):** this panel is no longer a preview. It appears only while a
real position or a real pending entry exists (magic number = ours), shows the
real ticket, the real lot, the real stop and its journey (`initial` → `moved to
Entry`), the real ladder state per level (`✓ HIT 14:51 — closed 50% of lot`,
`pending — 68% progress to target`), and what the manager is doing right now.

### 3.4 Incompatible chart behavior (owner rule)

If the chart timeframe is **not** M5 / M15 / M30 (e.g. M1, H1, D1):
the panel shows **row labels only, no values**, and STATUS names the problem.

```
┌───────────────────────────────────────────────────────────┐
│ Autotrader V1.0 | ETHUSDm | TF: H1 | Auto Trading: ON      │
├───────────────────────────────────────────────────────────┤
│ Bid: --------- | Ask: --------- | Spread: ---------        │
│ Regime: ---------                                         │
│ SIGNAL: ---------                                         │
│ Confidence: ---------                                     │
│ Entry: ---------                                          │
│ Stop Loss: ---------                                      │
│ Take Profit: ---------                                    │
│ Risk:Reward: ---------                                    │
│ Session: ---------                                         │
│ STATUS: Incompatible chart - please attach to M5, M15 or M30│
│ Today: ---------                                          │
│ All Time: ---------                                       │
└───────────────────────────────────────────────────────────┘
```

(Exact fit of long messages is handled by the auto-size logic — the panel
widens itself; text is never clipped.)

### 3.5 Regime row — expanded specific labels (owner-agreed 13 Oct 2026, BUILT in Phase 2)

The Regime row always answers: *what is the market doing + which
direction/where + how strong/clear is it?* Symbols are drawn from unicode
code points (as with ▲▼✓) so they render in the panel font on MT5/Windows.

| Display | Meaning |
|---|---|
| `▲ TRENDING UP — Strong` / `— Weak/Early` | uptrend, clean or just starting |
| `▼ TRENDING DOWN — Strong` / `— Weak/Early` | downtrend, clean or just starting |
| `↩ PULLBACK in UPTREND` | main trend UP, temporary fall against it |
| `↪ PULLBACK in DOWNTREND` | main trend DOWN, temporary bounce against it |
| `↔ RANGING — price at range TOP` | sideways, near resistance |
| `↔ RANGING — price at range BOTTOM` | sideways, near support |
| `↔ RANGING — price in MIDDLE` | sideways, no edge (HOLD territory) |
| `⚠ VOLATILE — fast swings both ways` | chaotic expansion, protection mode |
| `● QUIET — flat, compressed` | very low movement, waiting for expansion |
| `? TRANSITION — direction unclear` | old trend weakening, new one unconfirmed |
| `● CALIBRATING — collecting price history` | not enough bars yet after attach |

Classification method (RegimeEngine.mqh, closed bars only, no repaint):
direction agreement of five witnesses (close vs EMA50, EMA20 vs EMA50,
EMA50 slope, higher-high/higher-low structure, close vs EMA100), trend
efficiency ratio, current ATR vs its own longer-run normal, and position
inside the recent 60-bar range. Safety states (VOLATILE/QUIET) are checked
first; a fast one-directional move is a strong trend, not "volatile".

### 3.6 Symbol Intelligence (Phase 2, BUILT — internal, no new panel rows)

On attach and every ~5s afterwards (SymbolIntelligence.mqh) the EA builds
a profile card for the chart symbol: family (Forex/Metal/Crypto/Index/
Energy/Other, from the symbol name + broker contract mode), digits/point/
tick size+value/contract size/volume limits, live-sampled typical spread,
and behaviour on the chart TF (current ATR vs longer-run normal, average
swing). From that profile it derives its hidden dials — SL/TP distances as
multiples of the symbol's own ATR (calmer family = tighter, jumpier =
wider), confidence threshold (≈85 calm forex → ≈90+ crypto/volatile),
"spread too expensive" limit (≈2.5× typical spread) and the 1% risk
baseline. Jumpy-right-now (ATR ≫ its own normal) widens the stop dial and
raises the proof threshold automatically. These dials feed Phase 3/4;
in Phase 2 they already scale the preview Entry/SL/TP distances, and the
STATUS row reports `<Family> profile ready` (or "Calibrating…" while
history is short). No panel rows were added — the locked interface in
3.2/3.3 is unchanged apart from the Regime/STATUS text itself.

Note: even on an M5 chart, the engine internally reads all three timeframes
(M30 bias → M15 setup → M5 trigger). **This is now built** (`MarketData.mqh`
keeps one closed-bar cache per timeframe; `DirectionEngine.mqh` holds three
`CTFAnalysis` snapshots). The chart's TF decides which **direction product**
the panel reports:

| Chart TF | Direction product | Style | Built |
|----------|-------------------|-------|-------|
| M5  | trade trigger & entry timing | scalping | ✔ lane `AT_LANE_M5` |
| M15 | short-term setup direction | short-term | ✔ lane `AT_LANE_M15` |
| M30 | intraday bias direction | intraday | ✔ lane `AT_LANE_M30` |

**The A/B question — DECIDED: Option A, locked 14 Oct 2026 (decision #15).**
Option B is kept below for reference only and is not built.

**Option A — one direction per chart (default):**
the panel shows the direction product of **the chart's timeframe**.

```
Chart: M5  →  panel title "TF: M5"   → shows SCALPING direction only
Chart: M15 →  panel title "TF: M15"  → shows SHORT-TERM direction only
Chart: M30 →  panel title "TF: M30"  → shows INTRADAY direction only
```
Want all three open at once? Open three charts (M5 + M15 + M30), each with
its own panel and its own trades. Clean, simple, like professional workspaces.

**Option B — all three directions in one panel on one chart:**
one bigger panel showing three stacked signal blocks at once.

```
┌──────────────────────────────┐
│ Autotrader V1.0 | ETHUSDm | TF: M30 | Auto Trading: ON │
│ ...price / regime rows...    │
│ M5  SCALPING   : SIGNAL ▲ BUY  Conf 88% ...           │
│ M15 SHORT-TERM : SIGNAL — HOLD Conf 54% ...           │
│ M30 INTRADAY   : SIGNAL ▼ SELL Conf 91% ...           │
└──────────────────────────────┘
```
Convenient overview in one glance, but the EA then trades up to **three
style-lanes separately** (each lane = its own orders + own LIVE TRADING
sub-panel + own Win/Loss counters). More complex, more trades.

Both options use the exact same visual style and rows.

---

## 4. The technology (pure MQL5, self-adapting, zero training)

### A. Symbol Intelligence (auto-configuration engine) — BUILT (Phase 2)
On attach to any chart, and continuously afterwards:
- class detection: forex / metals / crypto / indices / energy (your ETHUSDm = crypto),
- micro-structure: digits, point, tick size/value, contract size, margin rules,
- rolling behavior profile: typical spread, tick activity by hour, ATR% per TF,
  gap behavior, average swing size, noise level,
- derives ALL parameters automatically: SL/TP multipliers, TP-ladder distances,
  trailing speed, break-even trigger, confidence threshold, lot sizing,
- keeps re-calibrating as conditions change (owner motto: adapt to the symbol).

### B. Regime Engine ("Regime:" row) — BUILT (Phase 2)
TRENDING / RANGING / VOLATILE / QUIET via efficiency ratio + adaptive decycler
(Ehlers cycle/trend separation), ATR percentile, structure persistence.
Behavior switches: TRENDING → pullback continuation; RANGING → mean reversion
at envelope extremes; VOLATILE/QUIET → mostly HOLD (protects the 98%).

### C. Modern Indicator Layer (2026 stack) — BUILT (Phase 3, `ModernIndicators.mqh`)
1. **Nadaraya–Watson kernel regression (Gaussian), non-repainting variant** —
   `ATMI_NW()`. Fits each bar from that bar and the bars *before* it only, so
   the line can never redraw itself. Bandwidth adapts to how wild the market is
   right now; the envelope is ±2 × the fit's own weighted mean absolute error.
   Used as trend baseline, slope evidence and the fallback entry zone.
2. **Ehlers DSP filters** — `ATMI_SuperSmoother()` (10-bar 2-pole Butterworth),
   `ATMI_Decycler()` / `ATMI_DecyclerOscPct()` (20-bar cycle cut),
   `ATMI_LaguerreRSI()` with **adaptive gamma** (a clean move gets a faster
   filter, chop gets a slower one). Near-zero-lag triggers, no MACD-style lag.
3. **Kalman filter** trend line — `ATMI_Kalman()` / `ATMI_KalmanSlope()`,
   local-level model whose process/measurement noise come from the symbol's own
   ATR, so it trusts price in calm markets and smooths harder in noisy ones.
4. **Regime-weighted confluence score (0–100)** — eight evidence groups, each
   weighted by the current regime (section 8.2). Feeds the Confidence % row.
5. **Smart-Money Concepts engine** — `SmartMoney.mqh`: confirmed swing structure
   (HH/HL vs LH/LL), BOS, CHoCH, order blocks (last opposite candle before the
   displacement, with mitigation checks), fair value gaps (3-candle imbalance,
   with fill checks), liquidity sweeps (wick through an old high/low closing back
   inside), and the nearest usable demand/supply zone per side with its distance
   in ATRs.
6. **Volume-flow tools** — `VolumeFlow.mqh`: tick-volume delta (CVD-style) and
   its 5-bar slope, participation ratio vs the symbol's own average, session
   volume profile (POC / VAH / VAL, 24 bins, 70% value area), session VWAP and
   rolling 100-bar VWAP.
7. **Classics that still earn their place:** Wilder ATR (SL/TP sizing),
   EMA 20/50/100/200 (baseline + stack), efficiency ratio, spread monitor.
   Nothing else old without a reason.

### D. Direction & Confidence Engine (the heart of the 98%) — BUILT (Phase 3, `DirectionEngine.mqh`)
Evidence checklist with regime-adjusted weights (0–100):
M30 bias, M15 structure, M5 trigger, zone quality (OB/FVG/liquidity),
momentum (modern oscillators), volume agreement, volatility fitness, quote quality.
- Score ≥ threshold (auto per symbol class, ~85–90) → BUY/SELL.
- Below → HOLD (the default state). M5/M15 never fight M30.

**As built (Phase 3):** the regime also decides *which* direction is allowed —
a trend may only be continued, a pullback may only be taken with the trend, a
range may only be faded at its TOP/BOTTOM, and VOLATILE / QUIET / TRANSITION /
range-MIDDLE are hard HOLD territory. Signals are **latched** with hysteresis
(released only 8 points below the line, or on a veto, a direction flip, or old
age) so the panel never flickers. Every rejection writes its reason into the
STATUS row and the audit log.

### E. Trade Management Engine (feeds the LIVE TRADING panel) — BUILT (Phase 4, `TradeEngine.mqh`)
- Entry: limit at zone edge or confirmation close.
- SL: structural level + ATR buffer; if price is in "open space" (e.g. near
  all-time high) → volatility SL (ATR-based); if even that is absurd → no trade.
  **Hard broker-side SL on every order. Never trade without it.**
- TP ladder: TP1 60% / TP2 80% / TP3 100%, partial close 50/30/20,
  SL → Entry after TP1 (break-even), trailing after TP2 (phase 2).
- Time exit if trade stalls beyond Expected Duration.
- State survives restart / reconnection (position state restored, panel redraws).

**As built (Phase 4):** lot size = equity × risk dial ÷ (stop distance valued in
account money), normalised to the broker's volume step and re-checked against
free margin; the broker's own minimum lot is refused if it would risk more than
3× the dial. Entry is a LIMIT at the zone edge when a valid zone sits 0.05–0.60
ATR away on the right side, otherwise a market entry at the confirmation quote.
The stop is structural + 0.25 ATR when a usable swing sits 0.55–3.0 ATR away,
else the volatility stop (`sl_mult` × ATR), always ≥ the broker stops level and
the spread, and the trade is refused if the stop would exceed 3.5 ATR or 3% of
price. TP3 is set broker-side at open (so the target survives even if the EA
dies), TP1/TP2 partials are sent by the EA, break-even moves the stop to Entry
the moment TP1 banks, and a trade that never reaches TP1 within 1.5× its
expected duration is closed for time. Protection is re-checked and repaired on
every pass (at most once per 5 s, so a refusing broker is never hammered).
Restore reads the broker's own position/order data plus two terminal global
variables per ticket (starting volume, expected duration); if those are gone the
ladder state is inferred from the remaining volume and whether the stop already
sits at Entry.

### F. Risk & Safety Manager — BUILT (Phase 5, `SafetyManager.mqh`)
Risk % per trade (auto, ~1% baseline), auto lot size, max daily loss stand-down
(account protection — not session blocking), news shock freeze (MQL5 calendar),
spread explosion guard, weekend gap guard, slippage limits, magic numbers,
equity floor. STATUS line reports any safety condition in plain words.

**As built (Phase 5), in the order the guards are checked:** terminal / EA /
account / expert trading permissions → broker symbol trade mode → quote age
(> 120 s = no fresh quote, and a stale weekend quote is named as such for
non-crypto symbols) → spread vs the symbol's own limit → HIGH-impact news for
either of the symbol's currencies (no new entries from 30 min before to 15 min
after; if the calendar cannot be reached the guard switches itself off and says
so in the log rather than blocking forever) → gap shock (a new bar opening more
than 3 ATR away freezes entries for 3 bars) → today's realised loss vs 3% of the
day-start equity (stand-down until tomorrow) → equity below 85% of its recorded
high-water mark. Day-start equity and the high-water mark live in terminal global
variables, so a restart cannot erase them. The magic number is derived from the
symbol + timeframe (never an input), so each chart lane stays isolated and manual
trades are never touched. Slippage/deviation is fixed in points; requotes, price
changed, off-quotes and timeouts are retried up to 3 times.

### G. Execution & Feedback — BUILT (Phase 6, `StatsKeeper.mqh`)
Fully automatic order sending (slippage-aware, retry logic), every signal logged
to CSV (signal, score, prices, outcome) → feeds Today / All Time counters and
lets us audit the 98% at any time.

**As built (Phase 6):** counters are computed from the broker's own deal history
filtered by magic + symbol, with closing deals **grouped by position id** so that
one trade = one result even though the ladder closes it in three pieces. The
owner's rule is applied to the group's net result (profit + swap + commission):
positive = Win, negative = Loss, |net| < half a cent = BE. Today's numbers use the
same pass with the day's start as the cut. Signal counts (BUY/SELL latches only —
HOLD is not a "signal") are kept in terminal global variables so they survive a
restart. Every signal, open, cancel, failure, ladder step and close is appended
to `MQL5\Files\Autotrader_log.csv` (rotated at 4 MB), and the Experts log gets
one audit line per closed lane bar with the full score breakdown and the reason
for the answer.

---

## 5. How we PROVE the 98% before real money

1. MT5 Strategy Tester — every tick based on **real ticks**, 1–2 years,
   across several symbol classes (forex, gold, crypto, index).
2. Walk-forward check — tune on one window, verify on the next (no curve-fitting).
3. Demo forward 4–8 weeks — the panel's own Win / Loss / BE counters are the judge.
4. Small live → scale only if the scoreboard stays on target.

---

## 6. Build order (phases)

| Phase | Deliverable | Notes |
|-------|-------------|-------|
| 1 | MAIN + LIVE TRADING panels, exact look, drag + auto-size, live quotes, sample states (incl. incompatible chart view) | **BUILT** — in `MQL5/`. Preview cycles BUY→HOLD→SELL every ~20s. Look revised 13 Oct 2026 (soft/dark-grey, 12/14pt, drag + width fixes, decision #12) |
| 2 | Symbol Intelligence + Regime Engine | **BUILT** 13 Oct 2026 — `SymbolIntelligence.mqh` + `RegimeEngine.mqh`; Regime row live with the expanded labels (3.5), profile dials auto-set (3.6). Signals still preview until Phase 3 |
| 3 | Direction engine (M30→M15→M5) + Confidence % | **BUILT 14 Oct 2026** — `MarketData.mqh`, `ModernIndicators.mqh`, `SmartMoney.mqh`, `VolumeFlow.mqh`, `DirectionEngine.mqh`. Real BUY/SELL/HOLD, latched, with real reachable Entry/SL/TP |
| 4 | Trade engine: entry rules + SL logic + TP ladder + break-even + management (LIVE panel goes live-live) | **BUILT 14 Oct 2026** — `TradeEngine.mqh`. The owner's 60/80/100 ladder with 50/30/20 partials, break-even after TP1, time exit, restart restore. The LIVE TRADING panel is no longer a preview: it shows the real ticket |
| 5 | Safety layer: news, spread, daily loss, restart-restore | **BUILT 14 Oct 2026** — `SafetyManager.mqh` (7 guards, see 4F) + restore inside `TradeEngine.mqh` |
| 6 | Auto-execution + Win/Loss/BE logging + counters | **BUILT 14 Oct 2026** — `StatsKeeper.mqh` + the auto-execution wiring in `Autotrader.mq5`. Counters live, CSV audit trail live |
| 7 | Full validation (tester, walk-forward, PBO/CPCV/Deflated Sharpe, permutation test, demo forward), all pure MQL5 — see 6C. No tuning inside Phase 7 | **BUILT in MQL5 (14 Oct 2026) — owner compiles, runs tests and demo** |
| 9 | Fine-tuning (only if Phase 7 fails; then re-run Phase 7) | later |
| 8 | Trailing stop (owner: later) | after the core is proven |

Each phase ends with a demo to the owner. Phases 3–6 were built together at the
owner's request on 14 Oct 2026, so their demo is one bigger demo: compile in
MetaEditor (F7), attach to a **demo** chart on M5/M15/M30, and watch the panel,
the Experts log and the scoreboard.

---

## 6B. Phase 3–6 as built — the file map and the judge's weights

### 6B.1 File map (all pure MQL5, no DLL, no Python, no external data)

| File | Lines of work | What it is |
|---|---|---|
| `MQL5/Experts/Autotrader/Autotrader.mq5` | the EA | wires everything: panels, engines, auto-execution, events |
| `Include/Autotrader/Panel.mqh` | Phase 1 | MAIN + LIVE panels, drag, auto-size, 12/14pt soft style (+ redraw economy since Phase 3) |
| `Include/Autotrader/SymbolIntelligence.mqh` | Phase 2 | symbol profile + the hidden dials (+ broker stops level, currencies, trade mode since Phase 3) |
| `Include/Autotrader/RegimeEngine.mqh` | Phase 2 | the 11 specific regime labels (+ raw evidence getters since Phase 3) |
| `Include/Autotrader/MarketData.mqh` | Phase 3 | one closed-bar cache per timeframe, new-bar detection, M30+M15+M5 on any chart |
| `Include/Autotrader/ModernIndicators.mqh` | Phase 3 | Nadaraya–Watson, Ehlers (Super Smoother / Decycler / Laguerre RSI), Kalman, ATR, EMA, VWAP, efficiency |
| `Include/Autotrader/SmartMoney.mqh` | Phase 3 | structure, BOS/CHoCH, order blocks, FVG, liquidity sweeps, zones |
| `Include/Autotrader/VolumeFlow.mqh` | Phase 3 | CVD-style delta, participation ratio, session volume profile, VWAPs |
| `Include/Autotrader/DirectionEngine.mqh` | Phase 3 | the judge: three timeframes, 8 evidence groups, gates, latch, real Entry/SL/TP |
| `Include/Autotrader/SafetyManager.mqh` | Phase 5 | the seven freeze guards |
| `Include/Autotrader/StatsKeeper.mqh` | Phase 6 | Win/Loss/BE scoreboard + CSV audit trail |
| `Include/Autotrader/TradeEngine.mqh` | Phase 4 | lots, orders, ladder, break-even, time exit, protection repair, restore |

### 6B.2 The judge's weights (regime-adjusted, sum = 1.00)

| Evidence group | TRENDING | PULLBACK | RANGE extreme | anything else |
|---|---|---|---|---|
| M30 bias | .20 | .20 | .12 | .15 |
| M15 + lane structure | .18 | .16 | .12 | .15 |
| M5 trigger | .12 | .14 | .14 | .15 |
| Zone quality (OB/FVG/sweep/NW/POC) | .10 | .16 | .24 | .15 |
| Momentum (NW + Kalman + Decycler + SuperSmoother + Laguerre) | .18 | .12 | .10 | .15 |
| Volume (delta + participation + VWAP side) | .08 | .08 | .14 | .10 |
| Volatility fitness (ATR ratio + efficiency + beats the spread) | .08 | .08 | .08 | .10 |
| Quote quality (spread vs limit + tick freshness) | .06 | .06 | .06 | .05 |

Score = 100 × Σ (weight × evidence). Speak only at ≥ the symbol's auto-set
threshold; release a latched signal only below threshold − 8.

### 6B.3 Hard gates (a veto means HOLD whatever the score says)

regime not tradeable (VOLATILE / QUIET / TRANSITION / CALIBRATING / range
middle) · wrong side of the regime for that direction · M5/M15 fighting the M30
bias · M30 itself VOLATILE · spread above the symbol's own limit · quote older
than 120 s · stop wider than 3.5 ATR or 3% of price · risk:reward below 1:1.5 ·
target not reachable inside the lane's window (M5 8 h, M15 16 h, M30 32 h) ·
plus everything the safety layer adds (section 4F).

### 6B.4 Checks used while writing it (no MetaEditor in this workspace)

`tools/mql5_lint.py` — bracket balance, unique include guards, no duplicate
global definitions, every declared class method defined (and every definition
declared), every method the EA calls on its own objects really exists, and a
blocklist of MQL5 calls that do not exist. After the owner's first MetaEditor
compile on 14 Oct 2026 (17 errors, 4 wrong names) it also checks: every
ALL-CAPS name used is either ours (`#define`, enum, glyph) or a verified MQL5
constant, the property argument of each built-in accessor belongs to that
accessor's own enum, and every `TRADE_RETCODE_*` used is a real trade server
retcode. `tools/score_sim.py` — re-states the
decision and money arithmetic and asserts: the four weight sets sum to 1.00,
random noise never reaches the threshold (HOLD is the default state), all 15
regime/direction gate combinations behave as designed, risk-sized lots never
exceed the dial by more than the small-account allowance, the 50/30/20 ladder
always closes exactly the opening volume after volume-step rounding, and the
owner's Win/Loss/BE rule reproduces the four cases in section 1.
`tools/volume_profile_sim.py` — re-states the session volume-profile walk of
`VolumeFlow.mqh` (from the POC, grow outward until 70% of the volume) and runs
it over 20,000 synthetic sessions plus the spike shapes that used to kill it.
It exists because of the first runtime report (decision #19): it reproduces the
old `dn++` walk leaving the bin array (13% of ordinary sessions, 40% of
spike-shaped ones) and asserts the patched walk never forms an out-of-range
index, never counts a bin twice, always keeps VAL ≤ POC ≤ VAH and always
reaches 70% of the volume.
All three are development checks only — they are **not** part of the EA and are never
copied into MT5 (only the `MQL5/` folder is).

---

## 6C. Phase 7 — validation (decided 14 Oct 2026, BUILT in MQL5)

**Owner's decisions:** Phase 7 covers all the validation in one phase, with no add-ons
later. Pure MQL5 only, no Python in the test path. Trailing stop (Phase 8) and
fine-tuning (Phase 9) come later. Phase 7 judges the EA **exactly as built**: nothing
is tuned in Phase 7, so the zero-inputs rule (decision 17) holds and the EA itself
gets no test code.

### 6C.1 What was built

| File | What it does |
|------|--------------|
| `MQL5/Include/Autotrader/Validation.mqh` | the statistics only: normal distribution, Wilson win-rate bound, Deflated Sharpe, drawdown, reshuffle drawdown range, PBO. Used by the scripts, never by the EA |
| `MQL5/Scripts/Autotrader/Phase7_Report.mq5` | reads the logs, runs gates G1–G9, writes `MQL5\Files\Phase7_Report.txt` and prints PASS/FAIL per gate |
| `MQL5/Scripts/Autotrader/Phase7_Permutation.mq5` | builds shuffled copies of a symbol as custom symbols for gate G7 |
| `StatsKeeper.mqh` (small change) | writes one `TRADE` line per finished trade to `Autotrader_log.csv` (result, net, open time, minutes open, lots). Also: a trade that still has an open position no longer counts as Win/Loss/BE until it is fully closed |

The EA's trading logic was **not** changed by Phase 7.

### 6C.2 How the owner runs it

1. **Real runs (12):** Strategy Tester, real ticks, about 2 years, one run per class
   and timeframe: FOREX, GOLD, CRYPTO, INDEX × M5, M15, M30. After each run, copy the
   tester's `Autotrader_log.csv` into `MQL5\Files` as `Phase7_<CLASS>_<TF>.csv`.
2. **Permutation (G7):** run `Phase7_Permutation` once per class (SourceSymbol = a
   symbol of that class, ClassName = the class, Shuffles = 20). Then run the EA on
   **M15** with each `AT_<CLASS>_k` (k = 0..20) in the **same** tester model for all
   of them. Save each log as `Phase7_PERM_<CLASS>_M15_<k>.csv`. That is 21 runs per
   class, 84 in total.
3. **Demo (G9):** 4 to 8 weeks on a demo account. Copy the log as `Phase7_DEMO.csv`.
4. Run `Phase7_Report`. Read `Phase7_Report.txt`.

### 6C.3 Pass rules (gates)

| Gate | Rule |
|------|------|
| G1 Sample | at least 200 closed trades out-of-sample (last 30% of the period) |
| G2 Win rate | Win ÷ (Win + Loss), BE excluded: point **≥ 98%** and Wilson 95% lower bound **≥ 95%** |
| G3 No degradation | in-sample win rate minus out-of-sample win rate **≤ 3 points** |
| G4 Window pairs | the period is cut into 6 windows; every pair of windows (15 combinations) is tested; the worst pair's Wilson lower bound must be **≥ 90%** |
| G5 Deflated Sharpe | probability the per-trade Sharpe is real, after correcting for the 12 runs tried: **≥ 95%** |
| G6 PBO | Probability of Backtest Overfitting over the 12 runs (8 time blocks, all 70 half-splits): **< 25%** |
| G7 Permutation | per class (M15): p-value from 20 shuffles against the unshuffled base: **p < 0.05** |
| G8 Drawdown | 95th percentile drawdown after 1000 reshuffles of the trade order ≤ **15% of balance** |
| G9 Demo | at least 60 demo trades, win rate ≥ 98%, lower bound ≥ 95% |

**Overall PASS** only if G1–G9 all pass. Any fail → the EA stays on demo, the next
step is Phase 9 fine-tuning, and Phase 7 is run again on fresh data. Data used in a
failed run is not reused as a pass.

**Important correction to the 98% rule:** with 200 trades, 3 losses (98.5%) gives a lower
bound of 95.7% and passes; 4 losses (98.0%) gives 94.97% and fails. So G2 means
**at most 3 losses in 200 closed trades**.

### 6C.4 Notes

- **Purge and embargo** (CPCV's leakage guard) are not needed here: Phase 7 fits
  nothing, so no training data can leak into testing. G4 gives the combination check.
- **PBO** uses the 12 runs (class × timeframe) as the trials, not parameter sets,
  because nothing is tuned. The multiple-testing burden is counted by G5.
- The **permutation** copies are built from M5 bars. Compare them only with the
  unshuffled base (k = 0) run in the same tester model. Real-tick runs are not
  comparable with them.
- The 98% motto is very demanding. If the EA rarely trades, the trade count shows it;
  the gates do not hide it.
- **Not verified here:** the MQL5 code has not been compiled (no MetaEditor in this
  workspace). The lint tool and a separate check of the statistics formulas passed. The
  first real compile (F7) and the first test run are the owner's.

---

## 7. One-line summary

> **14 Oct 2026: everything in the sentence below is built except the proving
> (Phase 7). Until then it trades on a demo account.**

> A **pure MQL5, input-free, self-calibrating EA** for any symbol on M5/M15/M30
> charts: 2026-modern signal science inside a regime-aware confluence judge that
> says **HOLD most of the time**, calls BUY/SELL only at high confidence, manages
> every trade via a **60/80/100 TP ladder with break-even**, shows everything on a
> **draggable, self-sizing two-panel interface** (SIGNAL view + LIVE TRADING view),
> and **proves** the 98% on its own Win/Loss/BE scoreboard before real money.
