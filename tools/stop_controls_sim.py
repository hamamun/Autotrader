#!/usr/bin/env python3
"""Synthetic stop-control lifecycle + MQL5 wiring regression checks.

Not an MQL5 runtime or broker emulator. Native MetaEditor/MT5 checks in README
remain required. The model mirrors the stop intent, not fills or profitability.
"""
from dataclasses import dataclass, asdict
import unittest
from trailing_policy_sim import (ENGINE_PATH, EXPERT_PATH, arm_threshold,
                                 cost_floor, safe_candidate)


@dataclass
class StopIntent:
    direction: int = 1
    entry: float = 100.0
    reference: float = 98.0
    sl: float = 0.0
    remembered: float = 0.0
    armed: bool = False
    tp1: bool = False
    pending: bool = False

    @classmethod
    def open(cls, direction, initial_sl, pending=False):
        reference = 100.0 - direction * 2.0
        stop = reference if initial_sl else 0.0
        return cls(direction, reference=reference, sl=stop,
                   remembered=stop, pending=pending)

    def repair(self, trailing, floor):
        # No fallback to the internal reference. OFF preserves actual SL.
        if not trailing or self.pending:
            return self.sl
        return floor if self.armed and self.remembered <= 0 else self.remembered

    def manage(self, trailing, lane, mark, broker_space=True, tp1=False):
        if self.pending:
            return
        self.tp1 |= tp1  # partial-close milestone independent of trailing
        if not trailing:
            return
        risk = abs(self.entry - self.reference) if self.reference > 0 else 0
        if risk <= .01 and not self.tp1 and not self.armed:
            return
        progress = max(0, (mark - self.entry) * self.direction)
        if not self.armed and not self.tp1:
            if risk <= .01 or progress / risk < arm_threshold(lane):
                return
        floor = cost_floor(self.entry, self.direction, .02, .01, 0, .01)
        if not broker_space:
            return
        bid = mark if self.direction == 1 else mark - .02
        ask = mark + .02 if self.direction == 1 else mark
        candidate = safe_candidate(self.direction, mark, 999, floor,
                                   bid, ask, .05)
        if candidate is None:
            return
        self.armed = True
        if self.sl == 0 or (candidate - self.sl) * self.direction > 0:
            self.sl = self.remembered = candidate


