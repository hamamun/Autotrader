//+------------------------------------------------------------------+
//| TradeEngine.mqh                                                   |
//| Autotrader Phase 4 + 6 + 8 - the trade manager.                   |
//|                                                                   |
//| What it does, in plain words:                                     |
//|  * sizes the lot from the account's own equity and the 1% risk    |
//|    dial - never a fixed lot, never a guess;                       |
//|  * sends the order with a HARD broker-side stop loss on every     |
//|    single trade (PLAN: never trade without one) plus the broker-  |
//|    side TP3, so the trade stays protected even if this EA dies;   |
//|  * walks the owner's ladder: TP1 60% -> close 50% of the lot,     |
//|    TP2 80% -> close 30%, TP3 100% -> close the rest;              |
//|  * adapts a non-loss trailing stop to timeframe, market state,    |
//|    price structure and changing directional evidence;            |
//|  * never moves a profit-protecting stop back toward a loss;        |
//|  * closes for time when a trade simply stalls;                    |
//|  * repairs protection that went missing;                          |
//|  * rebuilds all of the above from the broker's own position data  |
//|    after a restart, a reconnection or a re-attach (Phase 5).      |
//|                                                                   |
//| Pure MQL5 + the standard CTrade helper. No DLL, no Python.        |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_TRADE_ENGINE_MQH
#define AUTOTRADER_TRADE_ENGINE_MQH

#include <Trade/Trade.mqh>

#define ATTE_MAX_STATES 4
#define ATTE_MAX_RETRY  3

#define ATTE_TRAIL_WAITING    0
#define ATTE_TRAIL_PROTECTED  1
#define ATTE_TRAIL_FOLLOWING  2

//--- A read-only snapshot from the direction/regime engines. Trade
//--- management owns the stop; the signal engine only supplies context.
struct SATTrailContext
  {
   bool     ready;
   int      lane_minutes;       // 5 / 15 / 30
   datetime bar_time;           // closed lane bar; score slope updates once per bar
   double   atr;                 // current typical move, price units
   double   atr_ratio;           // current ATR / its longer-run normal
   double   efficiency;          // 0..1, straightness of price movement
   int      sign_changes;        // recent candle direction flips
   bool     trend;
   bool     pullback;
   bool     range_extreme;
   bool     range_middle;
   bool     volatile_state;
   bool     quiet_state;
   bool     transition_state;
   int      lane_direction;      // +1 / -1 / 0
   int      m15_direction;       // higher-timeframe alignment
   int      m30_direction;       // higher-timeframe alignment
   int      buy_score;            // evidence index, not probability
   int      sell_score;
   int      choch_direction;     // recent possible change of character
   int      bars_since_choch;
   int      swing_direction;
   double   swing_high;
   double   swing_low;
   int      swing_high_bar;
   int      swing_low_bar;
  };

struct SATTradeState
  {
   ulong    ticket;
   bool     active;
   bool     is_pending;        // still a limit order, not a position yet
   int      dir;               // +1 buy, -1 sell
   double   entry;             // position open price / limit price
   double   sl_initial;
   double   sl_now;
   double   tp1, tp2, tp3;
   double   v0;                // volume when the trade started
   double   v_now;
   bool     tp1_hit, tp2_hit, tp3_hit;
   datetime tp1_time;
   bool     be_armed, be_locked;
   bool     trail_armed;
   int      trail_stage;         // waiting / non-loss floor / following price
   double   trail_best;          // highest BUY / lowest SELL price seen
   double   trail_arm_r;         // adaptive activation threshold, in initial-risk units
   double   trail_gap;           // current adaptive gap, price units
   double   trail_cost_buffer;   // conservative break-even-plus-cost distance
   datetime trail_bar_time;      // last closed lane bar used for confidence slope
   int      trail_last_score;
   int      trail_score_delta;
   int      trail_updates;
   string   trail_reason;
   datetime opened;
   int      expected_seconds;  // expected position duration
   int      pending_ttl_seconds; // pending entry freshness window
   string   action;            // what the manager last did (panel STATUS)
  };

class CTradeEngine
  {
public:
   CTrade         trade;
   SATTradeState  st[ATTE_MAX_STATES];

private:
   string   m_symbol;
   ulong    m_magic;
   int      m_digits;
   double   m_point;
   ulong    m_deviation;
   double   m_vmin, m_vmax, m_vstep;
   double   m_tick_size, m_tick_value;
   double   m_stops_price;
   double   m_freeze_price;
   string   m_last_error;
   datetime m_last_protect_try;   // repairs are attempted at most every 5s
   datetime m_last_trail_modify;  // avoid repeated broker requests at one quote
   //--- what we are about to open, so the new state is exact and not guessed
   bool     m_expect_new;
   int      m_expect_dir;
   double   m_expect_entry, m_expect_sl, m_expect_tp1, m_expect_tp2, m_expect_tp3;
   int      m_expect_seconds;
   int      m_expect_pending_ttl;
   string   m_last_pending_event;

   int      FindState(const ulong ticket) const;
   int      PendingLifetimeSeconds(const int expected_seconds) const;
   int      FreeSlot(void) const;
   void     DropState(const int idx);
   bool     AddStateFromBroker(const ulong ticket);
   void     UpdateStateFromBroker(const int idx);
   bool     EnsureProtection(const int idx);
   bool     PartialClose(const int idx, const double fraction, const string why);
   bool     MoveStopTo(const int idx, const double new_sl, const string why);
   double   NormStopPrice(const double price, const int dir) const;
   string   StateKey(const ulong ticket, const string suffix) const;
   void     SaveState(const int idx);
   void     RestoreState(const int idx);
   void     DeleteState(const int idx);
   void     UpdateTrailContext(const int idx, const SATTrailContext &ctx);
   double   TrailArmThreshold(const int idx, const SATTrailContext &ctx) const;
   double   TrailDistance(const int idx, const SATTrailContext &ctx) const;
   double   BreakEvenFloor(const int idx);
   double   EstimateRoundTurnCostPrice(const int idx);
   bool     TrailCanImprove(const int idx, const double sl,
                            const double bid, const double ask) const;
   void     ManageTrailingStop(const int idx, const SATTrailContext &ctx,
                               const double mark, const double bid,
                               const double ask);

public:
            CTradeEngine(void);
   bool     Init(const string symbol, const ulong magic, const ulong deviation_pts,
                 CSymbolIntelligence &profile);
   void     Sync(void);                       // positions + pending orders
   double   CalcLots(const double sl_dist, const double risk_pct, const double atr);
   double   NormVolume(const double v) const;
   double   NormPrice(const double p) const;
   bool     Open(const int dir, const bool use_limit, const double entry,
                 const double sl, const double tp1, const double tp2, const double tp3,
                 const int expected_seconds, const double risk_pct, const double atr);
   bool     Manage(const SATTrailContext &ctx); // true when a pending order expires
   void     SetExpectedDefault(const int seconds);
   bool     ClosePosition(const int idx, const string why);
   bool     CancelPending(const string why);
   string   LastPendingEvent(void) const { return m_last_pending_event; }

   //--- panel getters
   int      MainIdx(void) const;
   bool     HasPosition(void) const;
   bool     HasPending(void) const;
   bool     HasAny(void) const;
   string   LastError(void) const { return m_last_error; }
   double   FloatingUsd(const int idx) const;
   double   TpProgress(const int idx) const;
   string   BeStateText(const int idx) const;
   string   SlJourneyText(const int idx) const;
   string   TrailStatusText(const int idx) const;
  };

//+------------------------------------------------------------------+
CTradeEngine::CTradeEngine(void)
  {
   m_symbol = "";
   m_magic = 0;
   m_digits = 2;
   m_point = 0.01;
   m_deviation = 20;
   m_vmin = 0.01; m_vmax = 100.0; m_vstep = 0.01;
   m_tick_size = 0.0; m_tick_value = 0.0;
   m_stops_price = 0.0;
   m_freeze_price = 0.0;
   m_last_error = "";
   m_last_protect_try = 0;
   m_last_trail_modify = 0;
   m_expect_new = false;
   m_expect_dir = 0;
   m_expect_entry = 0.0; m_expect_sl = 0.0;
   m_expect_tp1 = 0.0; m_expect_tp2 = 0.0; m_expect_tp3 = 0.0;
   m_expect_seconds = 0;
   m_expect_pending_ttl = 0;
   m_last_pending_event = "";
   for(int i = 0; i < ATTE_MAX_STATES; i++)
     {
      st[i].ticket = 0;
      st[i].active = false;
      st[i].is_pending = false;
      st[i].dir = 0;
      st[i].entry = 0.0;
      st[i].sl_initial = 0.0;
      st[i].sl_now = 0.0;
      st[i].tp1 = 0.0; st[i].tp2 = 0.0; st[i].tp3 = 0.0;
      st[i].v0 = 0.0; st[i].v_now = 0.0;
      st[i].tp1_hit = false; st[i].tp2_hit = false; st[i].tp3_hit = false;
      st[i].tp1_time = 0;
      st[i].be_armed = false; st[i].be_locked = false;
      st[i].trail_armed = false;
      st[i].trail_stage = ATTE_TRAIL_WAITING;
      st[i].trail_best = 0.0;
      st[i].trail_arm_r = 0.0;
      st[i].trail_gap = 0.0;
      st[i].trail_cost_buffer = -1.0;
      st[i].trail_bar_time = 0;
      st[i].trail_last_score = 0;
      st[i].trail_score_delta = 0;
      st[i].trail_updates = 0;
      st[i].trail_reason = "waiting for profit";
      st[i].opened = 0;
      st[i].expected_seconds = 0;
      st[i].pending_ttl_seconds = 0;
      st[i].action = "";
     }
  }

