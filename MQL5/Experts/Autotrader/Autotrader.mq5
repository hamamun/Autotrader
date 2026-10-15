//+------------------------------------------------------------------+
//| Time exit, restart restore.                                      |
//| Phase 5: Safety layer - permissions, stale quotes, spread, news,  |
//|          gap shock, daily loss stand-down, equity floor.          |
//| Phase 6: Auto-execution + the owner's Win/Loss/BE scoreboard and  |
//|          the CSV audit trail.                                     |
//|                                                                   |
//| Inputs: Auto Trading, TrailStop and SL. Adaptive distances are    |
//| decided by the EA from the symbol and the market itself.         |
//+------------------------------------------------------------------+
#property copyright   "Autotrader"
#property version     "1.00"
#property description "Autotrader - fully automatic MT5 EA (Phases 1-6: panels, symbol intelligence, regime, direction engine, trade engine, safety, scoreboard)"

#include <Autotrader/Panel.mqh>
#include <Autotrader/SymbolIntelligence.mqh>
#include <Autotrader/MarketData.mqh>
#include <Autotrader/RegimeEngine.mqh>
#include <Autotrader/ModernIndicators.mqh>
#include <Autotrader/SmartMoney.mqh>
#include <Autotrader/VolumeFlow.mqh>
#include <Autotrader/DirectionEngine.mqh>
#include <Autotrader/SafetyManager.mqh>
#include <Autotrader/StatsKeeper.mqh>
#include <Autotrader/TradeEngine.mqh>

//--- owner controls; distances and risk sizing remain self-configuring
input bool InpAutoTrading = true; // Auto Trading
input bool InpTrailStop   = true; // TrailStop
input bool InpSL          = false; // SL

//--- panels
CInfoPanel          g_main;      // MAIN panel (signal view)
CInfoPanel          g_live;      // LIVE TRADING panel (real open order)
//--- brains
CSymbolIntelligence g_symbol;    // symbol profile + adaptive dials
CDirectionEngine    g_dir;       // the judge: two-sided evidence + qualified signal
CSafetyManager      g_safety;    // freeze conditions
CStatsKeeper        g_stats;     // Win/Loss/BE scoreboard + CSV audit
CTradeEngine        g_trade;     // entries, ladder, break-even, restore

//--- state
bool     g_compatible_tf = true;    // chart TF is M5 / M15 / M30
ulong    g_magic          = 0;      // auto-derived, per symbol + timeframe
int      g_live_gap       = 10;     // px between MAIN and LIVE panels
datetime g_last_brains    = 0;      // throttle: direction engine (1s)
datetime g_last_profile   = 0;      // throttle: symbol profile (5s)
datetime g_last_latch     = 0;      // latch time we already counted
datetime g_last_fail      = 0;      // order-failure cooldown
datetime g_last_audit_bar = 0;      // audit line printed once per lane bar
bool     g_had_trade      = false;  // to notice an active position/order ending
bool     g_had_position   = false;  // distinguish a closed trade from an unfilled pending order
bool     g_live_shown     = false;  // LIVE panel visibility, cached
datetime g_last_gap_bar   = 0;      // gap check runs once per lane bar
double   g_disp_lots      = 0.0;    // cached display lot size
datetime g_disp_lots_at   = 0;

//+------------------------------------------------------------------+
//| formatting helpers                                                |
//+------------------------------------------------------------------+
string FmtPrice(const double v)
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return DoubleToString(v, digits);
  }

//--- "+USD 3.95" / "-USD 6.24"
string FmtUsd(const double v)
  {
   return (v >= 0 ? "+USD " : "-USD ") + DoubleToString(MathAbs(v), 2);
  }

//--- "1234 pts"
string FmtPts(const double price_diff)
  {
   long pts = (long)MathRound(MathAbs(price_diff) / _Point);
   return IntegerToString(pts) + " pts";
  }

//--- what a price move is worth in money for a given lot size
double EstUsd(const double price_diff, const double lots)
  {
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0.0 || tick_value <= 0.0)
      return 0.0;
   return price_diff / tick_size * tick_value * lots;
  }

string ConfLabel(const int score)
  {
   return ATDE_EvidenceTier(score);
  }

string TFName(void)
  {
   switch((ENUM_TIMEFRAMES)Period())
     {
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      default:         return "TF" + IntegerToString((int)Period());
     }
  }

//--- session name from server time (information only - never blocks)
string SessionName(void)
  {
   MqlDateTime dt;
   TimeCurrent(dt);
   int h = dt.hour;
   if(h < 8)  return "Asia";
   if(h < 13) return "London";
   if(h < 17) return "London-New York Overlap";
   if(h < 22) return "New York";
   return "Asia (late)";
  }

string HmOf(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   string hh = IntegerToString(dt.hour);
   string mm = IntegerToString(dt.min);
   if(dt.hour < 10) hh = "0" + hh;
   if(dt.min  < 10) mm = "0" + mm;
   return hh + ":" + mm;
  }

//--- "Expected Duration" is now computed from the target distance and
//--- this symbol's own speed, not a fixed phrase (Phase 3)
string DurationText(const int minutes)
  {
   if(minutes <= 0)
      return "~-";
   double lo = (double)minutes * 0.60 / 60.0;
   double hi = (double)minutes * 1.60 / 60.0;
   if(hi < 1.0)
      return "~" + IntegerToString((int)MathRound(lo * 60.0)) + "-" +
             IntegerToString((int)MathRound(hi * 60.0)) + " minutes";
   int dp_lo = (lo < 10.0) ? 1 : 0;
   int dp_hi = (hi < 10.0) ? 1 : 0;
   return "~" + DoubleToString(lo, dp_lo) + "-" + DoubleToString(hi, dp_hi) + " hours";
  }

