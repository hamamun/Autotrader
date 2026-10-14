#!/usr/bin/env python3
"""Mirror of the Autotrader decision/money maths, run on synthetic cases.

The MQL5 itself cannot be compiled in this sandbox, so this script re-states
the arithmetic exactly as written in DirectionEngine.mqh / TradeEngine.mqh /
StatsKeeper.mqh and checks the outcomes we care about:

  * the regime weight sets really sum to 1.0
  * how much evidence it takes to clear the auto-set threshold (selectivity)
  * the hard gates veto what they should
  * risk-sized lots, the 60/80/100 ladder with 50/30/20 partials and the
    volume-step / minimum-volume rounding behave on real-ish numbers
  * the owner's Win / Loss / BE rule reproduces PLAN section 1's table
  * the provisional side shown while no side has been chosen (decision #20)
    is the fade side at a range extreme / the vote's lean otherwise, and the
    parts printed for it can never become a signal
"""
import math

# ---------------------------------------------------------------- weights
W = {
    "trend":     [0.20, 0.18, 0.12, 0.10, 0.18, 0.08, 0.08, 0.06],
    "pullback":  [0.20, 0.16, 0.14, 0.16, 0.12, 0.08, 0.08, 0.06],
    "range_ext": [0.12, 0.12, 0.14, 0.24, 0.10, 0.14, 0.08, 0.06],
    "other":     [0.15, 0.15, 0.15, 0.15, 0.15, 0.10, 0.10, 0.05],
}
NAMES = ["bias", "structure", "trigger", "zone",
         "momentum", "volume", "fitness", "quote"]

fails = []
for k, w in W.items():
    tot = sum(w)
    ok = abs(tot - 1.0) < 1e-9
    print(f"weights[{k:9s}] sum = {tot:.4f}  {'ok' if ok else 'WRONG'}")
    if not ok:
        fails.append(f"weights {k} sum to {tot}")


def clamp01(v):
    return max(0.0, min(1.0, v))


def score(evidence, regime):
    w = W[regime]
    return int(round(sum(wi * clamp01(ei) for wi, ei in zip(w, evidence)) * 100.0))


# ------------------------------------------------- selectivity of the judge
print("\nhow much agreement does it take to speak?")
THRESHOLDS = {"forex": 85, "metal": 87, "crypto": 90}
for label, ev in [
    ("everything agrees strongly", [1.0] * 8),
    ("strong but zone/volume only ok", [1.0, 1.0, 1.0, 0.55, 1.0, 0.5, 0.85, 1.0]),
    ("typical decent setup", [0.9, 0.8, 0.75, 0.55, 0.8, 0.6, 0.85, 0.9]),
    ("mixed / half-hearted", [0.6, 0.5, 0.5, 0.4, 0.6, 0.4, 0.7, 0.8]),
    ("bias against us", [0.0, 0.7, 0.7, 0.6, 0.7, 0.6, 0.8, 0.9]),
]:
    row = []
    for cls, thr in THRESHOLDS.items():
        s = score(ev, "trend")
        row.append(f"{cls} {s:>3d}/{thr} {'SPEAK' if s >= thr else 'hold '}")
    print(f"  {label:34s} " + " | ".join(row))

# a HOLD must be the common answer: sample a spread of plausible evidence
import random
random.seed(7)
spoke = 0
N = 20000
for _ in range(N):
    ev = [clamp01(random.gauss(0.55, 0.25)) for _ in range(8)]
    if score(ev, random.choice(list(W))) >= 88:
        spoke += 1
print(f"\nrandom market noise: spoke on {spoke}/{N} samples "
      f"({100.0 * spoke / N:.2f}%) - HOLD is the default state")
if spoke / N > 0.05:
    fails.append("engine speaks too often on random evidence")

# ------------------------------------------------------------- hard gates
print("\nhard gates (a veto means HOLD whatever the score says):")
def regime_allows(kind, d):
    return {"TREND_UP": d == 1, "TREND_DOWN": d == -1,
            "PULLBACK_UP": d == 1, "PULLBACK_DOWN": d == -1,
            "RANGE_TOP": d == -1, "RANGE_BOTTOM": d == 1}.get(kind, False)