//+------------------------------------------------------------------+
int CTradeEngine::PendingLifetimeSeconds(const int expected_seconds) const
  {
   int bar_seconds = PeriodSeconds((ENUM_TIMEFRAMES)Period());
   int ttl = (bar_seconds > 0) ? bar_seconds * 3 : 600;
   if(expected_seconds > 0 && expected_seconds < ttl)
      ttl = expected_seconds;
   if(ttl < 600)
      ttl = 600;
   return ttl;
  }

//+------------------------------------------------------------------+
bool CTradeEngine::Init(const string symbol, const ulong magic,
                        const ulong deviation_pts, CSymbolIntelligence &profile)
  {
   m_symbol   = symbol;
   m_magic    = magic;
   m_digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   m_point    = SymbolInfoDouble(symbol, SYMBOL_POINT);
   m_deviation = deviation_pts;
   m_vmin     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   m_vmax     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   m_vstep    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   m_tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   m_tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   m_stops_price = profile.StopsLevelPrice();
   m_freeze_price = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL) * m_point;

   trade.SetExpertMagicNumber(magic);
   trade.SetDeviationInPoints(deviation_pts);

   //--- pick a filling mode this symbol actually accepts
   long fm = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fm & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   Sync();
   return true;
  }

//+------------------------------------------------------------------+
double CTradeEngine::NormPrice(const double p) const
  {
   return NormalizeDouble(p, m_digits);
  }

// BUY stops round up and SELL stops down, preserving the cost floor.
double CTradeEngine::NormStopPrice(const double price,const int dir) const
  {
   double step=(m_tick_size>0.0 ? m_tick_size : m_point);
   if(step<=0.0 || (dir!=1 && dir!=-1))
      return NormalizeDouble(price,m_digits);
   double units=price/step;
   double aligned=(dir==1 ? MathCeil(units-1e-10) : MathFloor(units+1e-10))*step;
   return NormalizeDouble(aligned,m_digits);
  }

double CTradeEngine::NormVolume(const double v) const
  {
   double step = (m_vstep > 0.0) ? m_vstep : 0.01;
   double lots = MathFloor(v / step + 0.5) * step;
   if(lots < m_vmin) lots = m_vmin;
   if(lots > m_vmax) lots = m_vmax;
   return NormalizeDouble(lots, 8);
  }

//+------------------------------------------------------------------+
//| Lot size from equity x risk% and the distance to the stop.        |
//| Returns 0 when the trade cannot be afforded properly.             |
//+------------------------------------------------------------------+
double CTradeEngine::CalcLots(const double sl_dist, const double risk_pct,
                              const double atr)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0 || sl_dist <= 0.0 || m_tick_size <= 0.0 || m_tick_value <= 0.0)
      return 0.0;

   double risk_money  = equity * risk_pct / 100.0;
   double loss_per_lot = sl_dist / m_tick_size * m_tick_value;
   if(loss_per_lot <= 0.0)
      return 0.0;

   double lots = risk_money / loss_per_lot;
   lots = NormVolume(lots);

   //--- the broker's smallest lot may already risk far more than 1%.
   //--- Allow up to 3x the dial (small accounts), refuse beyond that.
   double min_risk = m_vmin * loss_per_lot;
   if(lots <= m_vmin && min_risk > risk_money * 3.0)
     {
      m_last_error = StringFormat("account too small: minimum lot risks %.2f vs %.2f allowed",
                                  min_risk, risk_money);
      return 0.0;
     }

   //--- margin sanity: never use more than half the free margin
   double price = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double margin = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, m_symbol, lots, price, margin))
     {
      double free_m = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      while(margin > free_m * 0.50 && lots > m_vmin)
        {
         lots = NormVolume(lots - m_vstep);
         if(lots < m_vmin) { lots = m_vmin; break; }
         if(!OrderCalcMargin(ORDER_TYPE_BUY, m_symbol, lots, price, margin))
            break;
        }
      if(margin > free_m * 0.90)
        {
         m_last_error = "not enough free margin";
         return 0.0;
        }
     }
   return lots;
  }

//+------------------------------------------------------------------+
int CTradeEngine::FindState(const ulong ticket) const
  {
   for(int i = 0; i < ATTE_MAX_STATES; i++)
      if(st[i].active && st[i].ticket == ticket)
         return i;
   return -1;
  }

int CTradeEngine::FreeSlot(void) const
  {
   for(int i = 0; i < ATTE_MAX_STATES; i++)
      if(!st[i].active)
         return i;
   return -1;
  }

string CTradeEngine::StateKey(const ulong ticket,const string suffix) const
  {
   return "AT8_"+IntegerToString((long)m_magic)+"_"+
          IntegerToString((long)ticket)+"_"+suffix;
  }

void CTradeEngine::SaveState(const int idx)
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || !st[idx].active || st[idx].ticket==0)
      return;
   const ulong ticket=st[idx].ticket;
   GlobalVariableSet(StateKey(ticket,"V0"),st[idx].v0);
   GlobalVariableSet(StateKey(ticket,"ET"),(double)st[idx].expected_seconds);
   GlobalVariableSet(StateKey(ticket,"SL0"),st[idx].sl_initial);
   GlobalVariableSet(StateKey(ticket,"T1"),(st[idx].tp1_hit ? 1.0 : 0.0));
   GlobalVariableSet(StateKey(ticket,"T2"),(st[idx].tp2_hit ? 1.0 : 0.0));
   GlobalVariableSet(StateKey(ticket,"T3"),(st[idx].tp3_hit ? 1.0 : 0.0));
   GlobalVariableSet(StateKey(ticket,"T1T"),(double)st[idx].tp1_time);
   GlobalVariableSet(StateKey(ticket,"TRA"),(st[idx].trail_armed ? 1.0 : 0.0));
   GlobalVariableSet(StateKey(ticket,"TRS"),(double)st[idx].trail_stage);
   GlobalVariableSet(StateKey(ticket,"TRP"),st[idx].trail_best);
   GlobalVariableSet(StateKey(ticket,"TRSL"),st[idx].sl_now);
   GlobalVariableSet(StateKey(ticket,"TRR"),st[idx].trail_arm_r);
   GlobalVariableSet(StateKey(ticket,"TRG"),st[idx].trail_gap);
   GlobalVariableSet(StateKey(ticket,"TRC"),st[idx].trail_cost_buffer);
   GlobalVariableSet(StateKey(ticket,"TRB"),(double)st[idx].trail_bar_time);
   GlobalVariableSet(StateKey(ticket,"TRSCORE"),(double)st[idx].trail_last_score);
   GlobalVariableSet(StateKey(ticket,"TRDELTA"),(double)st[idx].trail_score_delta);
   GlobalVariableSet(StateKey(ticket,"TRU"),(double)st[idx].trail_updates);
  }