//--- how old is the broker's last quote?
int QuoteAgeSec(void)
  {
   datetime t = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
   if(t <= 0)
      return 0;
   datetime now = TimeCurrent();
   if(now <= t)
      return 0;
   return (int)(now - t);
  }

//--- the lot size the EA would use right now (also used for the panel's
//--- USD estimates, so what you read is what would really be traded).
//--- Cached for a few seconds: it calls the broker's margin maths.
double DisplayLots(void)
  {
   datetime now = TimeCurrent();
   if(g_disp_lots > 0.0 && g_disp_lots_at > 0 && now - g_disp_lots_at < 5)
      return g_disp_lots;
   double lots = g_trade.CalcLots(g_dir.SlDist(), g_symbol.RiskPct(), g_dir.LaneAtr());
   if(lots <= 0.0)
      lots = g_symbol.VolumeMin();
   if(lots <= 0.0)
      lots = 0.10;
   g_disp_lots = lots;
   g_disp_lots_at = now;
   return lots;
  }

//--- a level that is not known yet is printed as a dash, never as 0
string FmtLevel(const double v)
  {
   return (v > 0.0) ? FmtPrice(v) : GLYPH_DASH;
  }

//+------------------------------------------------------------------+
//| magic number: derived from the symbol + timeframe, so it is the   |
//| same after every restart (that is what makes restore possible),   |
//| and every chart lane stays isolated from the others and from any  |
//| manual trade.                                                     |
//+------------------------------------------------------------------+
ulong DeriveMagic(void)
  {
   string s = _Symbol;
   ulong  h = 2166136261;
   int    len = StringLen(s);
   for(int i = 0; i < len; i++)
     {
      h ^= (ulong)StringGetCharacter(s, i);
      h *= 16777619;
     }
   int tfc = 5;
   if(Period() == PERIOD_M15)      tfc = 15;
   else if(Period() == PERIOD_M30) tfc = 30;
   return 700000 + (h % 9000) * 100 + (ulong)tfc;
  }

//+------------------------------------------------------------------+
//| open the trade the judge asked for                                |
//+------------------------------------------------------------------+
void TryOpenTrade(void)
  {
   int dir = (g_dir.Dir() == AT_SIG_BUY) ? 1 : -1;
   int eta = g_dir.ExpectedMinutes() * 60;

   bool ok = g_trade.Open(dir, g_dir.UseLimit(), g_dir.Entry(), g_dir.Sl(),
                          g_dir.Tp1(), g_dir.Tp2(), g_dir.Tp3(),
                          eta, g_symbol.RiskPct(), g_dir.LaneAtr());
   if(ok)
     {
      g_dir.MarkTraded();
      g_trade.SetExpectedDefault(eta);
      g_had_trade = true;
      g_had_position = g_trade.HasPosition();
      g_stats.Log("OPEN", g_dir.Audit());
     }
   else
     {
      g_last_fail = TimeCurrent();
      g_stats.Log("ORDER FAILED", g_trade.LastError());
      Print("Autotrader: could not open the trade - ", g_trade.LastError());
     }
  }

//+------------------------------------------------------------------+
//| run the brains (throttled): profile -> direction -> safety        |
//+------------------------------------------------------------------+
void RunBrains(const bool force)
  {
   datetime now = TimeCurrent();
   if(!force && g_last_brains > 0 && now - g_last_brains < 1)
      return;
   g_last_brains = now;

   //--- Phase 2: keep the symbol profile current (5s is plenty)
   if(force || g_last_profile == 0 || now - g_last_profile >= 5)
     {
      g_symbol.Refresh(_Symbol, (ENUM_TIMEFRAMES)Period());
      g_last_profile = now;
     }

   //--- Phase 3: the judge
   long spread_pts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_dir.Refresh(g_symbol, force, spread_pts,
                 g_symbol.SpreadLimitPts(), QuoteAgeSec());

   //--- Phase 6: scoreboard, then Phase 5: safety (it needs today's result)
   g_stats.Scan(false);
   g_safety.SetDayRealized(g_stats.NetToday());
   g_safety.Refresh(g_symbol, QuoteAgeSec());

   //--- a NEW latched signal? count it, log it, and act on it
   int      dir  = g_dir.Dir();
   datetime ltch = g_dir.LatchTime();
   if(dir != AT_SIG_HOLD && ltch != 0 && ltch != g_last_latch)
     {
      g_last_latch = ltch;
      g_stats.OnSignal(dir, g_dir.Score(), g_dir.Threshold(),
                       g_dir.RegimeDisplay(), g_dir.Entry(), g_dir.Sl(),
                       g_dir.Tp1(), g_dir.Tp2(), g_dir.Tp3(), g_dir.Audit());
      Print("Autotrader: NEW SIGNAL - ", g_dir.Audit());
     }
   else if(dir == AT_SIG_HOLD && g_last_latch != 0)
      g_last_latch = 0;

   //--- Revalidate every pending entry on each brain pass. An order must
   //--- still have a qualified signal, auto-trading permission and all
   //--- current safety checks; otherwise cancel it before it can fill stale.
   if(g_trade.HasPending())
     {
      string cancel_why = "";
      if(!InpAutoTrading)
         cancel_why = "Auto Trading OFF - pending entry cancelled";
      else if(!g_safety.CanOpen())
         cancel_why = "safety block - pending entry cancelled: " + g_safety.Block();
      else if(dir == AT_SIG_HOLD || !g_dir.Tradable())
         cancel_why = "signal no longer execution-qualified - pending entry cancelled: " +
                      g_dir.Reason();
      if(cancel_why != "" && g_trade.CancelPending(cancel_why))
         g_stats.Log("CANCEL", cancel_why);
     }

   //--- Phase 6: auto-execution (only when everything agrees)
   if(InpAutoTrading && dir != AT_SIG_HOLD && g_dir.Tradable() &&
      !g_dir.LatchTraded() && !g_trade.HasAny() && g_safety.CanOpen())
     {
      if(g_last_fail == 0 || now - g_last_fail >= 30)
         TryOpenTrade();
     }
  }

