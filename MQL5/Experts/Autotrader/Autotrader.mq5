//+------------------------------------------------------------------+
//| Autotrader.mq5                                                    |
//| Autotrader - fully automatic MT5 trading EA.                      |
//| Phase 1: interface (MAIN + LIVE TRADING panels) - soft eye-       |
//|          friendly look, drag by title bar, auto-size, live quotes, |
//|          preview states.                                           |
//| Phase 2: Symbol Intelligence + Regime engine (live, see below).    |
//| Phase 3+: direction engine, trading.                               |
//+------------------------------------------------------------------+
#property copyright "Autotrader"
#property version   "1.00"
#property description "Autotrader - automated MT5 trading EA (Phase 2: symbol intelligence + regime engine)"

#include <Autotrader/Panel.mqh>
#include <Autotrader/SymbolIntelligence.mqh>
#include <Autotrader/RegimeEngine.mqh>

//--- the only user input (owner decision)
input bool InpAutoTrading = true; // Auto Trading

//--- panels
CInfoPanel g_main;                       // MAIN panel (signal view)
CInfoPanel g_live;                       // LIVE TRADING panel (open order)
bool       g_compatible_tf = true;       // chart TF is M5 / M15 / M30
int        g_timer_ticks   = 0;          // preview cycle timer
int        g_state         = 0;          // 0=BUY 1=HOLD 2=SELL (preview)
datetime   g_state_started;              // when current preview state began
double     g_entry, g_sl, g_tp, g_lots;  // sample signal values
int        g_confidence    = 0;
int        g_live_gap      = 10;         // px between MAIN and LIVE panels

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

//--- estimated money for a price move, sample lot 0.10
double EstUsd(const double price_diff, const double lots)
  {
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0.0)
      return 0.0;
   return price_diff / tick_size * tick_value * lots;
  }

string ConfLabel(const int conf)
  {
   if(conf >= 90) return "Prime";
   if(conf >= 75) return "Strong";
   if(conf >= 60) return "Confident";
   if(conf >= 40) return "Neutral";
   return "Weak";
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

//--- expected duration text per chart TF (info only)
string ExpectedDuration(void)
  {
   switch((ENUM_TIMEFRAMES)Period())
     {
      case PERIOD_M5:  return "~1-4 hours";
      case PERIOD_M15: return "~2-8 hours";
      case PERIOD_M30: return "~5-16 hours";
      default:         return "~-";
     }
  }

//--- session name from server time (info only - never blocks trading)
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
   if(dt.min < 10)  mm = "0" + mm;
   return hh + ":" + mm;
  }

string HmNow(void)
  {
   return HmOf(TimeCurrent());
  }

//--- average bar range in price units (volatility proxy for sample numbers)
double AvgRangePrice(void)
  {
   MqlRates rates[];
   int n = CopyRates(_Symbol, (ENUM_TIMEFRAMES)Period(), 1, 30, rates);
   if(n <= 0)
      return 100 * _Point;
   double sum = 0.0;
   for(int i = 0; i < n; i++)
      sum += (rates[i].high - rates[i].low);
   double avg = sum / n;
   return (avg > 0 ? avg : 100 * _Point);
  }

//+------------------------------------------------------------------+
//| Phase 2 engines: study the symbol + classify the regime.          |
//| Refreshed on a timer (history copies are too heavy for every      |
//| tick); the panel quotes themselves still update every tick.       |
//+------------------------------------------------------------------+
void RefreshEngines(const bool force)
  {
   datetime now = TimeCurrent();
   if(!force && g_engines_at > 0 && now - g_engines_at < 5)
      return;
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
   g_symbol.Refresh(_Symbol, tf);
   g_regime.Refresh(_Symbol, tf);
   g_engines_at = now;
  }