void CTradeEngine::RestoreState(const int idx)
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || !st[idx].active || st[idx].ticket==0)
      return;
   const ulong ticket=st[idx].ticket;
   string key=StateKey(ticket,"V0");
   if(GlobalVariableCheck(key)) st[idx].v0=GlobalVariableGet(key);
   key=StateKey(ticket,"ET");
   if(GlobalVariableCheck(key)) st[idx].expected_seconds=(int)GlobalVariableGet(key);
   key=StateKey(ticket,"SL0");
   if(GlobalVariableCheck(key)) st[idx].sl_initial=GlobalVariableGet(key);
   key=StateKey(ticket,"T1");
   if(GlobalVariableCheck(key)) st[idx].tp1_hit=(GlobalVariableGet(key)>0.5);
   key=StateKey(ticket,"T2");
   if(GlobalVariableCheck(key)) st[idx].tp2_hit=(GlobalVariableGet(key)>0.5);
   key=StateKey(ticket,"T3");
   if(GlobalVariableCheck(key)) st[idx].tp3_hit=(GlobalVariableGet(key)>0.5);
   key=StateKey(ticket,"T1T");
   if(GlobalVariableCheck(key)) st[idx].tp1_time=(datetime)GlobalVariableGet(key);
   key=StateKey(ticket,"TRA");
   if(GlobalVariableCheck(key)) st[idx].trail_armed=(GlobalVariableGet(key)>0.5);
   key=StateKey(ticket,"TRS");
   if(GlobalVariableCheck(key)) st[idx].trail_stage=(int)GlobalVariableGet(key);
   key=StateKey(ticket,"TRP");
   if(GlobalVariableCheck(key)) st[idx].trail_best=GlobalVariableGet(key);
   key=StateKey(ticket,"TRSL");
   if(GlobalVariableCheck(key))
     {
      double saved_sl=GlobalVariableGet(key);
      if(saved_sl>0.0 && st[idx].sl_now<=0.0)
         st[idx].sl_now=saved_sl;
      else if(saved_sl>0.0 && (st[idx].trail_armed || st[idx].tp1_hit))
        {
         if(st[idx].dir==1) st[idx].sl_now=MathMax(st[idx].sl_now,saved_sl);
         else               st[idx].sl_now=MathMin(st[idx].sl_now,saved_sl);
        }
     }
   key=StateKey(ticket,"TRR");
   if(GlobalVariableCheck(key)) st[idx].trail_arm_r=GlobalVariableGet(key);
   key=StateKey(ticket,"TRG");
   if(GlobalVariableCheck(key)) st[idx].trail_gap=GlobalVariableGet(key);
   key=StateKey(ticket,"TRC");
   if(GlobalVariableCheck(key)) st[idx].trail_cost_buffer=GlobalVariableGet(key);
   key=StateKey(ticket,"TRB");
   if(GlobalVariableCheck(key)) st[idx].trail_bar_time=(datetime)GlobalVariableGet(key);
   key=StateKey(ticket,"TRSCORE");
   if(GlobalVariableCheck(key)) st[idx].trail_last_score=(int)GlobalVariableGet(key);
   key=StateKey(ticket,"TRDELTA");
   if(GlobalVariableCheck(key)) st[idx].trail_score_delta=(int)GlobalVariableGet(key);
   key=StateKey(ticket,"TRU");
   if(GlobalVariableCheck(key)) st[idx].trail_updates=(int)GlobalVariableGet(key);
   if(st[idx].trail_armed && st[idx].trail_stage<ATTE_TRAIL_PROTECTED)
      st[idx].trail_stage=ATTE_TRAIL_PROTECTED;
  }

void CTradeEngine::DeleteState(const int idx)
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || st[idx].ticket==0)
      return;
   const ulong ticket=st[idx].ticket;
   string suffixes[18]={"V0","ET","SL0","T1","T2","T3","T1T","TRA",
                        "TRS","TRP","TRSL","TRR","TRG","TRC","TRB",
                        "TRSCORE","TRDELTA","TRU"};
   for(int i=0;i<ArraySize(suffixes);i++)
      GlobalVariableDel(StateKey(ticket,suffixes[i]));
  }

void CTradeEngine::DropState(const int idx)
  {
   if(idx < 0 || idx >= ATTE_MAX_STATES)
      return;
   DeleteState(idx);
   //--- forget the restore notes for this ticket
   GlobalVariableDel("ATRV0_" + IntegerToString((long)m_magic) + "_" +
                     IntegerToString((long)st[idx].ticket));
   GlobalVariableDel("ATRET_" + IntegerToString((long)m_magic) + "_" +
                     IntegerToString((long)st[idx].ticket));
   GlobalVariableDel("ATPE_" + IntegerToString((long)m_magic) + "_" +
                     IntegerToString((long)st[idx].ticket));
   st[idx].active = false;
   st[idx].ticket = 0;
   st[idx].action = "";
  }

//+------------------------------------------------------------------+
//| a ticket we have not seen: either we just opened it, or the EA    |
//| restarted and must restore the trade from the broker's data.      |
//+------------------------------------------------------------------+
bool CTradeEngine::AddStateFromBroker(const ulong ticket)
  {
   int idx = FreeSlot();
   if(idx < 0)
      return false;

   bool is_pos = PositionSelectByTicket(ticket);
   bool is_ord = false;
   if(!is_pos)
      is_ord = OrderSelect(ticket);
   if(!is_pos && !is_ord)
      return false;

   string sym = is_pos ? PositionGetString(POSITION_SYMBOL) : OrderGetString(ORDER_SYMBOL);
   if(sym != m_symbol)
      return false;

   //--- write straight into the slot (no structure copies: MQL5 keeps
   //--- this plain and portable)
   st[idx].ticket     = ticket;
   st[idx].active     = true;
   st[idx].is_pending = is_ord;
   st[idx].tp1_hit = false; st[idx].tp2_hit = false; st[idx].tp3_hit = false;
   st[idx].tp1_time = 0;
   st[idx].be_armed = false; st[idx].be_locked = false;
   st[idx].trail_armed = false;
   st[idx].trail_stage = ATTE_TRAIL_WAITING;
   st[idx].trail_best = 0.0;
   st[idx].trail_arm_r = 0.0;
   st[idx].trail_gap = 0.0;
   st[idx].trail_cost_buffer = -1.0;
   st[idx].trail_bar_time = 0;
   st[idx].trail_last_score = 0;
   st[idx].trail_score_delta = 0;
   st[idx].trail_updates = 0;
   st[idx].trail_reason = "waiting for profit";
   st[idx].action = "";
   st[idx].expected_seconds = 0;
   st[idx].pending_ttl_seconds = 0;

   if(is_pos)
     {
      st[idx].dir    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      st[idx].entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      st[idx].sl_now = PositionGetDouble(POSITION_SL);
      st[idx].tp3    = PositionGetDouble(POSITION_TP);
      st[idx].v_now  = PositionGetDouble(POSITION_VOLUME);
      st[idx].opened = (datetime)PositionGetInteger(POSITION_TIME);
     }
   else
     {
      long otype = OrderGetInteger(ORDER_TYPE);
      st[idx].dir    = (otype == ORDER_TYPE_BUY_LIMIT || otype == ORDER_TYPE_BUY_STOP) ? 1 : -1;
      st[idx].entry  = OrderGetDouble(ORDER_PRICE_OPEN);
      st[idx].sl_now = OrderGetDouble(ORDER_SL);   // ENUM_ORDER_PROPERTY_DOUBLE: pending stop loss
      st[idx].tp3    = OrderGetDouble(ORDER_TP);   // ENUM_ORDER_PROPERTY_DOUBLE: pending take profit
      st[idx].v_now  = OrderGetDouble(ORDER_VOLUME_CURRENT);
      st[idx].opened = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
     }
   st[idx].v0 = st[idx].v_now;
   st[idx].sl_initial = st[idx].sl_now;

   //--- the ladder follows from Entry and the broker-side TP (= TP3)
   double d = st[idx].tp3 - st[idx].entry;
   st[idx].tp1 = st[idx].entry + 0.60 * d;
   st[idx].tp2 = st[idx].entry + 0.80 * d;

   bool exact = false;
   if(m_expect_new && m_expect_dir == st[idx].dir &&
      TimeCurrent() - st[idx].opened < 180)
     {
      //--- we opened this ourselves a moment ago - keep the exact plan
      st[idx].entry      = m_expect_entry;
      st[idx].sl_initial = m_expect_sl;
      st[idx].sl_now     = m_expect_sl;
      st[idx].tp1        = m_expect_tp1;
      st[idx].tp2        = m_expect_tp2;
      st[idx].tp3        = m_expect_tp3;
      st[idx].expected_seconds = m_expect_seconds;
      st[idx].pending_ttl_seconds = m_expect_pending_ttl;
      st[idx].v0         = st[idx].v_now;
      exact = true;
      m_expect_new = false;
     }

   if(!exact)
     {
      //--- RESTORE after restart. New builds persist the TP flags and trail
      //--- state explicitly. The older keys remain supported for trades
      //--- opened by a pre-trailing build.
      string gv = "ATRV0_" + IntegerToString((long)m_magic) + "_" + IntegerToString((long)ticket);
      string ge = "ATRET_" + IntegerToString((long)m_magic) + "_" + IntegerToString((long)ticket);
      string gp = "ATPE_" + IntegerToString((long)m_magic) + "_" + IntegerToString((long)ticket);
      if(GlobalVariableCheck(gv)) st[idx].v0 = GlobalVariableGet(gv);
      if(GlobalVariableCheck(ge)) st[idx].expected_seconds = (int)GlobalVariableGet(ge);
      if(GlobalVariableCheck(gp)) st[idx].pending_ttl_seconds = (int)GlobalVariableGet(gp);

      bool saved_tp_state = GlobalVariableCheck(StateKey(ticket,"T1"));
      RestoreState(idx);
      bool sl_at_or_better =
         (st[idx].dir == 1 && st[idx].sl_now > 0.0 &&
          st[idx].sl_now >= st[idx].entry - m_point) ||
         (st[idx].dir == -1 && st[idx].sl_now > 0.0 &&
          st[idx].sl_now <= st[idx].entry + m_point);
      if(saved_tp_state)
        {
         // An early trail can move the stop to entry before TP1, so a stop
         // above/below entry must no longer be used to infer TP1 completion.
         st[idx].be_armed = (st[idx].tp1_hit || st[idx].trail_armed);
         st[idx].be_locked = sl_at_or_better;
         if(st[idx].v0 <= 0.0) st[idx].v0 = st[idx].v_now;
        }
      else if(sl_at_or_better)
        {
         // Legacy restore only: older versions could only move the stop to
         // entry after TP1, so the broker stop remains a valid clue.
         st[idx].be_armed  = true;
         st[idx].be_locked = true;
         st[idx].tp1_hit   = true;
         if(st[idx].v0 <= st[idx].v_now)
            st[idx].v0 = st[idx].v_now / 0.50;
        }
      else if(st[idx].v0 > 0.0 && st[idx].v_now > 0.0)
        {
         double ratio = st[idx].v_now / st[idx].v0;
         if(ratio <= 0.25)      { st[idx].tp1_hit = true; st[idx].tp2_hit = true; }
         else if(ratio <= 0.55) { st[idx].tp1_hit = true; st[idx].be_armed = true; }
        }

      if(st[idx].trail_best <= 0.0 && !st[idx].is_pending)
        {
         double bid_now=SymbolInfoDouble(m_symbol,SYMBOL_BID);
         double ask_now=SymbolInfoDouble(m_symbol,SYMBOL_ASK);
         st[idx].trail_best=(st[idx].dir==1 ? bid_now : ask_now);
        }
      if(st[idx].tp3 <= 0.0)
        {
         //--- somebody removed the target: manage the stop only and say so
         st[idx].tp1 = 0.0;
         st[idx].tp2 = 0.0;
         st[idx].action = "target missing - stop protection only";
         Print("Autotrader: restored ticket ", ticket,
               " has no broker TP - managing the stop only");
        }
      else if(st[idx].action == "")
         st[idx].action = "restored after restart";
     }

   //--- keep the legacy keys readable, while the full state uses AT8 keys
   GlobalVariableSet("ATRV0_" + IntegerToString((long)m_magic) + "_" +
                     IntegerToString((long)ticket), st[idx].v0);
   if(st[idx].expected_seconds > 0)
      GlobalVariableSet("ATRET_" + IntegerToString((long)m_magic) + "_" +
                        IntegerToString((long)ticket), (double)st[idx].expected_seconds);
   if(st[idx].is_pending && st[idx].pending_ttl_seconds > 0)
      GlobalVariableSet("ATPE_" + IntegerToString((long)m_magic) + "_" +
                        IntegerToString((long)ticket), (double)st[idx].pending_ttl_seconds);

   if(exact)
     {
      st[idx].action = "opened";
      if(!st[idx].is_pending)
        {
         double bid_now=SymbolInfoDouble(m_symbol,SYMBOL_BID);
         double ask_now=SymbolInfoDouble(m_symbol,SYMBOL_ASK);
         st[idx].trail_best=(st[idx].dir==1 ? bid_now : ask_now);
        }
     }
   SaveState(idx);
   return true;
  }

