#!/usr/bin/env python3
"""Focused synthetic checks for the adaptive MQL5 trailing-stop policy.

This mirrors the policy arithmetic in TradeEngine.mqh and checks its integration
points. It does not execute or compile MQL5, model broker fills, or establish
profitability; native MetaEditor and MT5 testing are still required.
"""
from pathlib import Path
import math
import random
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE_PATH = ROOT / "MQL5/Include/Autotrader/TradeEngine.mqh"
EXPERT_PATH = ROOT / "MQL5/Experts/Autotrader/Autotrader.mq5"


def arm_threshold(lane, weak=False, transition=False, range_middle=False,
                  volatile=False, efficiency=0.5, sign_changes=0,
                  aligned=False, directional=False, own_score=0,
                  score_delta=0):
    arm = 0.45 if lane <= 5 else (0.65 if lane <= 15 else 0.85)
    strengthening = (aligned and directional and own_score >= 70 and
                     score_delta >= 0 and not weak)
    if weak:
        arm -= 0.12
    if transition or range_middle:
        arm -= 0.05
    if volatile and (efficiency < 0.45 or sign_changes >= 4):
        arm -= 0.05
    if strengthening:
        arm += 0.08
    return max(0.30, min(1.10, arm))


def trail_distance(lane, atr, atr_ratio, efficiency, sign_changes,
                   trend=False, pullback=False, volatile=False, quiet=False,
                   range_middle=False, aligned=False, own_score=0,
                   weak=False, score_delta=0, point=0.01):
    if atr <= 0:
        return 0.0
    base = 0.65 if lane <= 5 else (0.85 if lane <= 15 else 1.05)
    directional = (trend or pullback) and efficiency >= 0.35
    strengthening = (aligned and directional and own_score >= 70 and
                     score_delta >= 0 and not weak)
    choppy = range_middle or efficiency < 0.25 or sign_changes >= 6
    chaotic = volatile or (atr_ratio >= 1.50 and
                           (efficiency < 0.45 or sign_changes >= 4))
    atr_for_gap = atr
    if chaotic and atr_ratio > 1.0:
        normal_atr = atr / atr_ratio
        atr_for_gap = max(atr * 0.65, normal_atr * 0.85)
    factor = 1.0
    if strengthening:
        factor *= 1.20
    elif directional:
        factor *= 1.05
    if choppy:
        factor *= 0.88
    if weak:
        factor *= 0.70
    if quiet:
        factor *= 0.85
    if volatile and not strengthening:
        factor *= 0.92
    factor = max(0.55, min(1.35, factor))
    return max(point * 3.0, atr_for_gap * base * factor)


def norm_stop(price, direction, tick_size):
    """Round a BUY stop up / SELL stop down so the cost floor is not lost."""
    units = price / tick_size
    aligned = (math.ceil(units - 1e-10) if direction == 1 else
               math.floor(units + 1e-10))
    return round(aligned * tick_size, 8)


def cost_floor(entry, direction, spread, commission_price, negative_swap_price,
               point, tick_size=None):
    """Return entry +/- a conservative modeled cost buffer."""
    buffer = max(point * 2.0, spread) + commission_price + negative_swap_price
    step = tick_size or point
    return norm_stop(entry + direction * buffer, direction, step)


def safe_candidate(direction, best, gap, floor, bid, ask, min_distance):
    """Mirror the MQL5 trailing clamp; None means no broker-safe space yet."""
    if direction == 1:
        if bid - min_distance < floor:
            return None
        return min(max(best - gap, floor), bid - min_distance)
    if ask + min_distance > floor:
        return None
    return max(min(best + gap, floor), ask + min_distance)


def ratchet(direction, current, proposed):
    """A BUY SL only rises; a SELL SL only falls."""
    return max(current, proposed) if direction == 1 else min(current, proposed)


