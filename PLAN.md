# AUTOTRADER — Master Build Plan v3 (pure MQL5)

> Status: Phase 1 (interface) built 12 Oct 2026; Phase 2 (Symbol Intelligence
> + Regime engine) built 13 Oct 2026, including the owner's expanded,
> specific Regime labels and the soft eye-friendly interface style.
> Next step: Phase 3 — direction engine.

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
| Trail Stop | `OFF (phase 2)` now; later: `ACTIVE — trailing @ price` |
| TP1/TP2/TP3 | ladder price + % of D, live status: `✓ HIT time — closed N%` / `pending — NN% progress` / `skipped (manual)` |
| STATUS | what the manager is doing: running to TP1 / moved SL to Entry / closed for time / closing… |

Note: the MAIN panel's "Stop Loss" row = the **planned** SL of the current signal.
The LIVE panel's "Stop Loss" row = the **live** SL of the open order (it changes:
initial → Entry → trailing). Both are always on screen.

This is where the owner's TP-ladder idea becomes visible and auditable in real time.

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
(M30 bias → M15 setup → M5 trigger). The chart's TF decides which
**direction product** the panel reports:

| Chart TF | Direction product | Style |
|----------|-------------------|-------|
| M5  | trade trigger & entry timing | scalping |
| M15 | short-term setup direction | short-term |
| M30 | intraday bias direction | intraday |

**Open to owner — the A/B question explained visually:**

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

### A. Symbol Intelligence (auto-configuration engine)
On attach to any chart, and continuously afterwards:
- class detection: forex / metals / crypto / indices / energy (your ETHUSDm = crypto),
- micro-structure: digits, point, tick size/value, contract size, margin rules,
- rolling behavior profile: typical spread, tick activity by hour, ATR% per TF,
  gap behavior, average swing size, noise level,
- derives ALL parameters automatically: SL/TP multipliers, TP-ladder distances,
  trailing speed, break-even trigger, confidence threshold, lot sizing,
- keeps re-calibrating as conditions change (owner motto: adapt to the symbol).

### B. Regime Engine ("Regime:" row)
TRENDING / RANGING / VOLATILE / QUIET via efficiency ratio + adaptive decycler
(Ehlers cycle/trend separation), ATR percentile, structure persistence.
Behavior switches: TRENDING → pullback continuation; RANGING → mean reversion
at envelope extremes; VOLATILE/QUIET → mostly HOLD (protects the 98%).

### C. Modern Indicator Layer (2026 stack — researched Oct 2026)
1. **Nadaraya–Watson kernel regression (Gaussian), non-repainting variant** —
   trend baseline, dynamic zones, and realistic TP references (adaptive bandwidth).
2. **Ehlers DSP filters** — Gaussian/Super Smoother, Decycler Oscillator,
   Adaptive Laguerre, Laguerre RSI (near-zero-lag triggers, replace slow MACD-style logic).
3. **Kalman filter** trend line — clean "true price" for structure breaks.
4. **Regime-weighted confluence oscillator (0–100)** — each evidence source
   weighted by the current regime; feeds the Confidence % row.
5. **Smart-Money Concepts engine** — BOS/CHoCH, order blocks, fair value gaps,
   liquidity sweeps. Still the backbone of pro entries in 2026.
6. **Volume-flow tools** — tick-volume delta (CVD-style), session volume profile,
   anchored VWAP (MT5 tick volume is sufficient as confluence).
7. **Classics that still earn their place:** ATR (SL/TP sizing), EMA200 (baseline),
   spread monitor. Nothing else old without a reason.

### D. Direction & Confidence Engine (the heart of the 98%)
Evidence checklist with regime-adjusted weights (0–100):
M30 bias, M15 structure, M5 trigger, zone quality (OB/FVG/liquidity),
momentum (modern oscillators), volume agreement, volatility fitness, quote quality.
- Score ≥ threshold (auto per symbol class, ~85–90) → BUY/SELL.
- Below → HOLD (the default state). M5/M15 never fight M30.

### E. Trade Management Engine (feeds the LIVE TRADING panel)
- Entry: limit at zone edge or confirmation close.
- SL: structural level + ATR buffer; if price is in "open space" (e.g. near
  all-time high) → volatility SL (ATR-based); if even that is absurd → no trade.
  **Hard broker-side SL on every order. Never trade without it.**
- TP ladder: TP1 60% / TP2 80% / TP3 100%, partial close 50/30/20,
  SL → Entry after TP1 (break-even), trailing after TP2 (phase 2).
- Time exit if trade stalls beyond Expected Duration.
- State survives restart / reconnection (position state restored, panel redraws).

### F. Risk & Safety Manager
Risk % per trade (auto, ~1% baseline), auto lot size, max daily loss stand-down
(account protection — not session blocking), news shock freeze (MQL5 calendar),
spread explosion guard, weekend gap guard, slippage limits, magic numbers,
equity floor. STATUS line reports any safety condition in plain words.

### G. Execution & Feedback
Fully automatic order sending (slippage-aware, retry logic), every signal logged
to CSV (signal, score, prices, outcome) → feeds Today / All Time counters and
lets us audit the 98% at any time.

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
| 3 | Direction engine (M30→M15→M5) + Confidence % | BUY/SELL/HOLD live |
| 4 | Trade engine: entry rules + SL logic + TP ladder + break-even + management (LIVE panel goes live-live) | owner's TP idea |
| 5 | Safety layer: news, spread, daily loss, restart-restore | |
| 6 | Auto-execution + Win/Loss/BE logging + counters | fully automatic at last |
| 7 | Tester + demo validation, threshold tuning toward 98% | prove it |
| 8 | Trailing stop (owner: later) | after core is proven |

Each phase ends with a demo to the owner.

---

## 7. One-line summary

> A **pure MQL5, input-free, self-calibrating EA** for any symbol on M5/M15/M30
> charts: 2026-modern signal science inside a regime-aware confluence judge that
> says **HOLD most of the time**, calls BUY/SELL only at high confidence, manages
> every trade via a **60/80/100 TP ladder with break-even**, shows everything on a
> **draggable, self-sizing two-panel interface** (SIGNAL view + LIVE TRADING view),
> and **proves** the 98% on its own Win/Loss/BE scoreboard before real money.