//+------------------------------------------------------------------+
void CTradeEngine::UpdateStateFromBroker(const int idx)
  {
   if(idx < 0 || idx >= ATTE_MAX_STATES || !st[idx].active)
      return;
   if(st[idx].is_pending)
     {
      if(OrderSelect(st[idx].ticket))
        {
         st[idx].v_now = OrderGetDouble(ORDER_VOLUME_CURRENT);
         st[idx].sl_now = OrderGetDouble(ORDER_SL);
         st[idx].tp3    = OrderGetDouble(ORDER_TP);
        }
      return;
     }
   if(PositionSelectByTicket(st[idx].ticket))
     {
      st[idx].v_now  = PositionGetDouble(POSITION_VOLUME);
      double sl_brok = PositionGetDouble(POSITION_SL);
      double tp_brok = PositionGetDouble(POSITION_TP);
      if(sl_brok > 0.0)
        {
         bool profit_lock=(st[idx].trail_armed || st[idx].be_armed ||
                           st[idx].be_locked || st[idx].tp1_hit);
         if(st[idx].sl_now<=0.0 || !profit_lock)
            st[idx].sl_now=sl_brok;
         else if(st[idx].dir==1)
            st[idx].sl_now=MathMax(st[idx].sl_now,sl_brok);
         else
            st[idx].sl_now=MathMin(st[idx].sl_now,sl_brok);
        }
      if(tp_brok > 0.0)
         st[idx].tp3 = tp_brok;
      //--- For an armed trail, LOCKED means the broker SL is at the
      //--- cost-aware floor, not merely at Entry. Legacy break-even states
      //--- continue to use the textbook entry-price check.
      if(st[idx].trail_armed)
        {
         st[idx].be_armed=true;
         double floor=BreakEvenFloor(idx);
         st[idx].be_locked=(sl_brok>0.0 && floor>0.0 &&
                            (st[idx].dir==1 ? sl_brok>=floor-m_point :
                                             sl_brok<=floor+m_point));
        }
      else
        {
         bool at_be=(st[idx].dir==1)
                    ? (st[idx].sl_now>=st[idx].entry-m_point)
                    : (st[idx].sl_now>0.0 && st[idx].sl_now<=st[idx].entry+m_point);
         if(at_be)
           {
            st[idx].be_armed=true;
            st[idx].be_locked=true;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| rebuild the picture from the broker (positions + our pendings)    |
//+------------------------------------------------------------------+
void CTradeEngine::Sync(void)
  {
   bool seen[ATTE_MAX_STATES];
   for(int i = 0; i < ATTE_MAX_STATES; i++)
      seen[i] = false;

   //--- open positions
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic)
         continue;
      int idx = FindState(tk);
      if(idx < 0)
        {
         if(!AddStateFromBroker(tk))
            continue;
         idx = FindState(tk);
        }
      if(idx >= 0)
        {
         st[idx].is_pending = false;
         seen[idx] = true;
         UpdateStateFromBroker(idx);
        }
     }

   //--- our pending orders
   int orders = OrdersTotal();
   for(int i = 0; i < orders; i++)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != m_symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != m_magic)
         continue;
      int idx = FindState(tk);
      if(idx < 0)
        {
         if(!AddStateFromBroker(tk))
            continue;
         idx = FindState(tk);
        }
      if(idx >= 0)
        {
         st[idx].is_pending = true;
         seen[idx] = true;
         UpdateStateFromBroker(idx);
        }
     }

   //--- anything we no longer see is finished
   for(int i = 0; i < ATTE_MAX_STATES; i++)
      if(st[i].active && !seen[i])
         DropState(i);
  }

//+------------------------------------------------------------------+
//| the trade the LIVE panel should show (the most recent one)        |
//+------------------------------------------------------------------+
int CTradeEngine::MainIdx(void) const
  {
   int best = -1;
   for(int i = 0; i < ATTE_MAX_STATES; i++)
     {
      if(!st[i].active)
         continue;
      if(best < 0) { best = i; continue; }
      //--- a live position outranks a pending order; then newest wins
      if(st[i].is_pending && !st[best].is_pending)
         continue;
      if(!st[i].is_pending && st[best].is_pending)
        { best = i; continue; }
      if(st[i].opened > st[best].opened)
         best = i;
     }
   return best;
  }

bool CTradeEngine::HasPosition(void) const
  {
   for(int i = 0; i < ATTE_MAX_STATES; i++)
      if(st[i].active && !st[i].is_pending)
         return true;
   return false;
  }

bool CTradeEngine::HasPending(void) const
  {
   for(int i = 0; i < ATTE_MAX_STATES; i++)
      if(st[i].active && st[i].is_pending)
         return true;
   return false;
  }

bool CTradeEngine::HasAny(void) const
  {
   return (HasPosition() || HasPending());
  }