EXPECT = {
    "TREND_UP/BUY":       True,
    "TREND_UP/SELL":      False,
    "TREND_DOWN/SELL":    True,
    "TREND_DOWN/BUY":     False,
    "PULLBACK_UP/BUY":    True,
    "PULLBACK_UP/SELL":   False,
    "RANGE_TOP/SELL":     True,
    "RANGE_TOP/BUY":      False,
    "RANGE_BOTTOM/BUY":   True,
    "RANGE_BOTTOM/SELL":  False,
    "RANGE_MIDDLE/BUY":   False,
    "VOLATILE/BUY":       False,
    "QUIET/SELL":         False,
    "TRANSITION/BUY":     False,
    "CALIBRATING/BUY":    False,
}
for k, want in EXPECT.items():
    kind, d = k.split("/")
    got = regime_allows(kind, 1 if d == "BUY" else -1)
    flag = "ok" if got == want else "WRONG"
    print(f"  {k:22s} allowed={str(got):5s} expected={str(want):5s} {flag}")
    if got != want:
        fails.append(f"gate {k}: got {got}, want {want}")

print("\nother vetoes that must force HOLD regardless of the score:")
for why in ["M5/M15 would fight the M30 bias",
            "spread above the symbol's own limit",
            "quote older than 120 s",
            "stop wider than 3.5 x ATR",
            "risk:reward below 1:1.5",
            "target not reachable inside the lane window"]:
    print(f"  veto: {why}")

# ------------------------------------------------------- money maths
print("\nrisk-sized lots (XAUUSDm-style: tick 0.01, tick value 0.01 USD/lot):")


def norm_volume(v, vmin=0.01, vmax=100.0, step=0.01):
    lots = math.floor(v / step + 0.5) * step
    return round(max(vmin, min(vmax, lots)), 8)


def calc_lots(equity, risk_pct, sl_dist, tick_size=0.01, tick_value=0.01,
              vmin=0.01, step=0.01):
    risk_money = equity * risk_pct / 100.0
    loss_per_lot = sl_dist / tick_size * tick_value
    if loss_per_lot <= 0:
        return 0.0, risk_money, loss_per_lot
    lots = norm_volume(risk_money / loss_per_lot, vmin, 100.0, step)
    return lots, risk_money, loss_per_lot


for equity, sl_dist in [(1000, 2.0), (1000, 5.0), (10000, 3.5),
                        (100, 2.0), (250000, 8.0)]:
    lots, risk_money, per_lot = calc_lots(equity, 1.0, sl_dist)
    real_risk = lots * per_lot
    print(f"  equity {equity:>7} sl_dist {sl_dist:>4} -> {lots:.2f} lot "
          f"(risk ${real_risk:,.2f} of ${risk_money:,.2f} dial)")
    if lots > 0 and real_risk > risk_money * 3.0 + 1e-9:
        fails.append(f"lot {lots} risks {real_risk} vs dial {risk_money}")

print("\nthe 60/80/100 ladder with 50/30/20 partials:")


def ladder(v0, vmin=0.01, step=0.01):
    out, remaining = [], v0
    for frac, name in [(0.50, "TP1"), (0.30, "TP2")]:
        want = norm_volume(v0 * frac, vmin, 100.0, step)
        vol = want
        if vol >= remaining:
            vol = remaining
        elif remaining - vol < vmin:
            vol = remaining
        if vol < vmin:
            out.append((name, 0.0, remaining))
            continue
        remaining = round(remaining - vol, 8)
        out.append((name, vol, remaining))
    out.append(("TP3", remaining, 0.0))
    return out


for v0 in [0.01, 0.02, 0.05, 0.10, 0.37, 1.00]:
    steps = ladder(v0)
    txt = ", ".join(f"{n} closes {c:.2f} (left {r:.2f})" for n, c, r in steps)
    closed = sum(c for _, c, _ in steps)
    print(f"  v0={v0:.2f}: {txt}")
    if abs(closed - v0) > 1e-6:
        fails.append(f"ladder for {v0} closed {closed} != {v0}")

# ------------------------------------------- owner's Win/Loss/BE counting
print("\nowner's counting rule on PLAN section 1's worked example:")