//+------------------------------------------------------------------+
//| give the trade manager a compact, current market/trend snapshot   |
//+------------------------------------------------------------------+
void BuildTrailContext(SATTrailContext &ctx)
  {
   ctx.ready=false;
   ctx.lane_minutes=(int)Period();
   ctx.bar_time=0;
   ctx.atr=g_symbol.AtrPrice();
   ctx.atr_ratio=g_symbol.AtrRatio();
   ctx.efficiency=0.0;
   ctx.sign_changes=0;
   ctx.trend=false; ctx.pullback=false; ctx.range_extreme=false;
   ctx.range_middle=false; ctx.volatile_state=false; ctx.quiet_state=false;
   ctx.transition_state=false;
   ctx.lane_direction=0;
   ctx.m15_direction=g_dir.a15.regime.Direction();
   ctx.m30_direction=g_dir.a30.regime.Direction();
   ctx.buy_score=g_dir.BuyScore();
   ctx.sell_score=g_dir.SellScore();
   ctx.choch_direction=0; ctx.bars_since_choch=999;
   ctx.swing_direction=0;
   ctx.swing_high=0.0; ctx.swing_low=0.0;
   ctx.swing_high_bar=0; ctx.swing_low_bar=0;

   if(Period()==PERIOD_M5)
     {
      ctx.ready=g_dir.a5.ready;
      ctx.atr=g_dir.a5.atr;
      ctx.atr_ratio=g_dir.a5.atr_ratio;
      ctx.efficiency=g_dir.a5.eff;
      ctx.sign_changes=g_dir.a5.regime.SignChanges();
      ctx.trend=g_dir.a5.regime.IsTrend();
      ctx.pullback=g_dir.a5.regime.IsPullback();
      ctx.range_extreme=g_dir.a5.regime.IsRangeExtreme();
      ctx.range_middle=(g_dir.a5.regime.Kind()==AT_REGIME_RANGE_MIDDLE);
      ctx.volatile_state=(g_dir.a5.regime.Kind()==AT_REGIME_VOLATILE);
      ctx.quiet_state=(g_dir.a5.regime.Kind()==AT_REGIME_QUIET);
      ctx.transition_state=(g_dir.a5.regime.Kind()==AT_REGIME_TRANSITION ||
                            g_dir.a5.regime.Kind()==AT_REGIME_CALIBRATING);
      ctx.lane_direction=g_dir.a5.regime.Direction();
      ctx.choch_direction=g_dir.a5.smc.choch_dir;
      ctx.bars_since_choch=g_dir.a5.smc.bars_since_choch;
      ctx.swing_direction=g_dir.a5.smc.structure_dir;
      ctx.swing_high=g_dir.a5.smc.swing_hi;
      ctx.swing_low=g_dir.a5.smc.swing_lo;
      ctx.swing_high_bar=g_dir.a5.smc.swing_hi_bar;
      ctx.swing_low_bar=g_dir.a5.smc.swing_lo_bar;
     }
   else if(Period()==PERIOD_M15)
     {
      ctx.ready=g_dir.a15.ready;
      ctx.atr=g_dir.a15.atr;
      ctx.atr_ratio=g_dir.a15.atr_ratio;
      ctx.efficiency=g_dir.a15.eff;
      ctx.sign_changes=g_dir.a15.regime.SignChanges();
      ctx.trend=g_dir.a15.regime.IsTrend();
      ctx.pullback=g_dir.a15.regime.IsPullback();
      ctx.range_extreme=g_dir.a15.regime.IsRangeExtreme();
      ctx.range_middle=(g_dir.a15.regime.Kind()==AT_REGIME_RANGE_MIDDLE);
      ctx.volatile_state=(g_dir.a15.regime.Kind()==AT_REGIME_VOLATILE);
      ctx.quiet_state=(g_dir.a15.regime.Kind()==AT_REGIME_QUIET);
      ctx.transition_state=(g_dir.a15.regime.Kind()==AT_REGIME_TRANSITION ||
                            g_dir.a15.regime.Kind()==AT_REGIME_CALIBRATING);
      ctx.lane_direction=g_dir.a15.regime.Direction();
      ctx.choch_direction=g_dir.a15.smc.choch_dir;
      ctx.bars_since_choch=g_dir.a15.smc.bars_since_choch;
      ctx.swing_direction=g_dir.a15.smc.structure_dir;
      ctx.swing_high=g_dir.a15.smc.swing_hi;
      ctx.swing_low=g_dir.a15.smc.swing_lo;
      ctx.swing_high_bar=g_dir.a15.smc.swing_hi_bar;
      ctx.swing_low_bar=g_dir.a15.smc.swing_lo_bar;
     }
   else
     {
      ctx.lane_minutes=30;
      ctx.ready=g_dir.a30.ready;
      ctx.atr=g_dir.a30.atr;
      ctx.atr_ratio=g_dir.a30.atr_ratio;
      ctx.efficiency=g_dir.a30.eff;
      ctx.sign_changes=g_dir.a30.regime.SignChanges();
      ctx.trend=g_dir.a30.regime.IsTrend();
      ctx.pullback=g_dir.a30.regime.IsPullback();
      ctx.range_extreme=g_dir.a30.regime.IsRangeExtreme();
      ctx.range_middle=(g_dir.a30.regime.Kind()==AT_REGIME_RANGE_MIDDLE);
      ctx.volatile_state=(g_dir.a30.regime.Kind()==AT_REGIME_VOLATILE);
      ctx.quiet_state=(g_dir.a30.regime.Kind()==AT_REGIME_QUIET);
      ctx.transition_state=(g_dir.a30.regime.Kind()==AT_REGIME_TRANSITION ||
                            g_dir.a30.regime.Kind()==AT_REGIME_CALIBRATING);
      ctx.lane_direction=g_dir.a30.regime.Direction();
      ctx.choch_direction=g_dir.a30.smc.choch_dir;
      ctx.bars_since_choch=g_dir.a30.smc.bars_since_choch;
      ctx.swing_direction=g_dir.a30.smc.structure_dir;
      ctx.swing_high=g_dir.a30.smc.swing_hi;
      ctx.swing_low=g_dir.a30.smc.swing_lo;
      ctx.swing_high_bar=g_dir.a30.smc.swing_hi_bar;
      ctx.swing_low_bar=g_dir.a30.smc.swing_lo_bar;
     }
   ctx.bar_time=g_dir.LaneBarTime();
   if(ctx.atr<=0.0) ctx.atr=g_symbol.AtrPrice();
   if(ctx.atr_ratio<=0.0) ctx.atr_ratio=g_symbol.AtrRatio();
  }