//+------------------------------------------------------------------+
//| OPEN A TRADE                                                      |
//+------------------------------------------------------------------+
bool CTradeEngine::Open(const int dir, const bool use_limit, const double entry,
                        const double sl, const double tp1, const double tp2,
                        const double tp3, const int expected_seconds,
                        const double risk_pct, const double atr)
  {
   m_last_error = "";
   if(dir != 1 && dir != -1)
      return false;
   if(HasAny())
     {
      m_last_error = "a trade is already open on this chart";
      return false;
     }

   double sl_dist = MathAbs(entry - sl);
   double lots = CalcLots(sl_dist, risk_pct, atr);
   if(lots <= 0.0)
     {
      if(m_last_error == "")
         m_last_error = "lot size could not be computed";
      return false;
     }

   double e  = NormPrice(entry);
   double s  = NormPrice(sl);
   double t3 = NormPrice(tp3);

   //--- one more reality check against the broker's minimum distance
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double ref = (dir == 1) ? ask : bid;
   if(m_stops_price > 0.0)
     {
      if(dir == 1 && (ref - s < m_stops_price || t3 - ref < m_stops_price))
        { m_last_error = "levels closer than the broker's stops level"; return false; }
      if(dir == -1 && (s - ref < m_stops_price || ref - t3 < m_stops_price))
        { m_last_error = "levels closer than the broker's stops level"; return false; }
     }

   //--- remember the exact plan so the new state is not a guess
   m_expect_new = true;
   m_expect_dir = dir;
   m_expect_entry = e;
   m_expect_sl = s;
   m_expect_tp1 = NormPrice(tp1);
   m_expect_tp2 = NormPrice(tp2);
   m_expect_tp3 = t3;
   m_expect_seconds = expected_seconds;
   m_expect_pending_ttl = PendingLifetimeSeconds(expected_seconds);

   bool sent = false;
   for(int attempt = 1; attempt <= ATTE_MAX_RETRY && !sent; attempt++)
     {
      if(use_limit)
        {
         long exp_mode = SymbolInfoInteger(m_symbol, SYMBOL_EXPIRATION_MODE);
         bool can_spec = ((exp_mode & SYMBOL_EXPIRATION_SPECIFIED) != 0);
         datetime expir = TimeCurrent() + (datetime)m_expect_pending_ttl;
         if(dir == 1)
            sent = can_spec
                   ? trade.BuyLimit(lots, e, m_symbol, s, t3, ORDER_TIME_SPECIFIED, expir, "AT3")
                   : trade.BuyLimit(lots, e, m_symbol, s, t3, ORDER_TIME_GTC, 0, "AT3");
         else
            sent = can_spec
                   ? trade.SellLimit(lots, e, m_symbol, s, t3, ORDER_TIME_SPECIFIED, expir, "AT3")
                   : trade.SellLimit(lots, e, m_symbol, s, t3, ORDER_TIME_GTC, 0, "AT3");
        }
      else
        {
         if(dir == 1)
            sent = trade.Buy(lots, m_symbol, 0.0, s, t3, "AT3");
         else
            sent = trade.Sell(lots, m_symbol, 0.0, s, t3, "AT3");
        }

      uint rc = trade.ResultRetcode();
      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED ||
                  rc == TRADE_RETCODE_DONE_PARTIAL))
         break;

      sent = false;
      m_last_error = StringFormat("retcode %d (%s)", (int)rc,
                                  trade.ResultRetcodeDescription());
      //--- requotes / price changed / off quotes: try again at once
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED &&
         rc != TRADE_RETCODE_PRICE_OFF && rc != TRADE_RETCODE_TIMEOUT &&
         rc != TRADE_RETCODE_REJECT)
         break;
      if(!MQLInfoInteger(MQL_TESTER))
         Sleep(150);
     }

   if(!sent)
     {
      m_expect_new = false;
      Print("Autotrader: order failed - ", m_last_error);
      return false;
     }

   Sync();
   int idx = MainIdx();
   //--- read the ticket behind a plain if, never inside a ?: - st[] is a
   //--- fixed-size array and a range guard written inside a ?: does not bound
   //--- the read (see VolumeFlow.mqh, 14 Oct 2026). idx is -1 whenever the
   //--- broker has not reported the new position yet, which is a normal state.
   string tkt = "";
   if(idx >= 0)
      tkt = " ticket " + IntegerToString((long)st[idx].ticket);
   Print("Autotrader: ", (dir == 1 ? "BUY" : "SELL"), " ", DoubleToString(lots, 2),
         " lot opened at ", DoubleToString(e, m_digits),
         " SL ", DoubleToString(s, m_digits),
         " TP3 ", DoubleToString(t3, m_digits), tkt);
   return true;
  }

//+------------------------------------------------------------------+
void CTradeEngine::UpdateTrailContext(const int idx,const SATTrailContext &ctx)
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || !st[idx].active || !ctx.ready ||
      ctx.bar_time<=0 || ctx.bar_time==st[idx].trail_bar_time)
      return;
   int score=(st[idx].dir==1 ? ctx.buy_score : ctx.sell_score);
   if(st[idx].trail_bar_time>0)
      st[idx].trail_score_delta=score-st[idx].trail_last_score;
   else
      st[idx].trail_score_delta=0;
   st[idx].trail_last_score=score;
   st[idx].trail_bar_time=ctx.bar_time;
   SaveState(idx);
  }

//--- M5 arms earliest; higher timeframes allow more room. Evidence and
//--- structure can advance protection, but never arm a losing stop.
double CTradeEngine::TrailArmThreshold(const int idx,const SATTrailContext &ctx) const
  {
   int lane=ctx.lane_minutes;
   if(lane<=0) lane=(int)Period();
   double arm=(lane<=5 ? 0.45 : (lane<=15 ? 0.65 : 0.85));
   if(idx<0 || idx>=ATTE_MAX_STATES)
      return arm;

   int own=(st[idx].dir==1 ? ctx.buy_score : ctx.sell_score);
   int other=(st[idx].dir==1 ? ctx.sell_score : ctx.buy_score);
   bool weak=(st[idx].trail_score_delta<=-6 || other>=own+10 ||
              (ctx.choch_direction==-st[idx].dir && ctx.bars_since_choch<=3));
   bool aligned=(ctx.m15_direction==st[idx].dir && ctx.m30_direction==st[idx].dir);
   bool directional=(ctx.trend || ctx.pullback) && ctx.efficiency>=0.35;
   bool strengthening=aligned && directional && own>=70 &&
                      st[idx].trail_score_delta>=0 && !weak;

   if(weak) arm-=0.12;
   if(ctx.transition_state || ctx.range_middle) arm-=0.05;
   if(ctx.volatile_state && (ctx.efficiency<0.45 || ctx.sign_changes>=4)) arm-=0.05;
   if(strengthening) arm+=0.08;
   return MathMax(0.30,MathMin(1.10,arm));
  }

//--- The leash is measured in current ATR (normal price movement), then
//--- widened for aligned trends and tightened when the evidence fades.
double CTradeEngine::TrailDistance(const int idx,const SATTrailContext &ctx) const
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || ctx.atr<=0.0)
      return 0.0;
   int lane=ctx.lane_minutes;
   if(lane<=0) lane=(int)Period();
   double base=(lane<=5 ? 0.65 : (lane<=15 ? 0.85 : 1.05));

   int own=(st[idx].dir==1 ? ctx.buy_score : ctx.sell_score);
   int other=(st[idx].dir==1 ? ctx.sell_score : ctx.buy_score);
   bool weak=(st[idx].trail_score_delta<=-6 || other>=own+10 ||
              (ctx.choch_direction==-st[idx].dir && ctx.bars_since_choch<=3));
   bool aligned=(ctx.m15_direction==st[idx].dir && ctx.m30_direction==st[idx].dir);
   bool directional=(ctx.trend || ctx.pullback) && ctx.efficiency>=0.35;
   bool strengthening=aligned && directional && own>=70 &&
                      st[idx].trail_score_delta>=0 && !weak;
   bool choppy=(ctx.range_middle || ctx.efficiency<0.25 || ctx.sign_changes>=6);
   bool chaotic=(ctx.volatile_state ||
                 (ctx.atr_ratio>=1.50 && (ctx.efficiency<0.45 || ctx.sign_changes>=4)));

   double atr_for_gap=ctx.atr;
   if(chaotic && ctx.atr_ratio>1.0)
     {
      // A volatility burst with two-way movement must not expand the leash
      // without limit. Keep some live-ATR room, but cap it near the normal ATR.
      double normal_atr=ctx.atr/ctx.atr_ratio;
      atr_for_gap=MathMax(ctx.atr*0.65,normal_atr*0.85);
     }

   double factor=1.0;
   if(strengthening) factor*=1.20;
   else if(directional) factor*=1.05;
   if(choppy) factor*=0.88;
   if(weak) factor*=0.70;
   if(ctx.quiet_state) factor*=0.85;
   if(ctx.volatile_state && !strengthening) factor*=0.92;
   factor=MathMax(0.55,MathMin(1.35,factor));
   return MathMax(m_point*3.0,atr_for_gap*base*factor);
  }

//--- Estimate round-turn commission/fee in price units from the entry
//--- deals. Spread and any negative swap are added dynamically below.
double CTradeEngine::EstimateRoundTurnCostPrice(const int idx)
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || !st[idx].active || st[idx].is_pending ||
      !PositionSelectByTicket(st[idx].ticket))
      return 0.0;
   double volume=PositionGetDouble(POSITION_VOLUME);
   if(volume<=0.0 || m_tick_size<=0.0 || m_tick_value<=0.0)
      return 0.0;

   ulong position_id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   if(position_id==0 || !HistorySelectByPosition(position_id))
      return 0.0;

   double entry_cost=0.0;
   double entry_volume=0.0;
   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
     {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || (long)HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_IN)
         continue;
      double deal_volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
      if(deal_volume<=0.0)
         continue;
      entry_volume+=deal_volume;
      entry_cost+=MathAbs(HistoryDealGetDouble(deal,DEAL_COMMISSION))+
                  MathAbs(HistoryDealGetDouble(deal,DEAL_FEE));
     }
   if(entry_volume<=0.0)
      return 0.0;
   double round_turn_money=2.0*entry_cost*(volume/entry_volume);
   double money_per_price=(m_tick_value/m_tick_size)*volume;
   if(money_per_price<=0.0)
      return 0.0;
   return round_turn_money/money_per_price;
  }