class AdaptiveTrailPolicyTests(unittest.TestCase):
    def test_lane_specific_activation_and_evidence_adjustments(self):
        self.assertEqual([arm_threshold(t) for t in (5, 15, 30)],
                         [0.45, 0.65, 0.85])
        self.assertAlmostEqual(arm_threshold(5, weak=True), 0.33)
        self.assertAlmostEqual(
            arm_threshold(5, aligned=True, directional=True,
                          own_score=75, score_delta=2), 0.53)
        self.assertGreater(arm_threshold(5, weak=True), 0.0)

    def test_m5_can_arm_before_tp1(self):
        # At +0.46R, M5 clears its base +0.45R trigger; TP1 is deliberately
        # false. A broker-valid, cost-aware floor is the other required gate.
        progress_r = 0.46
        threshold = arm_threshold(5)
        tp1_hit = False
        floor_available = True
        self.assertFalse(tp1_hit)
        self.assertTrue(progress_r >= threshold and floor_available)

    def test_market_regime_and_evidence_change_the_following_gap(self):
        choppy = trail_distance(5, 2.0, 1.0, 0.20, 7, range_middle=True)
        directional = trail_distance(
            5, 2.0, 1.0, 0.65, 1, trend=True, aligned=True,
            own_score=78, score_delta=3)
        volatile_chop = trail_distance(
            5, 4.0, 2.0, 0.20, 6, volatile=True, weak=True)
        self.assertLess(choppy, directional)
        self.assertLess(volatile_chop, 4.0 * 0.65)
        self.assertGreater(
            trail_distance(30, 2.0, 1.0, 0.5, 1),
            trail_distance(5, 2.0, 1.0, 0.5, 1))

    def test_cost_floor_stays_on_the_profitable_side_of_entry(self):
        buy = cost_floor(100.0, 1, 0.12, 0.04, 0.02, 0.01)
        sell = cost_floor(100.0, -1, 0.12, 0.04, 0.02, 0.01)
        coarse_buy = cost_floor(100.0, 1, 0.10, 0.04, 0.02, 0.01,
                               tick_size=0.25)
        coarse_sell = cost_floor(100.0, -1, 0.10, 0.04, 0.02, 0.01,
                                 tick_size=0.25)
        self.assertGreater(buy, 100.0)
        self.assertLess(sell, 100.0)
        self.assertGreaterEqual(coarse_buy, 100.16)
        self.assertLessEqual(coarse_sell, 99.84)
        self.assertAlmostEqual(coarse_buy / 0.25, round(coarse_buy / 0.25))
        self.assertAlmostEqual(coarse_sell / 0.25, round(coarse_sell / 0.25))

    def test_broker_space_and_one_way_ratchet(self):
        rng = random.Random(20261015)
        for _ in range(1000):
            entry = rng.uniform(10.0, 10000.0)
            buffer = rng.uniform(0.01, 0.5)
            gap = rng.uniform(0.02, 4.0)
            distance = rng.uniform(0.01, 0.3)

            buy_floor = entry + buffer
            buy_bid = buy_floor + distance + rng.uniform(0.02, 3.0)
            buy_best = buy_bid + rng.uniform(0.0, 2.0)
            buy_sl = safe_candidate(1, buy_best, gap, buy_floor,
                                    buy_bid, buy_bid + 0.01, distance)
            self.assertIsNotNone(buy_sl)
            self.assertGreaterEqual(buy_sl, entry)
            self.assertLess(buy_sl, buy_bid - distance + 1e-9)
            self.assertGreaterEqual(ratchet(1, entry, buy_sl), entry)

            sell_floor = entry - buffer
            sell_ask = sell_floor - distance - rng.uniform(0.02, 3.0)
            sell_best = sell_ask - rng.uniform(0.0, 2.0)
            sell_sl = safe_candidate(-1, sell_best, gap, sell_floor,
                                     sell_ask - 0.01, sell_ask, distance)
            self.assertIsNotNone(sell_sl)
            self.assertLessEqual(sell_sl, entry)
            self.assertGreater(sell_sl, sell_ask + distance - 1e-9)
            self.assertLessEqual(ratchet(-1, entry, sell_sl), entry)

        self.assertIsNone(safe_candidate(1, 101.0, 1.0, 100.5,
                                         100.6, 100.61, 0.2))
        self.assertIsNone(safe_candidate(-1, 99.0, 1.0, 99.5,
                                         99.39, 99.4, 0.2))

    def test_mql5_wiring_calls_trailing_before_tp1_and_exposes_state(self):
        engine = ENGINE_PATH.read_text(encoding="utf-8")
        expert = EXPERT_PATH.read_text(encoding="utf-8")
        manage = engine.index("bool CTradeEngine::Manage(const SATTrailContext &ctx)")
        trail_call = engine.index("ManageTrailingStop(i,ctx,mark,bid,ask);", manage)
        tp1_branch = engine.index("//--- TP1:", trail_call)
        self.assertLess(trail_call, tp1_branch)
        self.assertIn("if(progress_r<arm || floating<=0.0)", engine)
        self.assertIn("NormStopPrice(MathMax(sl,floor),1)", engine)
        self.assertIn("NormStopPrice(MathMin(sl,floor),-1)", engine)
        self.assertIn("sl<=0.0", engine)
        self.assertIn("sl<=broker_sl+tol", engine)
        self.assertIn("sl>=broker_sl-tol", engine)
        self.assertIn("double CTradeEngine::NormStopPrice", engine)
        self.assertIn('StateKey(ticket,"TRSL")', engine)
        self.assertIn("g_trade.Manage(ctx)", expert)
        self.assertIn("g_trade.TrailStatusText(i)", expert)


if __name__ == "__main__":
    unittest.main(verbosity=2)
