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
  * BUY and SELL are scored side-by-side; bias tiers stay separate from the
    execution threshold and are explicitly not probabilities
  * NW slope only rewards the direction it actually supports
  * pending-order freshness windows and full trade-cost aggregation
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

# ---------------- two-sided evidence, display tiers, and execution split
print("\ntwo-sided bias selection and independent trade threshold:")


def evidence_tier(value):
    if value >= 85:
        return "very strong"
    if value >= 70:
        return "strong"
    if value >= 55:
        return "moderate"
    if value >= 40:
        return "developing"
    return "weak"


def select_bias(buy_score, sell_score, vote, margin=5):
    gap = buy_score - sell_score
    bias = 1 if gap >= margin else (-1 if gap <= -margin else 0)
    vote_candidate = 1 if vote >= 3 else (-1 if vote <= -3 else 0)
    candidate = bias if bias else vote_candidate
    return bias, candidate, gap


BIAS_CASES = [
    (62, 47, 0, 1, 1, 15, "BUY evidence leads; still below execution threshold"),
    (44, 52, 4, -1, -1, -8, "two-sided evidence overrides the raw BUY vote"),
    (65, 62, 3, 0, 1, 3, "close scores display mixed; old vote is fallback"),
    (51, 54, 0, 0, 0, -3, "balanced/weak evidence remains mixed"),
]
for buy, sell, vote, want_bias, want_candidate, want_gap, why in BIAS_CASES:
    bias, cand, gap = select_bias(buy, sell, vote)
    ok = (bias, cand, gap) == (want_bias, want_candidate, want_gap)
    qualified = max(buy, sell) >= 85
    print(f"  BUY {buy:2d} / SELL {sell:2d}, vote {vote:+d} -> "
          f"bias {bias:+d}, candidate {cand:+d}, gap {gap:+d}, "
          f"trade-threshold-qualified={qualified} ({why}) {'ok' if ok else 'WRONG'}")
    if not ok:
        fails.append(f"two-sided bias selection for BUY {buy} / SELL {sell}")
    if (buy, sell) == (62, 47) and qualified:
        fails.append("display bias incorrectly cleared the execution threshold")

# Directional slope magnitude must never boost the opposing side.
def slope_credit(slope, side):
    return 0.30 * min(1.0, abs(slope) / 0.15) if slope * side > 0 else 0.0

buy_credit = slope_credit(0.12, 1)
sell_credit = slope_credit(0.12, -1)
print(f"  positive NW slope credit -> BUY {buy_credit:.2f}, SELL {sell_credit:.2f} "
      f"{'ok' if buy_credit > sell_credit else 'WRONG'}")
if not buy_credit > sell_credit:
    fails.append("NW slope rewarded both directional sides equally")

# --------------------- pending entry freshness (three lane bars)
print("\npending-order maximum age:")


def pending_lifetime(lane_seconds, expected_seconds):
    ttl = lane_seconds * 3 if lane_seconds > 0 else 600
    if expected_seconds > 0 and expected_seconds < ttl:
        ttl = expected_seconds
    return max(600, ttl)


PENDING_CASES = [
    (300, 7200, 900),    # M5: three bars
    (900, 960, 960),     # M15: shorter expected duration
    (1800, 2000, 2000),  # M30: bounded by expected duration
    (300, 300, 600),     # never shorter than the 10-minute safety floor
]
for lane, expected, want in PENDING_CASES:
    got = pending_lifetime(lane, expected)
    ok = got == want
    print(f"  lane {lane:4d}s expected {expected:4d}s -> TTL {got:4d}s "
          f"(expected {want}) {'ok' if ok else 'WRONG'}")
    if not ok:
        fails.append(f"pending TTL lane={lane} expected={expected}: got {got}, want {want}")

# -------------------- all-in trade outcome costs
print("\ntrade result includes all deal-side costs:")

def net_from_components(deals):
    gross = sum(d["profit"] for d in deals)
    swap = sum(d["swap"] for d in deals)
    commission = sum(d["commission"] for d in deals)
    fee = sum(d["fee"] for d in deals)
    return gross, swap, commission, fee, gross + swap + commission + fee


cost_deals = [
    {"profit": 0.0, "swap": 0.0, "commission": -1.25, "fee": -0.10},  # entry
    {"profit": 10.0, "swap": -0.20, "commission": -0.75, "fee": -0.05},
]
gross, swap, commission, fee, net = net_from_components(cost_deals)
print(f"  gross {gross:+.2f} swap {swap:+.2f} commission {commission:+.2f} "
      f"fee {fee:+.2f} -> net {net:+.2f} ({result(net)})")
if abs(net - 7.65) > 1e-9 or result(net) != "Win":
    fails.append("opening/closing commissions or deal fees were omitted from net")

print("\n" + ("ALL CHECKS PASSED" if not fails else f"FAILURES: {fails}"))
raise SystemExit(1 if fails else 0)