//--- A positive-price floor for a profit-protecting stop. It includes
//--- current spread, estimated round-turn fees and negative swap.
double CTradeEngine::BreakEvenFloor(const int idx)
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || !st[idx].active ||
      !PositionSelectByTicket(st[idx].ticket))
      return 0.0;
   if(st[idx].trail_cost_buffer<0.0)
      st[idx].trail_cost_buffer=EstimateRoundTurnCostPrice(idx);

   double bid=SymbolInfoDouble(m_symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(m_symbol,SYMBOL_ASK);
   double spread=(ask>bid ? ask-bid : m_point);
   double volume=PositionGetDouble(POSITION_VOLUME);
   double money_per_price=0.0;
   if(volume>0.0 && m_tick_size>0.0 && m_tick_value>0.0)
      money_per_price=(m_tick_value/m_tick_size)*volume;
   double swap=PositionGetDouble(POSITION_SWAP);
   double swap_buffer=(swap<0.0 && money_per_price>0.0 ? -swap/money_per_price : 0.0);
   double buffer=MathMax(m_point*2.0,spread)+st[idx].trail_cost_buffer+swap_buffer;
   return NormStopPrice(st[idx].entry+(double)st[idx].dir*buffer,st[idx].dir);
  }

bool CTradeEngine::TrailCanImprove(const int idx,const double sl,
                                    const double bid,const double ask) const
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || sl<=0.0 || bid<=0.0 || ask<=0.0)
      return false;
   double live_stops=(double)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL)*m_point;
   double live_freeze=(double)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_FREEZE_LEVEL)*m_point;
   double min_distance=MathMax(MathMax(m_stops_price,live_stops),
                               MathMax(m_freeze_price,live_freeze))+m_point;
   if(st[idx].dir==1)
      return (sl<bid-min_distance);
   return (sl>ask+min_distance);
  }

void CTradeEngine::ManageTrailingStop(const int idx,const SATTrailContext &ctx,
                                      const double mark,const double bid,
                                      const double ask)
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || !st[idx].active || st[idx].is_pending ||
      !PositionSelectByTicket(st[idx].ticket) || mark<=0.0)
      return;
   int dir=st[idx].dir;
   if(st[idx].trail_best<=0.0)
     {
      st[idx].trail_best=mark;
      GlobalVariableSet(StateKey(st[idx].ticket,"TRP"),st[idx].trail_best);
     }
   else if((dir==1 && mark>st[idx].trail_best) ||
           (dir==-1 && mark<st[idx].trail_best))
     {
      st[idx].trail_best=mark;
      GlobalVariableSet(StateKey(st[idx].ticket,"TRP"),st[idx].trail_best);
     }

   UpdateTrailContext(idx,ctx);
   double risk=MathAbs(st[idx].entry-st[idx].sl_initial);
   if(risk<=m_point && PositionGetDouble(POSITION_SL)>0.0)
      risk=MathAbs(st[idx].entry-PositionGetDouble(POSITION_SL));
   if(risk<=m_point)
     {
      st[idx].trail_reason="waiting - initial risk unavailable";
      return;
     }

   double favorable=MathMax(0.0,(mark-st[idx].entry)*(double)dir);
   double progress_r=favorable/risk;
   double floor=BreakEvenFloor(idx);
   double floating=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   double arm=TrailArmThreshold(idx,ctx);
   st[idx].trail_arm_r=arm;

   if(!st[idx].trail_armed)
     {
      if(progress_r<arm || floating<=0.0)
        {
         st[idx].trail_reason=StringFormat("waiting for +%.2fR profit",arm);
         return;
        }
      double live_stops=(double)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL)*m_point;
      double live_freeze=(double)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_FREEZE_LEVEL)*m_point;
      double min_distance=MathMax(MathMax(m_stops_price,live_stops),
                                  MathMax(m_freeze_price,live_freeze))+m_point*2.0;
      if((dir==1 && bid-floor<=min_distance) ||
         (dir==-1 && floor-ask<=min_distance))
        {
         st[idx].trail_reason="armed by profit - waiting for broker stop space";
         return;
        }
      st[idx].trail_armed=true;
      st[idx].trail_stage=ATTE_TRAIL_PROTECTED;
      st[idx].be_armed=true;
      st[idx].trail_reason="non-loss protection armed";
      SaveState(idx);
     }

   if(!st[idx].trail_armed)
      return;
   if(floor<=0.0)
      return;

   int lane=ctx.lane_minutes;
   if(lane<=0) lane=(int)Period();
   double follow_r=(lane<=5 ? 0.80 : (lane<=15 ? 1.05 : 1.30));
   int own=(dir==1 ? ctx.buy_score : ctx.sell_score);
   int other=(dir==1 ? ctx.sell_score : ctx.buy_score);
   bool weak=(st[idx].trail_score_delta<=-6 || other>=own+10 ||
              (ctx.choch_direction==-dir && ctx.bars_since_choch<=3));
   bool aligned=(ctx.m15_direction==dir && ctx.m30_direction==dir);
   bool directional=(ctx.trend || ctx.pullback) && ctx.efficiency>=0.35;
   if(weak) follow_r-=0.15;
   if(aligned && directional && own>=70 && !weak) follow_r+=0.10;
   follow_r=MathMax(arm+0.12,follow_r);

   double candidate=floor;
   if(progress_r>=follow_r && ctx.atr>0.0)
     {
      st[idx].trail_stage=ATTE_TRAIL_FOLLOWING;
      st[idx].trail_gap=TrailDistance(idx,ctx);
      if(dir==1)
         candidate=st[idx].trail_best-st[idx].trail_gap;
      else
         candidate=st[idx].trail_best+st[idx].trail_gap;

      // A recent confirmed swing is a second, structural guide. M5 uses a
      // shorter freshness window; old pivots never drag a stop toward loss.
      int max_swing_age=(lane<=5 ? 6 : (lane<=15 ? 4 : 3));
      double swing_buffer=MathMax(ctx.atr*0.15,m_point*2.0);
      if(dir==1 && ctx.swing_low>st[idx].entry && ctx.swing_low<mark &&
         ctx.swing_low_bar>=2 && ctx.swing_low_bar<=max_swing_age)
         candidate=MathMax(candidate,ctx.swing_low-swing_buffer);
      if(dir==-1 && ctx.swing_high>0.0 && ctx.swing_high<st[idx].entry &&
         ctx.swing_high>mark && ctx.swing_high_bar>=2 &&
         ctx.swing_high_bar<=max_swing_age)
         candidate=MathMin(candidate,ctx.swing_high+swing_buffer);
      st[idx].trail_reason=(weak ? "tightening - evidence fading" :
                            (aligned && directional ? "following - aligned trend" :
                             (ctx.range_middle || ctx.sign_changes>=6 ?
                              "following - choppy market" : "following recent price")));
     }
   else
     {
      st[idx].trail_stage=ATTE_TRAIL_PROTECTED;
      st[idx].trail_gap=TrailDistance(idx,ctx);
      st[idx].trail_reason="protecting entry plus costs";
     }

   // The stop is always on the profitable side of entry after trailing arms.
   if(dir==1)
      candidate=MathMax(candidate,floor);
   else
      candidate=MathMin(candidate,floor);

   double live_stops=(double)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL)*m_point;
   double live_freeze=(double)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_FREEZE_LEVEL)*m_point;
   double min_distance=MathMax(MathMax(m_stops_price,live_stops),
                               MathMax(m_freeze_price,live_freeze))+m_point*2.0;
   if(dir==1)
     {
      double highest_valid=bid-min_distance;
      if(highest_valid<floor)
        {
         st[idx].trail_reason="armed - waiting for non-loss stop space";
         return;
        }
      candidate=MathMin(candidate,highest_valid);
      candidate=MathMax(candidate,floor);
     }
   else
     {
      double lowest_valid=ask+min_distance;
      if(lowest_valid>floor)
        {
         st[idx].trail_reason="armed - waiting for non-loss stop space";
         return;
        }
      candidate=MathMax(candidate,lowest_valid);
      candidate=MathMin(candidate,floor);
     }
   candidate=NormStopPrice(candidate,dir);
   if(!TrailCanImprove(idx,candidate,bid,ask))
     {
      st[idx].trail_reason="armed - waiting for broker stop space";
      return;
     }

   double broker_sl=PositionGetDouble(POSITION_SL);
   double current_sl=(broker_sl>0.0 ? broker_sl : st[idx].sl_now);
   double improvement=(dir==1 ? candidate-current_sl : current_sl-candidate);
   double step=MathMax(m_point*2.0,(ctx.atr>0.0 ? ctx.atr*0.04 : m_point*2.0));
   bool already_locked=false;
   if(broker_sl>0.0)
     {
      if(st[idx].trail_armed)
         already_locked=(floor>0.0 &&
                         (dir==1 ? broker_sl>=floor-m_point*0.5 :
                                   broker_sl<=floor+m_point*0.5));
      else
         already_locked=(dir==1 ? broker_sl>=st[idx].entry-m_point*0.5 :
                                  broker_sl<=st[idx].entry+m_point*0.5);
     }
   st[idx].be_locked=already_locked;
   if(current_sl>0.0 && improvement<step)
      return;

   datetime now=TimeCurrent();
   if(m_last_trail_modify>0 && now<=m_last_trail_modify)
      return;
   m_last_trail_modify=now;
   string why=(st[idx].trail_stage==ATTE_TRAIL_FOLLOWING ?
               "adaptive trailing stop" : "non-loss profit protection");
   if(MoveStopTo(idx,candidate,why))
     {
      st[idx].be_locked=true;
      st[idx].trail_updates++;
      SaveState(idx);
     }
   else
      st[idx].trail_reason="armed - broker update pending";
  }