//+------------------------------------------------------------------+
//| manage positions and record locally expired pending orders        |
//+------------------------------------------------------------------+
void ManageTrades(void)
  {
   SATTrailContext ctx;
   BuildTrailContext(ctx);
   if(g_trade.Manage(ctx))
      g_stats.Log("EXPIRE",g_trade.LastPendingEvent());
  }

//+------------------------------------------------------------------+
//| notice a trade finishing: the latch is free again                 |
//+------------------------------------------------------------------+
void CheckTradeFinished(void)
  {
   bool has_position = g_trade.HasPosition();
   bool has = g_trade.HasAny();
   if(g_had_trade && !has)
     {
      bool position_closed = g_had_position;
      g_had_trade = false;
      g_had_position = false;
      g_dir.ClearLatch();
      g_last_latch = 0;
      if(position_closed)
        {
         g_stats.Scan(true);
         g_stats.Log("CLOSED", "position finished - scoreboard updated");
        }
      else
         g_stats.Log("PENDING END", "pending entry removed or expired; no position opened");
     }
   else if(has)
     {
      g_had_trade = true;
      if(has_position)
         g_had_position = true;
     }
  }

//+------------------------------------------------------------------+
//| gap shock check, once per new lane bar                            |
//+------------------------------------------------------------------+
void CheckGapOnNewBar(void)
  {
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
   double open0  = iOpen(_Symbol, tf, 0);
   double close1 = iClose(_Symbol, tf, 1);
   double atr    = (g_dir.LaneAtr() > 0.0) ? g_dir.LaneAtr() : g_symbol.AtrPrice();
   g_safety.CheckGap(open0, close1, atr);
  }

//+------------------------------------------------------------------+
//| one audit line per closed lane bar - this is how the judge is     |
//| watched without trading (Experts log)                             |
//+------------------------------------------------------------------+
void AuditOnNewBar(void)
  {
   datetime bt = g_dir.LaneBarTime();
   if(bt == 0 || bt == g_last_audit_bar)
      return;
   g_last_audit_bar = bt;
   Print("Autotrader: ", g_dir.Audit(),
         " | safety: ", (g_safety.CanOpen() ? "ok" : g_safety.Block()),
         " | regime M30: ", g_dir.a30.regime.Display(),
         " | M15: ", g_dir.a15.regime.Display(),
         " | M5: ", g_dir.a5.regime.Display());
   bool can_submit = (InpAutoTrading && g_dir.Dir() != AT_SIG_HOLD &&
                      g_dir.Tradable() && !g_dir.LatchTraded() &&
                      !g_trade.HasAny() && g_safety.CanOpen() &&
                      (g_last_fail == 0 || TimeCurrent() - g_last_fail >= 30));
   string assessment = g_dir.Audit() + " | auto=" +
                       (InpAutoTrading ? "on" : "off") + " | safety=" +
                       (g_safety.CanOpen() ? "ok" : g_safety.Block());
   g_stats.OnAssessment(g_dir.BiasDir(), g_dir.BuyScore(), g_dir.SellScore(),
                        g_dir.Threshold(), g_dir.RegimeDisplay(),
                        g_dir.Entry(), g_dir.Sl(), g_dir.Tp1(), g_dir.Tp2(),
                        g_dir.Tp3(), SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
                        can_submit, assessment);
  }

//+------------------------------------------------------------------+
//| STATUS row - plain words, and always the real reason              |
//+------------------------------------------------------------------+
string StatusText(color &clr)
  {
   clr = CLR_ORANGE;

   if(!g_symbol.Ready() || !g_dir.Ready())
      return "STATUS: Calibrating - studying this symbol, collecting price history";

   if(g_trade.HasPosition())
      return "STATUS: Trading - position open, managing the ladder";

   if(g_trade.HasPending())
      return "STATUS: Waiting - fresh pending entry at the zone edge";

   string bias_note = "mixed BUY/SELL evidence";
   if(g_dir.BiasDir() == 1)
      bias_note = "BUY bias (" + g_dir.BiasTier() + " evidence; not a trade signal)";
   else if(g_dir.BiasDir() == -1)
      bias_note = "SELL bias (" + g_dir.BiasTier() + " evidence; not a trade signal)";

   if(!InpAutoTrading)
     {
      if(g_dir.Dir() == AT_SIG_HOLD)
         return "STATUS: Auto Trading OFF - " + bias_note + "; waiting: " + g_dir.Reason();
      return "STATUS: Auto Trading OFF - qualified signal displayed only, no orders sent";
     }

   if(!g_safety.CanOpen())
     {
      clr = g_safety.Alert() ? CLR_RED : CLR_ORANGE;
      return "STATUS: Frozen - " + g_safety.Block();
     }

   if(g_dir.Dir() == AT_SIG_HOLD)
      return "STATUS: Watching - " + bias_note + "; waiting: " + g_dir.Reason();

   if(!g_dir.LatchTraded() && g_last_fail > 0 &&
      TimeCurrent() - g_last_fail < 300)
     {
      clr = CLR_RED;
      return "STATUS: Order rejected - " + g_trade.LastError();
     }

   return "STATUS: Signal armed - " + g_dir.Reason();
  }