//+------------------------------------------------------------------+
//| build one preview signal (sample values - real direction engine   |
//| arrives in Phase 3; distances already use the Phase 2 profile:    |
//| the symbol's own typical wiggle x its auto-set dials)             |
//+------------------------------------------------------------------+
void BuildSampleSignal(void)
  {
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double range = (g_symbol.Ready() && g_symbol.AtrPrice() > 0.0)
                  ? g_symbol.AtrPrice() : AvgRangePrice();
   double sl_mult = (g_symbol.Ready()) ? g_symbol.SlMult() : 1.60;
   double tp_mult = (g_symbol.Ready()) ? g_symbol.TpMult() : 3.50;
   g_lots = 0.10;

   if(g_state == 1) // HOLD
     {
      g_confidence = 54;
      g_entry = g_sl = g_tp = 0.0;
      return;
     }

   if(g_state == 0) // BUY
     {
      g_confidence = 91;
      g_entry = bid - 0.80 * range;
      g_sl    = g_entry - sl_mult * range;
      g_tp    = g_entry + tp_mult * range;
     }
   else               // SELL
     {
      g_confidence = 84;
      g_entry = bid + 0.80 * range;
      g_sl    = g_entry + sl_mult * range;
      g_tp    = g_entry - tp_mult * range;
     }
  }