//+------------------------------------------------------------------+
bool CTradeEngine::MoveStopTo(const int idx, const double new_sl, const string why)
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || !st[idx].active || st[idx].is_pending ||
      !PositionSelectByTicket(st[idx].ticket))
      return false;

   double broker_sl=PositionGetDouble(POSITION_SL);
   if(broker_sl>0.0)
      st[idx].sl_now=broker_sl;
   double sl=NormStopPrice(new_sl,st[idx].dir);
   bool profit_protection=(st[idx].trail_armed || st[idx].be_armed || st[idx].tp1_hit);
   if(profit_protection)
     {
      double floor=BreakEvenFloor(idx);
      if(floor<=0.0)
         return false;
      if(st[idx].dir==1)
         sl=NormStopPrice(MathMax(sl,floor),1);
      else
         sl=NormStopPrice(MathMin(sl,floor),-1);
     }

   // A stop is a one-way ratchet. TP1 may request entry, but it can never
   // undo an earlier profitable trail.
   double tol=m_point*0.5;
   if(st[idx].dir==1 && broker_sl>0.0 && sl<=broker_sl+tol)
     {
      st[idx].sl_now=broker_sl;
      if(profit_protection && broker_sl>=BreakEvenFloor(idx)-m_point)
         st[idx].be_locked=true;
      return true;
     }
   if(st[idx].dir==-1 && broker_sl>0.0 && sl>=broker_sl-tol)
     {
      st[idx].sl_now=broker_sl;
      if(profit_protection && broker_sl<=BreakEvenFloor(idx)+m_point)
         st[idx].be_locked=true;
      return true;
     }

   double bid=SymbolInfoDouble(m_symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(m_symbol,SYMBOL_ASK);
   if(profit_protection)
     {
      // Never submit a trail on the losing side of entry, even if a caller
      // accidentally supplies an unsafe value.
      if((st[idx].dir==1 && sl<st[idx].entry) ||
         (st[idx].dir==-1 && sl>st[idx].entry))
         return false;
     }
   if(!TrailCanImprove(idx,sl,bid,ask))
      return false;

   double tp=NormPrice(st[idx].tp3);
   if(tp<=0.0)
      tp=NormPrice(PositionGetDouble(POSITION_TP));
   bool sent=trade.PositionModify(st[idx].ticket,sl,tp);
   uint rc=trade.ResultRetcode();
   if(!sent || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_PLACED))
     {
      m_last_error="SL move failed: "+trade.ResultRetcodeDescription();
      Print("Autotrader: ",m_last_error);
      return false;
     }
   st[idx].sl_now=sl;
   st[idx].action=why;
   if(profit_protection)
     {
      st[idx].be_armed=true;
      st[idx].be_locked=true;
     }
   SaveState(idx);
   Print("Autotrader: stop moved to ",DoubleToString(sl,m_digits)," (",why,")");
   return true;
  }

//+------------------------------------------------------------------+
bool CTradeEngine::PartialClose(const int idx, const double fraction, const string why)
  {
   if(idx < 0 || !st[idx].active || st[idx].is_pending)
      return false;
   if(!PositionSelectByTicket(st[idx].ticket))
      return false;

   double v_now = PositionGetDouble(POSITION_VOLUME);
   double want  = NormVolume(st[idx].v0 * fraction);
   if(want <= 0.0)
      return false;
   double vol = want;
   if(vol >= v_now)                 vol = v_now;              // close it all
   else if(v_now - vol < m_vmin)    vol = v_now;              // remainder too small
   if(vol < m_vmin)
      return false;

   bool done = false;
   for(int attempt = 1; attempt <= ATTE_MAX_RETRY && !done; attempt++)
     {
      done = trade.PositionClosePartial(st[idx].ticket, vol, m_deviation);
      uint rc = trade.ResultRetcode();
      if(done && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL ||
                  rc == TRADE_RETCODE_PLACED))
         break;
      done = false;
      m_last_error = StringFormat("partial close failed: retcode %d (%s)", (int)rc,
                                  trade.ResultRetcodeDescription());
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED &&
         rc != TRADE_RETCODE_PRICE_OFF && rc != TRADE_RETCODE_TIMEOUT)
         break;
      if(!MQLInfoInteger(MQL_TESTER))
         Sleep(150);
     }
   if(!done)
     {
      Print("Autotrader: ", m_last_error);
      return false;
     }

   st[idx].v_now = MathMax(m_vmin, v_now - vol);
   st[idx].action = why;
   Print("Autotrader: ", why, " - closed ", DoubleToString(vol, 2), " lot");
   return true;
  }

//+------------------------------------------------------------------+
bool CTradeEngine::ClosePosition(const int idx, const string why)
  {
   if(idx < 0 || !st[idx].active)
      return false;
   if(st[idx].is_pending)
     {
      if(!trade.OrderDelete(st[idx].ticket))
        {
         m_last_error = "order delete failed: " + trade.ResultRetcodeDescription();
         return false;
        }
      DropState(idx);
      return true;
     }
   bool done = trade.PositionClose(st[idx].ticket, m_deviation);
   if(!done)
     {
      m_last_error = "close failed: " + trade.ResultRetcodeDescription();
      Print("Autotrader: ", m_last_error);
      return false;
     }
   Print("Autotrader: position closed (", why, ")");
   DropState(idx);
   return true;
  }

//+------------------------------------------------------------------+
bool CTradeEngine::CancelPending(const string why)
  {
   bool any = false;
   for(int i = 0; i < ATTE_MAX_STATES; i++)
      if(st[i].active && st[i].is_pending)
        {
         if(trade.OrderDelete(st[i].ticket))
           {
            Print("Autotrader: pending entry cancelled (", why, ")");
            DropState(i);
            any = true;
           }
         else
            m_last_error = "cancel failed: " + trade.ResultRetcodeDescription();
        }
   return any;
  }

//+------------------------------------------------------------------+
//| protection must exist at all times - repair it if it does not     |
//+------------------------------------------------------------------+
bool CTradeEngine::EnsureProtection(const int idx)
  {
   if(idx < 0 || !st[idx].active || st[idx].is_pending)
      return false;
   if(!PositionSelectByTicket(st[idx].ticket))
      return false;

   double sl_brok = PositionGetDouble(POSITION_SL);
   double tp_brok = PositionGetDouble(POSITION_TP);
   //--- at most one repair attempt every 5 seconds per pass, so a
   //--- broker that refuses (freeze level, requote) is not hammered
   datetime now = TimeCurrent();
   if(m_last_protect_try > 0 && now - m_last_protect_try < 5)
      return true;

   double want_sl=NormStopPrice(st[idx].sl_now,st[idx].dir);
   double want_tp=NormPrice(st[idx].tp3);
   double tol=m_point*0.5;
   bool profit_lock=(st[idx].trail_armed || st[idx].be_armed ||
                     st[idx].be_locked || st[idx].tp1_hit);
   if(want_sl<=0.0)
     {
      if(profit_lock)
         want_sl=BreakEvenFloor(idx);
      else
         want_sl=NormStopPrice(st[idx].sl_initial,st[idx].dir);
     }
   if(profit_lock && want_sl>0.0)
     {
      double floor=BreakEvenFloor(idx);
      if(floor>0.0)
        {
         if(st[idx].dir==1)
            want_sl=NormStopPrice(MathMax(want_sl,floor),1);
         else
            want_sl=NormStopPrice(MathMin(want_sl,floor),-1);
        }
     }
   if(sl_brok>0.0 && want_sl>0.0)
     {
      // Repairs may restore or tighten protection, never loosen the broker SL.
      if(st[idx].dir==1) want_sl=MathMax(want_sl,sl_brok);
      else               want_sl=MathMin(want_sl,sl_brok);
     }

   bool need = false;
   if(want_sl > 0.0 && (sl_brok <= 0.0 || MathAbs(sl_brok - want_sl) > tol)) need = true;
   if(want_tp > 0.0 && (tp_brok <= 0.0 || MathAbs(tp_brok - want_tp) > tol)) need = true;
   if(!need)
      return true;
   m_last_protect_try = now;
   if(want_sl <= 0.0)
      want_sl = sl_brok;
   if(want_tp <= 0.0)
      want_tp = tp_brok;
   if(want_sl<=0.0)
      return false;
   bool sl_change=(sl_brok<=0.0 || MathAbs(sl_brok-want_sl)>tol);
   if(sl_change)
     {
      double bid=SymbolInfoDouble(m_symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(m_symbol,SYMBOL_ASK);
      if(!TrailCanImprove(idx,want_sl,bid,ask))
         return false;
     }

   bool sent=trade.PositionModify(st[idx].ticket,want_sl,want_tp);
   uint rc=trade.ResultRetcode();
   if(!sent || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_PLACED))
     {
      m_last_error="protection repair failed: "+trade.ResultRetcodeDescription();
      return false;
     }
   st[idx].sl_now=want_sl;
   st[idx].action="protection repaired";
   SaveState(idx);
   return true;
  }