//+------------------------------------------------------------------+
//| update MAIN panel rows                                            |
//+------------------------------------------------------------------+
void UpdateMainPanel(void)
  {
   string dashes = "----------";

   //--- title row (row 0)
   string auto_txt = (InpAutoTrading &&
                      (bool)MQLInfoInteger(MQL_TRADE_ALLOWED) &&
                      (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) ? "ON" : "OFF";
   g_main.SetTitle("Autotrader V1.0 | " + _Symbol + " | TF: " + TFName() +
                   " | Auto Trading: " + auto_txt);

   if(!g_compatible_tf)
     {
      //--- owner rule: labels only, no data, and STATUS names the problem.
      //--- Colour rule: only SIGNAL and STATUS may be coloured.
      g_main.SetRow(1,  "Bid: " + dashes + " | Ask: " + dashes + " | Spread: " + dashes, CLR_TEXT);
      g_main.SetRow(2,  "Regime: " + dashes, CLR_TEXT);
      g_main.SetRow(3,  "SIGNAL: " + dashes, CLR_DIM);
      g_main.SetRow(4,  "Evidence: " + dashes, CLR_TEXT);
      g_main.SetRow(5,  "Entry: " + dashes, CLR_TEXT);
      g_main.SetRow(6,  "Stop Loss: " + dashes, CLR_TEXT);
      g_main.SetRow(7,  "Take Profit: " + dashes, CLR_TEXT);
      g_main.SetRow(8,  "Risk:Reward: " + dashes, CLR_TEXT);
      g_main.SetRow(9,  "Session: " + dashes, CLR_TEXT);
      g_main.SetRow(10, "STATUS: Incompatible chart - please attach to M5, M15 or M30", CLR_RED);
      g_main.SetRow(11, "Today: " + dashes, CLR_TEXT);
      g_main.SetRow(12, "All Time: " + dashes, CLR_TEXT);
      g_main.Layout();
      return;
     }

   //--- live quotes row
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_main.SetRow(1, "Bid: " + FmtPrice(bid) + " | Ask: " + FmtPrice(ask) +
                    " | Spread: " + IntegerToString(spread) + " pts", CLR_TEXT);

   //--- regime: real and specific (Phase 2), for THIS chart's lane
   g_main.SetRow(2, "Regime: " + g_dir.RegimeDisplay(), CLR_TEXT);

   //--- Separate the displayed directional bias from a latched trade signal.
   int    dir = g_dir.Dir();
   string sig_txt;
   color  sig_clr;
   if(dir == AT_SIG_BUY)
     { sig_txt = "SIGNAL: " + GLYPH_UP + " BUY"; sig_clr = CLR_GREEN; }
   else if(dir == AT_SIG_SELL)
     { sig_txt = "SIGNAL: " + GLYPH_DOWN + " SELL"; sig_clr = CLR_RED; }
   else if(g_dir.BiasDir() == 1)
     { sig_txt = "BIAS: " + GLYPH_UP + " BUY (not a trade signal)"; sig_clr = CLR_ORANGE; }
   else if(g_dir.BiasDir() == -1)
     { sig_txt = "BIAS: " + GLYPH_DOWN + " SELL (not a trade signal)"; sig_clr = CLR_ORANGE; }
   else
     { sig_txt = "DIRECTION: MIXED / WAIT"; sig_clr = CLR_DIM; }
   g_main.SetRow(3, sig_txt, sig_clr);

   //--- The two side-scores show contrary evidence. They are evidence indices,
   //--- not calibrated probabilities; execution still needs the separate gate.
   int gap = (int)MathAbs(g_dir.BiasGap());
   string lead = (g_dir.BiasDir() == 1) ? "BUY leads by " :
                 ((g_dir.BiasDir() == -1) ? "SELL leads by " : "mixed, gap ");
   string conf_txt;
   if(dir != AT_SIG_HOLD)
      conf_txt = "Evidence: BUY " + IntegerToString(g_dir.BuyScore()) +
                 " / SELL " + IntegerToString(g_dir.SellScore()) +
                 " | signal score " + IntegerToString(g_dir.Score()) + "/" +
                 IntegerToString(g_dir.Threshold()) + " (" + ConfLabel(g_dir.Score()) +
                 "; score is not probability)";
   else if(g_dir.BiasDir() != 0)
      conf_txt = "Evidence: BUY " + IntegerToString(g_dir.BuyScore()) +
                 " / SELL " + IntegerToString(g_dir.SellScore()) + " | " + lead +
                 IntegerToString(gap) + " (" + g_dir.BiasTier() +
                 "; score is not probability; trade threshold " +
                 IntegerToString(g_dir.Threshold()) + ")";
   else
      conf_txt = "Evidence mixed: BUY " + IntegerToString(g_dir.BuyScore()) +
                 " / SELL " + IntegerToString(g_dir.SellScore()) + " | gap " +
                 IntegerToString(gap) + " (no clear bias; scores are not probabilities)";
   g_main.SetRow(4, conf_txt, CLR_TEXT);

   //--- the price plan: only printed when the levels are real
   bool have_plan = (g_dir.Entry() > 0.0 && g_dir.Sl() > 0.0 && g_dir.Tp3() > 0.0 &&
                     (dir != AT_SIG_HOLD || g_dir.BiasDir() != 0));
   if(!have_plan)
     {
      g_main.SetRow(5, "Entry: " + GLYPH_DASH, CLR_TEXT);
      g_main.SetRow(6, "Stop Loss: " + GLYPH_DASH, CLR_TEXT);
      g_main.SetRow(7, "Take Profit: " + GLYPH_DASH, CLR_TEXT);
      g_main.SetRow(8, "Risk:Reward: " + GLYPH_DASH, CLR_TEXT);
     }
   else
     {
      double lots = DisplayLots();
      double entry = g_dir.Entry();
      double sl    = g_dir.Sl();
      double tp3   = g_dir.Tp3();

      double gap     = entry - bid;
      double gap_usd = EstUsd(gap, lots);
      string plan_tag = (dir == AT_SIG_HOLD) ? "Indicative entry: " : "Entry: ";
      g_main.SetRow(5, plan_tag + FmtPrice(entry) + " / gap est. " +
                       FmtUsd(gap_usd) + " (" + FmtPts(gap) + " away)", CLR_TEXT);

      double sl_diff = sl - entry;
      string sl_tag = (dir == AT_SIG_HOLD) ? "Indicative Stop Loss: " : "Stop Loss: ";
      if(!InpSL) sl_tag="Risk reference (SL OFF): ";
      g_main.SetRow(6, sl_tag + FmtPrice(sl) + " / est. " +
                       FmtUsd(EstUsd(sl_diff, lots)) + " (" + FmtPts(sl_diff) + ")", CLR_TEXT);

      double tp_diff = tp3 - entry;
      string tp_tag = (dir == AT_SIG_HOLD) ? "Indicative Take Profit: " : "Take Profit: ";
      g_main.SetRow(7, tp_tag + FmtPrice(tp3) + " / est. " +
                       FmtUsd(EstUsd(tp_diff, lots)) + " (" + FmtPts(tp_diff) + ")", CLR_TEXT);

      string rr_tag = (dir == AT_SIG_HOLD) ? "Indicative Risk:Reward 1:" : "Risk:Reward 1:";
      g_main.SetRow(8, rr_tag + DoubleToString(g_dir.Rr(), 1), CLR_TEXT);
     }

   //--- session (information only) + the real expected duration
   string dur = have_plan ? DurationText(g_dir.ExpectedMinutes()) : "~-";
   g_main.SetRow(9, "Session: " + SessionName() + " | Expected Duration: " + dur, CLR_TEXT);

   //--- status: the honest reason, in plain words
   color st_clr = CLR_ORANGE;
   g_main.SetRow(10, StatusText(st_clr), st_clr);

   //--- counters (owner rule: Win = closed positive, Loss = closed negative, BE = zero)
   g_main.SetRow(11, g_stats.TodayText(), CLR_TEXT);
   g_main.SetRow(12, g_stats.AllTimeText(), CLR_TEXT);

   g_main.Layout();
  }

//+------------------------------------------------------------------+
//| LIVE TRADING panel - real orders only, since Phase 4              |
//+------------------------------------------------------------------+
void UpdateLivePanel(void)
  {
   bool visible = (g_compatible_tf && g_trade.HasAny());
   if(visible != g_live_shown)
     {
      g_live.SetVisible(visible);   // only when it really changes
      g_live_shown = visible;
     }
   if(!visible)
      return;

   int i = g_trade.MainIdx();
   if(i < 0)
      return;

   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mark  = (g_trade.st[i].dir == 1) ? bid : ask;
   string dir_s = (g_trade.st[i].dir == 1) ? "BUY" : "SELL";
   double lots  = g_trade.st[i].v_now;

   g_live.SetTitle("LIVE TRADING");

   //--- row 1: the order itself
   if(g_trade.st[i].is_pending)
      g_live.SetRow(1, "Order #" + IntegerToString((long)g_trade.st[i].ticket) + " | " +
                       dir_s + " LIMIT " + DoubleToString(lots, 2) +
                       " lot | placed " + HmOf(g_trade.st[i].opened), CLR_TEXT);
   else
      g_live.SetRow(1, "Order #" + IntegerToString((long)g_trade.st[i].ticket) + " | " +
                       dir_s + " " + DoubleToString(lots, 2) +
                       " lot | opened " + HmOf(g_trade.st[i].opened), CLR_TEXT);

   //--- row 2: entry -> now, with the floating result
   if(g_trade.st[i].is_pending)
     {
      double dist = mark - g_trade.st[i].entry;
      g_live.SetRow(2, "Entry: " + FmtPrice(g_trade.st[i].entry) + " (limit) " +
                       GLYPH_ARROW + " Now: " + FmtPrice(mark) + "  (" +
                       FmtPts(dist) + " away)", CLR_TEXT);
     }
   else
      g_live.SetRow(2, "Entry: " + FmtPrice(g_trade.st[i].entry) + " " + GLYPH_ARROW +
                       " Now: " + FmtPrice(mark) + "  (floating " +
                       FmtUsd(g_trade.FloatingUsd(i)) + ")", CLR_TEXT);

   //--- rows 3-5: the protective stop, break-even, trailing
   g_live.SetRow(3, "Stop Loss : " + g_trade.SlJourneyText(i), CLR_TEXT);
   g_live.SetRow(4, "Break-Even: " + g_trade.BeStateText(i), CLR_TEXT);
   g_live.SetRow(5, "Trail Stop: " + g_trade.TrailStatusText(i), CLR_TEXT);

   //--- rows 6-8: the owner's 60 / 80 / 100 ladder
   string tp1s, tp2s, tp3s;
   if(g_trade.st[i].is_pending)
     {
      tp1s = "pending - waiting for the entry";
      tp2s = "pending";
      tp3s = "pending";
     }
   else
     {
      double prog = g_trade.TpProgress(i);
      if(g_trade.st[i].tp1_hit)
         tp1s = GLYPH_CHECK + " HIT " + HmOf(g_trade.st[i].tp1_time) +
                " - closed 50% of lot";
      else
         tp1s = "pending - " + DoubleToString(prog, 0) + "% progress to target";

      if(g_trade.st[i].tp2_hit)
         tp2s = GLYPH_CHECK + " HIT - closed 30% of lot";
      else if(g_trade.st[i].tp1_hit)
        {
         double full2 = MathAbs(g_trade.st[i].tp2 - g_trade.st[i].entry);
         double p2 = (full2 > 0.0)
                     ? MathMin(99.0, MathAbs(mark - g_trade.st[i].entry) / full2 * 100.0)
                     : 0.0;
         tp2s = "pending - " + DoubleToString(p2, 0) + "% progress to target";
        }
      else
         tp2s = "pending";

      if(g_trade.st[i].tp3_hit)
         tp3s = GLYPH_CHECK + " HIT - closed 20% of lot";
      else
         tp3s = "pending";
     }
   g_live.SetRow(6, "TP1 " + FmtLevel(g_trade.st[i].tp1) + " (60%) : " + tp1s, CLR_TEXT);
   g_live.SetRow(7, "TP2 " + FmtLevel(g_trade.st[i].tp2) + " (80%) : " + tp2s, CLR_TEXT);
   g_live.SetRow(8, "TP3 " + FmtLevel(g_trade.st[i].tp3) + " (100%): " + tp3s, CLR_TEXT);

   //--- row 9: what the manager is doing right now
   string st;
   if(g_trade.st[i].is_pending)
      st = "STATUS: Waiting - entry at " + FmtPrice(g_trade.st[i].entry);
   else if(!InpTrailStop)
      st="STATUS: Managing TP ladder - trailing OFF; existing SL unchanged";
   else if(!g_trade.st[i].tp1_hit && g_trade.st[i].trail_armed &&
           g_trade.st[i].be_locked &&
           g_trade.st[i].trail_stage==ATTE_TRAIL_FOLLOWING)
      st="STATUS: Managing - adaptive trail following price before TP1";
   else if(!g_trade.st[i].tp1_hit && g_trade.st[i].trail_armed &&
           !g_trade.st[i].be_locked)
      st="STATUS: Managing - trail armed; waiting for safe broker stop space";
   else if(!g_trade.st[i].tp1_hit && g_trade.st[i].trail_armed)
      st="STATUS: Managing - profit floor locked, running to TP1";
   else if(!g_trade.st[i].tp1_hit)
      st="STATUS: Managing - trail waiting for a profitable move to TP1";
   else if(!g_trade.st[i].tp2_hit && g_trade.st[i].trail_armed &&
           !g_trade.st[i].be_locked)
      st="STATUS: Managing - trail armed; waiting for safe broker stop space";
   else if(!g_trade.st[i].tp2_hit &&
           g_trade.st[i].trail_stage==ATTE_TRAIL_FOLLOWING)
      st="STATUS: Managing - adaptive trail following price, running to TP2";
   else if(!g_trade.st[i].tp2_hit && g_trade.st[i].be_locked)
      st="STATUS: Managing - protected past entry, running to TP2";
   else if(!g_trade.st[i].tp2_hit)
      st="STATUS: Managing - running to TP2";
   else if(!g_trade.st[i].tp3_hit)
      st = "STATUS: Managing - running to TP3";
   else
      st = "STATUS: Managing - ladder complete";
   g_live.SetRow(9, st, CLR_ORANGE);   // STATUS row: coloured by design

   g_live.Layout();
  }

//+------------------------------------------------------------------+
//| dock LIVE panel under MAIN panel                                  |
//+------------------------------------------------------------------+
void DockLivePanel(void)
  {
   if(g_compatible_tf && g_trade.HasAny())
      g_live.Move(g_main.X(), g_main.Y() + g_main.Height() + g_live_gap);
  }

//+------------------------------------------------------------------+
//| full UI refresh                                                   |
//+------------------------------------------------------------------+
void UpdateUI(void)
  {
   UpdateMainPanel();
   UpdateLivePanel();
   DockLivePanel();
  }

//+------------------------------------------------------------------+
//| initialization                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- timeframe compatibility (owner rule)
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
   g_compatible_tf = (tf == PERIOD_M5 || tf == PERIOD_M15 || tf == PERIOD_M30);

   //--- row layouts (separators match the reference screenshot)
   bool main_sep[13];
   for(int i = 0; i < 13; i++) main_sep[i] = false;
   main_sep[0] = true;  // under title
   main_sep[1] = true;  // under bid/ask
   main_sep[2] = true;  // under regime
   main_sep[4] = true;  // under evidence
   main_sep[8] = true;  // under risk:reward
   main_sep[9] = true;  // under session
   main_sep[10] = true; // under status

   bool live_sep[10];
   for(int i = 0; i < 10; i++) live_sep[i] = false;
   live_sep[0] = true;  // under LIVE TRADING header
   live_sep[2] = true;  // under mark-to-market
   live_sep[5] = true;  // under trail stop
   live_sep[8] = true;  // under TP3

   if(!g_main.Create(0, 0, "ATR_M_", 13, main_sep, 15, 15))
     {
      Print("Autotrader: failed to create MAIN panel");
      return INIT_FAILED;
     }
   g_main.SetSignalRow(3);   // SIGNAL row alone at 14pt (all else 12pt)
   if(!g_live.Create(0, 0, "ATR_L_", 10, live_sep, 15, 15))
     {
      Print("Autotrader: failed to create LIVE panel");
      return INIT_FAILED;
     }
   g_live.SetVisible(false);

   //--- drag support
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);

   if(!g_compatible_tf)
     {
      UpdateUI();
      EventSetTimer(1);
      Print("Autotrader: incompatible chart timeframe - attach to M5, M15 or M30");
      return INIT_SUCCEEDED;
     }

   //--- Phase 2: study this symbol first (the dials feed everything else)
   g_symbol.Refresh(_Symbol, tf);
   g_last_profile = TimeCurrent();

   //--- Phase 3: the judge, on all three timeframes at once
   g_dir.Setup(_Symbol, tf);

   //--- Phase 4/6: the trade manager (magic derived, never an input)
   g_magic = DeriveMagic();
   g_trade.Init(_Symbol, g_magic, 20, g_symbol, InpTrailStop, InpSL);
   g_had_trade = g_trade.HasAny();
   g_had_position = g_trade.HasPosition();

   //--- Phase 5: safety, Phase 6: scoreboard
   g_safety.Init();
   g_stats.Init(_Symbol, g_magic, TFName());

   //--- first full pass, then the heartbeat
   RunBrains(true);
   ManageTrades();
   UpdateUI();

   //--- honest warning until Phase 7 has proven the numbers
   long acct_mode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(acct_mode != ACCOUNT_TRADE_MODE_DEMO)
      Print("Autotrader: WARNING - this is NOT a demo account. Phase 7 ",
            "validation (Strategy Tester + walk-forward + demo forward) is ",
            "not finished yet, so execution performance is still unvalidated. ",
            "Consider running this on demo first.");

   Print("Autotrader V1.0 ready | ", _Symbol, " ", TFName(),
         " | lane ", g_dir.LaneName(),
         " | magic ", IntegerToString((long)g_magic),
         " | ", g_symbol.ClassLabel(), " profile, threshold ",
         IntegerToString(g_dir.Threshold()), "%",
         " | auto trading ", (InpAutoTrading ? "ON" : "OFF"),
         " | TrailStop ", (InpTrailStop ? "ON" : "OFF"),
         " | initial SL ", (InpSL ? "ON" : "OFF"),
         " | account ", (acct_mode == ACCOUNT_TRADE_MODE_DEMO ? "demo" : "LIVE"));
   g_stats.Log("INIT", StringFormat("lane %s magic %d threshold %d account %s auto %s trail %s initial_sl %s",
                                     g_dir.LaneName(), (int)g_magic,
                                     g_dir.Threshold(),
                                     (acct_mode == ACCOUNT_TRADE_MODE_DEMO ? "demo" : "live"),
                                     (InpAutoTrading ? "on" : "off"),
                                     (InpTrailStop ? "on" : "off"),
                                     (InpSL ? "on" : "off")));

   if(!InpSL)
      Print("Autotrader: initial SL is OFF. New entries have no broker-side stop ",
            (InpTrailStop ? "until profit protection is accepted." :
                            "and trailing/TP1 stop protection is also OFF."));

   EventSetTimer(1);   // 1-second heartbeat
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| deinitialization                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_compatible_tf)
      g_stats.Log("DEINIT", "EA removed/reinitialised, reason " + IntegerToString(reason));
   g_main.Destroy();
   g_live.Destroy();
   ChartSetInteger(0, CHART_MOUSE_SCROLL, true);   // restore chart scroll
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| tick: manage open trades, keep the panel honest                   |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(g_compatible_tf)
     {
      RunBrains(false);
      ManageTrades();          // ladder + break-even need every tick
      CheckTradeFinished();
     }
   UpdateUI();
  }