class StopControlTests(unittest.TestCase):
    def test_four_combinations_on_all_lanes_both_directions_and_order_types(self):
        for lane in (5, 15, 30):
            for direction in (1, -1):
                for initial in (False, True):
                    for trailing in (False, True):
                        for pending in (False, True):
                            with self.subTest(lane=lane, direction=direction,
                                              initial=initial, trailing=trailing,
                                              pending=pending):
                                state = StopIntent.open(direction, initial, pending)
                                original = state.sl
                                self.assertEqual(original != 0, initial)
                                self.assertEqual(abs(state.entry-state.reference), 2)
                                self.assertEqual(state.repair(trailing, 100.03), original)
                                # Restart before activation; pending fill retains risk.
                                state = StopIntent(**asdict(state))
                                state.pending = False
                                mark = 100 + direction * (arm_threshold(lane)+.01)*2
                                state.manage(trailing, lane, mark)
                                if trailing:
                                    self.assertGreater((state.sl-100)*direction, 0)
                                else:
                                    self.assertEqual(state.sl, original)
                                state.manage(trailing, lane, 100+direction*4, tp1=True)
                                self.assertTrue(state.tp1)
                                if not trailing:
                                    self.assertEqual(state.sl, original)

    def test_tp1_can_place_first_stop_even_below_normal_arm_threshold(self):
        for direction in (1, -1):
            state = StopIntent.open(direction, False)
            state.manage(True, 30, 100+direction*.3, tp1=True)
            self.assertTrue(state.armed)
            self.assertGreater((state.sl-100)*direction, 0)

    def test_broker_rejection_waits_then_retries(self):
        state = StopIntent.open(1, False)
        state.manage(True, 5, 102, broker_space=False, tp1=True)
        self.assertEqual(state.sl, 0)
        state.manage(True, 5, 102)
        self.assertGreater(state.sl, 100)

    def test_merely_positive_does_not_place_stop(self):
        state = StopIntent.open(1, False)
        state.manage(True, 5, 100.1)
        self.assertEqual(state.sl, 0)

    def test_missing_risk_is_not_distance_to_zero(self):
        state = StopIntent.open(1, False)
        state.reference = 0
        state.manage(True, 5, 160)
        self.assertEqual(state.sl, 0)
        state.manage(True, 5, 101, tp1=True)
        self.assertGreater(state.sl, 100)

    def test_off_after_protection_freezes_stop_across_restart_and_tp1(self):
        for direction in (1, -1):
            state = StopIntent.open(direction, False)
            state.manage(True, 5, 100+direction*2)
            existing = state.sl
            state = StopIntent(**asdict(state))
            state.manage(False, 5, 100+direction*4, tp1=True)
            self.assertEqual(state.sl, existing)
            self.assertEqual(state.repair(False, 100+direction*.5), existing)

    def test_reenable_after_tp1_protects_no_sl_trade(self):
        state = StopIntent.open(1, False)
        state.manage(False, 5, 102, tp1=True)
        self.assertEqual(state.sl, 0)
        state = StopIntent(**asdict(state))
        state.manage(True, 5, 102)
        self.assertGreater(state.sl, 100)

    def test_inputs_and_market_limit_order_wiring(self):
        expert = EXPERT_PATH.read_text()
        engine = ENGINE_PATH.read_text()
        self.assertRegex(expert, r'input bool InpTrailStop\s*= true;')
        self.assertRegex(expert, r'input bool InpSL\s*= false;')
        self.assertIn('g_symbol, InpTrailStop, InpSL)', expert)
        open_code = engine.split('bool CTradeEngine::Open(', 1)[1].split(
            'void CTradeEngine::UpdateTrailContext', 1)[0]
        self.assertIn('double s  = (m_initial_sl_enabled ? planned_sl : 0.0);', open_code)
        self.assertIn('CalcLots(sl_dist, risk_pct, atr)', open_code)
        self.assertIn('m_expect_sl = planned_sl;', open_code)
        for method in ('BuyLimit', 'SellLimit'):
            self.assertEqual(open_code.count(f'trade.{method}(lots, e, m_symbol, s, t3,'), 2)
        for method in ('Buy', 'Sell'):
            self.assertIn(f'trade.{method}(lots, m_symbol, 0.0, s, t3,', open_code)
        self.assertIn('(m_initial_sl_enabled ? m_expect_sl : 0.0)', engine)
        self.assertIn('GlobalVariableSet(StateKey(ticket,"SL0"),st[idx].sl_initial)', engine)
        self.assertIn('st[idx].sl_initial=GlobalVariableGet(key)', engine)

    def test_all_sl_update_paths_honor_switch_and_tp_only_repair_is_allowed(self):
        engine = ENGINE_PATH.read_text()
        for signature in ('void CTradeEngine::ManageTrailingStop(',
                          'bool CTradeEngine::MoveStopTo('):
            body = engine.split(signature, 1)[1].split('//+---', 1)[0]
            self.assertIn('if(!m_trailing_enabled)', body)
        tp1 = engine.split('//--- TP1:', 1)[1].split('//--- TP2:', 1)[0]
        self.assertLess(tp1.index('PartialClose('), tp1.index('if(m_trailing_enabled)'))
        self.assertLess(tp1.index('if(m_trailing_enabled)'), tp1.index('MoveStopTo('))
        repair = engine.split('bool CTradeEngine::EnsureProtection(', 1)[1].split(
            'bool CTradeEngine::Manage(', 1)[0]
        self.assertIn('NormStopPrice(st[idx].sl_now,st[idx].dir) : sl_brok)', repair)
        self.assertNotIn('NormStopPrice(st[idx].sl_initial', repair)
        self.assertIn('bool profit_lock=m_trailing_enabled &&', repair)
        self.assertNotIn('if(want_sl<=0.0)\n      return false;', repair)
        self.assertIn('bool sl_change=(MathAbs(sl_brok-want_sl)>tol)', repair)
        self.assertIn('trade.PositionModify(st[idx].ticket,want_sl,want_tp)', repair)
        risk = engine.split('void CTradeEngine::ManageTrailingStop(', 1)[1].split(
            'bool CTradeEngine::MoveStopTo(', 1)[0]
        self.assertIn('double risk=(st[idx].sl_initial>0.0 ?', risk)
        self.assertIn('if(risk>m_point)\n      progress_r=favorable/risk;', risk)
        self.assertIn('NONE (no broker-side stop)', engine)
        self.assertIn('OFF (existing SL unchanged)', engine)


if __name__ == '__main__':
    unittest.main(verbosity=2)