//+------------------------------------------------------------------+
//| MANAGE - one pass over every trade we own                         |
//+------------------------------------------------------------------+
bool CTradeEngine::Manage(const SATTrailContext &ctx)
  {
   Sync();
   m_last_pending_event = "";
   datetime now = TimeCurrent();
   bool pending_expired = false;

   //--- Pending entries have a maximum age of three chart bars (bounded
   //--- by expected duration and a 10-minute minimum). Brokers that accept
   //--- ORDER_TIME_SPECIFIED also receive this same expiry; this local check
   //--- covers GTC-only symbols and acts as a second freshness guard.
   for(int i = 0; i < ATTE_MAX_STATES; i++)
     {
      if(!st[i].active || !st[i].is_pending)
         continue;
      int ttl = st[i].pending_ttl_seconds;
      if(ttl <= 0)
         ttl = PendingLifetimeSeconds(st[i].expected_seconds);
      long age = (st[i].opened > 0) ? (long)(now - st[i].opened) : 0;
      if(st[i].opened > 0 && age >= (long)ttl)
        {
         ulong ticket = st[i].ticket;
         if(trade.OrderDelete(ticket))
           {
            string note = "order " + IntegerToString((long)ticket) +
                          " expired locally after " + IntegerToString((int)age) +
                          "s (limit " + IntegerToString(ttl) + "s)";
            if(m_last_pending_event != "")
               m_last_pending_event += "; ";
            m_last_pending_event += note;
            Print("Autotrader: pending entry expired - ", note);
            DropState(i);
            pending_expired = true;
           }
         else
            m_last_error = "pending expiry cancellation failed: " + trade.ResultRetcodeDescription();
        }
     }

   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return pending_expired;

   for(int i = 0; i < ATTE_MAX_STATES; i++)
     {
      if(!st[i].active || st[i].is_pending)
         continue;
      if(!PositionSelectByTicket(st[i].ticket))
        {
         DropState(i);
         continue;
        }

      int    dir   = st[i].dir;
      double mark  = (dir == 1) ? bid : ask;    // the price we would close at

      //--- keep the broker-side protection honest, then manage the adaptive
      //--- non-loss trail before the TP ladder so M5 can protect profit early.
      EnsureProtection(i);
      ManageTrailingStop(i,ctx,mark,bid,ask);

      //--- TP1: bank half the lot; retain any more-protective trail already set
      if(!st[i].tp1_hit && st[i].tp1 > 0.0 &&
         ((dir == 1 && mark >= st[i].tp1) || (dir == -1 && mark <= st[i].tp1)))
        {
         if(PartialClose(i,0.50,"TP1 hit - closed 50% of lot"))
           {
            st[i].tp1_hit=true;
            st[i].tp1_time=TimeCurrent();
            st[i].be_armed=true;
            st[i].trail_armed=true;
            if(st[i].trail_stage<ATTE_TRAIL_PROTECTED)
               st[i].trail_stage=ATTE_TRAIL_PROTECTED;
            if(st[i].trail_best<=0.0) st[i].trail_best=mark;
            st[i].trail_reason="TP1 reached - protecting profit";
            // The floor includes spread/fees/swap. MoveStopTo is one-way,
            // so TP1 can never pull a better early trail back to entry.
            if(MoveStopTo(i,BreakEvenFloor(i),
                          "TP1 hit - non-loss stop protected"))
               st[i].be_locked=true;
            SaveState(i);
           }
         continue;   // one action per position per tick
        }

      //--- TP2: bank another 30% of the original lot
      if(st[i].tp1_hit && !st[i].tp2_hit && st[i].tp2 > 0.0 &&
         ((dir == 1 && mark >= st[i].tp2) || (dir == -1 && mark <= st[i].tp2)))
        {
         if(PartialClose(i,0.30,"TP2 hit - closed 30% of lot"))
           {
            st[i].tp2_hit=true;
            SaveState(i);
           }
         continue;
        }

      //--- TP3: the rest (the broker-side TP does the same if we are gone)
      if(st[i].tp2_hit && !st[i].tp3_hit && st[i].tp3 > 0.0 &&
         ((dir == 1 && mark >= st[i].tp3) || (dir == -1 && mark <= st[i].tp3)))
        {
         st[i].tp3_hit = true;
         ClosePosition(i, "TP3 hit - ladder complete");
         continue;
        }

      //--- time exit: a trade that stalls is a trade that was not right
      if(!st[i].tp1_hit && st[i].expected_seconds > 0)
        {
         long age = (long)(TimeCurrent() - st[i].opened);
         if(age > (long)st[i].expected_seconds * 3 / 2)
           {
            ClosePosition(i, "closed for time - trade stalled");
            continue;
           }
        }
     }
   return pending_expired;
  }

//+------------------------------------------------------------------+
//| a restored trade that lost its notes still deserves a time exit   |
//+------------------------------------------------------------------+
void CTradeEngine::SetExpectedDefault(const int seconds)
  {
   if(seconds <= 0)
      return;
   for(int i = 0; i < ATTE_MAX_STATES; i++)
      if(st[i].active && st[i].expected_seconds <= 0)
        {
         st[i].expected_seconds = seconds;
         GlobalVariableSet("ATRET_" + IntegerToString((long)m_magic) + "_" +
                           IntegerToString((long)st[i].ticket), (double)seconds);
        }
  }

//+------------------------------------------------------------------+
//| panel helpers                                                     |
//+------------------------------------------------------------------+
double CTradeEngine::FloatingUsd(const int idx) const
  {
   if(idx < 0 || !st[idx].active || st[idx].is_pending)
      return 0.0;
   double mark = (st[idx].dir == 1) ? SymbolInfoDouble(m_symbol, SYMBOL_BID)
                                    : SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double diff = (mark - st[idx].entry) * (double)st[idx].dir;
   if(m_tick_size <= 0.0 || m_tick_value <= 0.0)
      return 0.0;
   return diff / m_tick_size * m_tick_value * st[idx].v_now;
  }

//--- how far price has travelled from Entry towards TP1, in %
double CTradeEngine::TpProgress(const int idx) const
  {
   if(idx < 0 || !st[idx].active)
      return 0.0;
   double mark = (st[idx].dir == 1) ? SymbolInfoDouble(m_symbol, SYMBOL_BID)
                                    : SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double full = MathAbs(st[idx].tp1 - st[idx].entry);
   if(full <= 0.0)
      return 0.0;
   double p = MathAbs(mark - st[idx].entry) / full * 100.0;
   if(p < 0.0) p = 0.0;
   if(p > 99.0) p = 99.0;
   return p;
  }

string CTradeEngine::BeStateText(const int idx) const
  {
   if(idx < 0 || !st[idx].active)
      return "not armed";
   if(st[idx].be_locked)
      return (st[idx].trail_armed ? "LOCKED (non-loss trail)" : "LOCKED");
   if(st[idx].be_armed)
      return (st[idx].trail_armed ? "ARMED (trail update pending)" : "ARMED (after TP1)");
   return "not armed";
  }

string CTradeEngine::SlJourneyText(const int idx) const
  {
   if(idx<0 || !st[idx].active)
      return "";
   string now=DoubleToString(st[idx].sl_now,m_digits);
   if(MathAbs(st[idx].sl_now-st[idx].sl_initial)<m_point*0.5)
      return now+"  (initial)";
   if(st[idx].trail_armed && st[idx].be_locked)
      return now+"  (initial "+GLYPH_ARROW+" non-loss trail)";
   bool at_be=(st[idx].dir==1)
              ? (st[idx].sl_now>=st[idx].entry-m_point)
              : (st[idx].sl_now<=st[idx].entry+m_point);
   if(at_be)
      return now+"  (started "+DoubleToString(st[idx].sl_initial,m_digits)+
             " "+GLYPH_ARROW+" protected at entry)";
   return now+"  (started "+DoubleToString(st[idx].sl_initial,m_digits)+")";
  }

string CTradeEngine::TrailStatusText(const int idx) const
  {
   if(idx<0 || idx>=ATTE_MAX_STATES || !st[idx].active)
      return "OFF";
   if(st[idx].is_pending)
      return "waiting for entry";
   if(st[idx].trail_stage==ATTE_TRAIL_FOLLOWING && st[idx].be_locked)
      return "FOLLOWING "+DoubleToString(st[idx].sl_now,m_digits)+" - "+st[idx].trail_reason;
   if(st[idx].trail_armed && st[idx].be_locked)
      return "PROTECTED "+DoubleToString(st[idx].sl_now,m_digits)+" - "+st[idx].trail_reason;
   if(st[idx].trail_armed)
      return "ARMED - "+st[idx].trail_reason;
   if(st[idx].trail_reason!="")
      return st[idx].trail_reason;
   return "waiting for profit";
  }
//+------------------------------------------------------------------+
#endif // AUTOTRADER_TRADE_ENGINE_MQH