//+------------------------------------------------------------------+
//| update MAIN panel rows                                            |
//+------------------------------------------------------------------+
void UpdateMainPanel(void)
  {
   string dashes = "----------";

   //--- title row (row 0)
   string auto = (InpAutoTrading &&
                  (bool)MQLInfoInteger(MQL_TRADE_ALLOWED) &&
                  (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) ? "ON" : "OFF";
   g_main.SetTitle("Autotrader V1.0 | " + _Symbol + " | TF: " + TFName() +
                   " | Auto Trading: " + auto);

   if(!g_compatible_tf)
     {
      //--- owner rule: labels only, no data, status names the problem.
      //--- Colour rule: only SIGNAL and STATUS may be coloured - every
      //--- other row uses the one soft CLR_TEXT, here and everywhere.
      g_main.SetRow(1,  "Bid: " + dashes + " | Ask: " + dashes + " | Spread: " + dashes, CLR_TEXT);
      g_main.SetRow(2,  "Regime: " + dashes, CLR_TEXT);
      g_main.SetRow(3,  "SIGNAL: " + dashes, CLR_DIM);
      g_main.SetRow(4,  "Confidence: " + dashes, CLR_TEXT);
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
   long   spread = (long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_main.SetRow(1, "Bid: " + FmtPrice(bid) + " | Ask: " + FmtPrice(ask) +
                    " | Spread: " + IntegerToString(spread) + " pts", CLR_TEXT);

   //--- regime: REAL since Phase 2 (expanded, specific labels agreed
   //--- with the owner - direction + strength, or where price sits in
   //--- the range). Plain soft text: only SIGNAL/STATUS are coloured.
   g_main.SetRow(2, "Regime: " + g_regime.Display(), CLR_TEXT);

   //--- signal + confidence
   string sig_txt;
   color  sig_clr;
   if(g_state == 0)      { sig_txt = "SIGNAL: " + GLYPH_UP + " BUY";   sig_clr = CLR_GREEN; }
   else if(g_state == 2) { sig_txt = "SIGNAL: " + GLYPH_DOWN + " SELL"; sig_clr = CLR_RED;   }
   else                  { sig_txt = "SIGNAL: " + GLYPH_DASH + " HOLD"; sig_clr = CLR_DIM;   }
   g_main.SetRow(3, sig_txt, sig_clr);
   g_main.SetRow(4, "Confidence: " + IntegerToString(g_confidence) + "% " +
                    GLYPH_DASH + " " + ConfLabel(g_confidence), CLR_TEXT);

   if(g_state == 1) // HOLD: no price plan rows
     {
      g_main.SetRow(5, "Entry: " + GLYPH_DASH, CLR_TEXT);
      g_main.SetRow(6, "Stop Loss: " + GLYPH_DASH, CLR_TEXT);
      g_main.SetRow(7, "Take Profit: " + GLYPH_DASH, CLR_TEXT);
      g_main.SetRow(8, "Risk:Reward: " + GLYPH_DASH, CLR_TEXT);
     }
   else
     {
      double gap    = g_entry - bid;
      double gap_usd = EstUsd(gap, g_lots);
      g_main.SetRow(5, "Entry: " + FmtPrice(g_entry) + " / gap est. " + FmtUsd(gap_usd) +
                       " (" + FmtPts(gap) + " away)", CLR_TEXT);

      double sl_diff = g_sl - g_entry;
      g_main.SetRow(6, "Stop Loss: " + FmtPrice(g_sl) + " / est. " +
                       FmtUsd(EstUsd(sl_diff, g_lots)) + " (" + FmtPts(sl_diff) + ")", CLR_TEXT);

      double tp_diff = g_tp - g_entry;
      g_main.SetRow(7, "Take Profit: " + FmtPrice(g_tp) + " / est. " +
                       FmtUsd(EstUsd(tp_diff, g_lots)) + " (" + FmtPts(tp_diff) + ")", CLR_TEXT);

      double rr = MathAbs(tp_diff) / MathMax(MathAbs(sl_diff), _Point);
      g_main.SetRow(8, "Risk:Reward 1:" + DoubleToString(rr, 1), CLR_TEXT);
     }

   //--- session (info only - never blocks)
   g_main.SetRow(9, "Session: " + SessionName() + " | Expected Duration: " +
                    ExpectedDuration(), CLR_TEXT);

   //--- status (coloured row): Phase 2 state in plain words
   if(!g_symbol.Ready() || !g_regime.Ready())
      g_main.SetRow(10, "STATUS: Calibrating - studying this symbol, collecting price history", CLR_ORANGE);
   else
      g_main.SetRow(10, "STATUS: Phase 2 live - " + g_symbol.ClassLabel() +
                        " profile ready, regime live; signals still preview (Phase 3)", CLR_ORANGE);

   //--- counters (owner rule: Win = closed positive, Loss = closed negative, BE = zero)
   g_main.SetRow(11, "Today: Num of Signal: 0, Win: 0, Loss: 0, BE: 0", CLR_TEXT);
   g_main.SetRow(12, "All Time: Num of Signal: 0, Win: 0, Loss: 0, BE: 0", CLR_TEXT);

   g_main.Layout();
  }

//+------------------------------------------------------------------+
//| update LIVE TRADING panel rows (visible only while "order" open)   |
//+------------------------------------------------------------------+
void UpdateLivePanel(void)
  {
   //--- visible only in preview trade states (BUY / SELL)
   bool visible = (g_compatible_tf && g_state != 1);
   g_live.SetVisible(visible);
   if(!visible)
      return;

   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    t     = (int)(TimeCurrent() - g_state_started);   // seconds in state
   double tp1   = g_entry + 0.60 * (g_tp - g_entry);
   double tp2   = g_entry + 0.80 * (g_tp - g_entry);
   double tp3   = g_tp;
   string dir   = (g_state == 0) ? "BUY" : "SELL";

   g_live.SetTitle("LIVE TRADING");
   g_live.SetRow(1, "Order #100001 (sample) | " + dir + " " + DoubleToString(g_lots, 2) +
                    " lot | opened " + HmOf(g_state_started), CLR_TEXT);

   double fl = EstUsd(bid - g_entry, g_lots);
   if(g_state == 2)
      fl = EstUsd(g_entry - bid, g_lots);
   g_live.SetRow(2, "Entry: " + FmtPrice(g_entry) + " " + ShortToString(0x2192) + " Now: " +
                    FmtPrice(bid) + "  (floating " + FmtUsd(fl) + ")", CLR_TEXT);

   //--- Stop Loss row (owner asked for it) - shows the SL journey.
   //--- Plain soft text: only SIGNAL/STATUS rows carry colour.
   if(t < 6)
     {
      g_live.SetRow(3, "Stop Loss : " + FmtPrice(g_sl) + "  (initial)", CLR_TEXT);
      g_live.SetRow(4, "Break-Even: not armed", CLR_TEXT);
     }
   else
     {
      g_live.SetRow(3, "Stop Loss : " + FmtPrice(g_entry) +
                       "  (started " + FmtPrice(g_sl) + " " + ShortToString(0x2192) +
                       " moved to Entry)", CLR_TEXT);
      string be = "LOCKED";
      if(t < 8)
         be = "ARMED";
      g_live.SetRow(4, "Break-Even: " + be, CLR_TEXT);
     }
   g_live.SetRow(5, "Trail Stop: OFF (later phase)", CLR_TEXT);

   //--- TP ladder rows (owner's 60 / 80 / 100 idea)
   double prog = 0.0;
   double full = MathMax(MathAbs(tp1 - g_entry), _Point);
   prog = MathAbs(bid - g_entry) / full * 100.0;
   prog = MathMax(0.0, MathMin(99.0, prog));

   if(t < 12)
      g_live.SetRow(6, "TP1 " + FmtPrice(tp1) + " (60%) : pending - " +
                       DoubleToString(prog, 0) + "% progress to target", CLR_TEXT);
   else
      g_live.SetRow(6, "TP1 " + FmtPrice(tp1) + " (60%) : " + GLYPH_CHECK +
                       " HIT - closed 50% of lot", CLR_TEXT);

   if(t < 16)
      g_live.SetRow(7, "TP2 " + FmtPrice(tp2) + " (80%) : pending", CLR_TEXT);
   else
      g_live.SetRow(7, "TP2 " + FmtPrice(tp2) + " (80%) : " + GLYPH_CHECK +
                       " HIT - closed 30% of lot", CLR_TEXT);

   if(t < 19)
      g_live.SetRow(8, "TP3 " + FmtPrice(tp3) + " (100%): pending", CLR_TEXT);
   else
      g_live.SetRow(8, "TP3 " + FmtPrice(tp3) + " (100%): " + GLYPH_CHECK +
                       " HIT - closed 20% of lot", CLR_TEXT);

   string st;
   if(t < 6)       st = "STATUS: Managing - running to TP1";
   else if(t < 12) st = "STATUS: Managing - running to TP2";
   else if(t < 16) st = "STATUS: Managing - running to TP3";
   else            st = "STATUS: Managing - ladder complete";
   g_live.SetRow(9, st, CLR_ORANGE);   // STATUS row: coloured by design

   g_live.Layout();
  }

//+------------------------------------------------------------------+
//| dock LIVE panel under MAIN panel                                  |
//+------------------------------------------------------------------+
void DockLivePanel(void)
  {
   if(g_compatible_tf && g_state != 1)
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
   main_sep[4] = true;  // under confidence
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

   //--- enable mouse-move events for dragging
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);

   g_state_started = TimeCurrent();
   RefreshEngines(true);   // Phase 2: profile this symbol + first regime read
   BuildSampleSignal();
   UpdateUI();

   EventSetTimer(1);   // 1-second UI heartbeat
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| deinitialization                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_main.Destroy();
   g_live.Destroy();
   ChartSetInteger(0, CHART_MOUSE_SCROLL, true);   // restore chart scroll
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| tick: keep quotes fresh                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateUI();
  }

//+------------------------------------------------------------------+
//| timer: preview state cycle + UI heartbeat                         |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_timer_ticks++;
   RefreshEngines(false);   // Phase 2: keep profile + regime current (5s)
   //--- cycle sample states every 20s so the owner can see
   //    BUY -> HOLD -> SELL -> ... on the panel (preview only, Phase 3
   //    replaces these samples with the real direction engine)
   if(g_timer_ticks % 20 == 0)
     {
      g_state = (g_state + 1) % 3;
      g_state_started = TimeCurrent();
      BuildSampleSignal();
     }
   UpdateUI();
  }

//+------------------------------------------------------------------+
//| chart events: drag panels by their headers                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   //--- MAIN header drag: move whole unit
   if(g_main.HandleEvent(id, lparam, dparam, sparam))
     {
      DockLivePanel();
      return;
     }

   //--- LIVE header drag: move whole unit too (compute delta).
   //    Only when the LIVE panel is actually visible (it is hidden during HOLD).
   bool live_visible = (g_compatible_tf && g_state != 1);
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
      RefreshEngines(true);   // new TF/symbol context: re-study at once
      BuildSampleSignal();
      UpdateUI();
     }
  }
//+------------------------------------------------------------------+