//+------------------------------------------------------------------+
//| timer: heartbeat, new-bar work, scoreboard                        |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(g_compatible_tf)
     {
      RunBrains(false);
      ManageTrades();
      CheckTradeFinished();

      //--- once per closed lane bar: gap shock check + the audit line
      datetime lane_bar = g_dir.LaneBarTime();
      if(lane_bar != 0 && lane_bar != g_last_gap_bar)
        {
         g_last_gap_bar = lane_bar;
         CheckGapOnNewBar();     // Phase 5
         AuditOnNewBar();        // Phase 3
        }
      g_stats.Scan(false);       // Phase 6: scoreboard (throttled inside)
      g_safety.SetDayRealized(g_stats.NetToday());
     }
   UpdateUI();
  }

//+------------------------------------------------------------------+
//| trade events: keep the scoreboard and the states in step          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!g_compatible_tf)
      return;
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD ||
      trans.type == TRADE_TRANSACTION_POSITION ||
      trans.type == TRADE_TRANSACTION_ORDER_ADD ||
      trans.type == TRADE_TRANSACTION_ORDER_UPDATE ||
      trans.type == TRADE_TRANSACTION_ORDER_DELETE ||
      trans.type == TRADE_TRANSACTION_HISTORY_ADD)
     {
      g_trade.Sync();
      g_stats.Scan(true);
      g_safety.SetDayRealized(g_stats.NetToday());
      CheckTradeFinished();
      UpdateUI();
     }
  }

//+------------------------------------------------------------------+
//| chart events: drag panels by their headers                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   //--- MAIN header drag: move the whole unit
   if(g_main.HandleEvent(id, lparam, dparam, sparam))
     {
      DockLivePanel();
      return;
     }

   //--- LIVE header drag: move the whole unit too (compute the delta)
   bool live_visible = (g_compatible_tf && g_trade.HasAny());
   int lx = g_live.X();
   int ly = g_live.Y();
   if(live_visible && g_live.HandleEvent(id, lparam, dparam, sparam))
     {
      int dx = g_live.X() - lx;
      int dy = g_live.Y() - ly;
      g_main.Move(g_main.X() + dx, g_main.Y() + dy);
      DockLivePanel();
      return;
     }

   if(id == CHARTEVENT_CHART_CHANGE)
     {
      //--- the chart was resized or its context changed: re-study now
      g_symbol.Refresh(_Symbol, (ENUM_TIMEFRAMES)Period());
      g_last_profile = TimeCurrent();
      RunBrains(true);
      UpdateUI();
     }
  }
//+------------------------------------------------------------------+