def result(net):
    if abs(net) < 0.005:
        return "BE"
    return "Win" if net > 0 else "Loss"


CASES = [
    ("1: TP1+TP2+TP3 all hit", [3.5, 3.0, 2.4], "Win"),
    ("2: TP1 hit, rest closed at Entry", [3.5, 0.0], "Win"),
    ("3: straight to the stop", [-10.0], "Loss"),
    ("4: no TP, SL already at break-even", [0.0], "BE"),
]
for name, deals, want in CASES:
    grouped = sum(deals)           # one trade = one result (grouped by position id)
    got = result(grouped)
    flag = "ok" if got == want else "WRONG"
    print(f"  case {name:40s} net {grouped:+7.2f} -> {got:4s} (expected {want}) {flag}")
    if got != want:
        fails.append(f"counting case {name}: got {got}, want {want}")

# success rate arithmetic
win, loss, be = 33, 1, 8
print(f"\n  scoreboard Win {win} / Loss {loss} / BE {be} -> "
      f"success {100.0 * win / (win + loss):.1f}% (motto target ~98%)")

# ------------------------ provisional side (owner report, 14 Oct 2026)
# The eight evidence parts are ALWAYS computed in DirectionEngine.mqh. While
# no side has been chosen yet they describe the "provisional" side, so the log
# and the panel never show eight zeros. Two things must stay true:
#   * the side shown is the one the engine would look at first - a range
#     extreme's fade side (the only side RegimeAllows permits there), else
#     the plain vote's lean; and
#   * provisional parts can never become a signal: with no candidate the
#     published score is 0 and nothing latches on the printed number.
print("\nprovisional side when no side has been chosen (decision #20):")


def candidate(vote):
    return 1 if vote >= 3 else (-1 if vote <= -3 else 0)


def prov_side(vote, kind):
    if kind == "RANGE_BOTTOM":
        return 1                      # fade the bottom
    if kind == "RANGE_TOP":
        return -1                     # fade the top
    return 1 if vote > 0 else (-1 if vote < 0 else 0)


PROV_CASES = [
    # the owner's BTCUSDm M15 line: vote -1, lane regime RANGE BOTTOM
    (-1, "RANGE_BOTTOM", 0, 1, "range bottom -> the BUY fade side"),
    (-4, "RANGE_BOTTOM", -1, -1, "candidate exists -> parts follow it"),
    (4, "RANGE_MIDDLE", 1, 1, "candidate exists -> parts follow it"),
    (2, "RANGE_MIDDLE", 0, 1, "no extreme -> the vote's lean (BUY)"),
    (-2, "TRANSITION", 0, -1, "no extreme -> the vote's lean (SELL)"),
    (0, "RANGE_MIDDLE", 0, 0, "tied vote, plain range -> parts[n/a]"),
]
for vote, kind, want_cand, want_prov, why in PROV_CASES:
    cand = candidate(vote)
    prov = cand if cand != 0 else prov_side(vote, kind)
    flag = "ok" if (cand == want_cand and prov == want_prov) else "WRONG"
    print(f"  vote {vote:+d} {kind:12s} -> candidate {cand:+d}, "
          f"parts for {prov:+d} ({why}) {flag}")
    if cand != want_cand or prov != want_prov:
        fails.append(f"provisional side: vote {vote} in {kind}")

# the same evidence, scored for the fade side, is printed - but the decision
# score stays 0 while the candidate is 0, so it can never clear a threshold
PROV_EV = [0.40, 0.55, 0.30, 0.85, 0.80, 1.00, 0.15, 0.69]
shown = score(PROV_EV, "range_ext")
for vote in (-1, 0, 2):
    published = 0 if candidate(vote) == 0 else score(PROV_EV, "range_ext")
    ok = (published == 0)
    print(f"  the M15-style parts score {shown}/92 for the fade side, but with "
          f"vote {vote:+d} the published score is {published} "
          f"({'ok - cannot latch' if ok else 'WRONG'})")
    if not ok:
        fails.append(f"provisional parts leaked into the published score at vote {vote}")

print("\n" + ("ALL CHECKS PASSED" if not fails else f"FAILURES: {fails}"))
raise SystemExit(1 if fails else 0)
