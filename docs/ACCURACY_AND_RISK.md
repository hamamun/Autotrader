# The 98% question — answered with arithmetic

Your motto: *98% correct direction, with 98% achievable TP and entry.*
Here is the honest engineering answer, because a robot built on an
impossible target is a robot that will be "tuned" until it blows up.

## 1. Three different numbers hide inside "98%"

| claim | what it really means | what is achievable |
|---|---|---|
| **98% direction** | of the signals we take, how often the market moved the way we said | **53–60%** on 5-minute gold/EURUSD with a real edge. 98% does not exist. |
| **98% TP hit** | the trade reached take profit before stop loss | depends entirely on where TP sits — see §2. 98% is possible *only* with a target so small that costs eat it. |
| **98% entry quality** | the fill is at (or better than) the planned price | **this one is realistic**: with a spread filter, a limit-order option and a broker with decent execution, 90–99% of fills land inside the planned slippage. |

The third one is the one worth engineering. The first two are marketing.

## 2. Why "98% of TP" is a choice, not a skill

Two useful bits of arithmetic. First, expectancy in R (multiples of the
risk you accept):

```
E[R] = p × RR − (1 − p) − c          p = win rate, RR = reward:risk, c = cost in R
break-even win rate:  p* = (1 + c) / (1 + RR)
```

Second, the barrier probability. In a market with no drift — which is a
fair approximation of any 5-minute window — price reaches the *nearer*
barrier first with probability equal to the distance ratio:

```
P(TP first) = sl_distance / (tp_distance + sl_distance)
```

So with a stop at 1R, a target at xR is reached first with probability
`1 / (1 + x)`. Look at what that means:

| target | P(TP first) by pure geometry | expectancy before costs |
|---|---|---|
| TP = 3.0R | 25% | 0.00 R |
| TP = 1.5R | 40% | 0.00 R |
| TP = 1.0R | 50% | 0.00 R |
| TP = 0.25R | 80% | 0.00 R |
| TP = **0.02R** | **98%** | 0.00 R |

Every row is exactly zero before costs. **TP hit rate is not a skill you
engineer — it is a knob you turn, and turning it up does not move
expectancy.** To reach a 98% TP rate with a 1R stop, the target must sit at
1/49 of the stop distance (about 0.02R — on XAUUSD with a 1.5×ATR stop,
that is a handful of cents, well inside the spread).

Then subtract the cost `c` from every row, and the high-win-rate end of the
table becomes the *worst* end, because cost is a fixed fraction of R while
the profit per trade shrinks toward zero. Add slippage on the rare stop-out
and it is worse still.

**Conclusion:** 98% TP-hit is not a setting we are failing to find. It is
the zero-expectancy corner of the payoff space, and after spread it is a
losing one. Your edge lives in the **departure from those base rates**:
40% at 1.5R is break-even-ish; 46% at 1.5R is a business.

## 3. Why 98% direction is not available either

A 5-minute bar on a liquid market is, to a very good approximation, mostly
noise. The barrier structure of a 1.5R/1R trade has a built-in base rate:
under a coin-flip market the target is reached first about **40%** of the
time. Every honest model fights for the few points above that:

* 40–50% → no skill, or the model is overfitted
* 52–56% → a real, tradable edge (this is a *good* quant result)
* 58–62% → excellent, usually fragile, usually market-regime specific
* >70% on a *traded* signal set → look for a bug, lookahead, or a
  backtest that ignores spread

A model that could pick direction correctly 98% of the time would, by the
same information, predict the next bar's close — the market would stop
existing in a week.

**The good news:** direction accuracy is not what pays you. Expectancy is.
At 1.5R a 45% win rate is profitable (42% break-even). At 3R you only need
27%. Great systems win *less* often than bad ones; they just lose small.

## 4. So what is the motto we actually build to?

> **Every trade has a reason, a written risk, and a measured result.**
> **Direction hit rate is not claimed — it is logged, per timeframe, per
> symbol, and shown on the panel.**

Concretely, the targets this repo is engineered against:

| metric | target | where it is measured |
|---|---|---|
| plan compliance | ≥ 99% of trades have SL + TP set before entry, risk ≤ configured % | EA checklist + journal |
| signal hit rate (TP1 before SL) | ≥ 45% at RR 1.5 (≥ 42% break-even) | journal stats line + `models/report.json` |
| directional accuracy on taken trades | 53–60% | walk-forward + holdout backtest |
| no-trade discipline | 0 trades when spread/session/news/HTF gates fail | 10-point checklist |
| signal logging coverage | 100% of displayed signals written and scored | `autotrader_journal.csv` |
| live vs backtest drift | live hit rate within ±8 points of backtest on 200+ trades | journal vs report |

## 5. How we get the extra edge (the honest levers)

1. **Regime filter first, model second.** ADX + session filters remove a
   large slice of unprofitable chop. In this repo that is the `ADX min`,
   session window and M30 bias veto.
2. **Cost discipline.** A tight-spread symbol and a spread gate are worth
   more than another indicator. Test the EA on two brokers — the journal
   will show the difference immediately.
3. **Multi-timeframe agreement.** M30 bias + M15 setup + M5 trigger is the
   difference between "indicator soup" and a decision. It is why the EA
   also *vetoes* M5 when it fights M30.
4. **Trade fewer, better setups.** The `minimum model probability` gate and
   the checklist exist so the EA is allowed to say *no* 80% of the time.
   Traders lose money by taking the 81st-best setup at 3 a.m.
5. **Partial exits.** Want the psychological comfort of a high win rate?
   Take 50% off at 0.8–1R, trail the rest. Your win rate rises to 60–70%
   legitimately, because you changed the payoff, not the truth.
6. **Sample size discipline.** 200 trades minimum before judging. That is
   why every signal is journalled from day one, in signal-only mode, before
   a single real order is sent.

## 6. The go-live protocol (do not skip)

1. **Week 0–1 — parity.** Export features from MT5, run
   `python -m autotrader.cli parity ...`. Fix until it passes. A model
   trained on different numbers than the EA computes is a random number
   generator with good manners.
2. **Week 1–2 — research.** Train on 2+ years of M5 (ideally 5). Read
   `models/report.json`. If out-of-fold and holdout directional accuracy are
   not above 52%, change features/labels/symbol — do **not** touch the live
   EA.
3. **Week 2–6 — signal only.** Attach the EA to the chart, leave the mode on
   SIGNAL ONLY, let the journal run. After 200+ signals compare the measured
   hit rate with the backtest.
4. **Week 6+ — micro live.** AUTO mode with risk 0.1–0.25% per trade. Then
   scale. Never scale before the journal confirms the backtest.

## 7. What we will never do here

* Report accuracy that includes HOLD predictions (inflates it ~10 points).
* Optimise parameters on the test set.
* Use a random train/test split on time series.
* Hide spread and commission in the backtest.
* Show a hit rate on the panel that was not measured on real bars.
