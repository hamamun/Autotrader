//+------------------------------------------------------------------+
//| TradeEngine.mqh                                                   |
//| Autotrader Phase 4 + 6 - the trade manager.                       |
//|                                                                   |
//| What it does, in plain words:                                     |
//|  * sizes the lot from the account's own equity and the 1% risk    |
//|    dial - never a fixed lot, never a guess;                       |
//|  * sends the order with a HARD broker-side stop loss on every     |
//|    single trade (PLAN: never trade without one) plus the broker-  |
//|    side TP3, so the trade stays protected even if this EA dies;   |
//|  * walks the owner's ladder: TP1 60% -> close 50% of the lot,     |
//|    TP2 80% -> close 30%, TP3 100% -> close the rest;              |
//|  * moves the stop to Entry (break-even) the moment TP1 banks, so  |
//|    the trade can no longer become a Loss;                         |
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
   datetime opened;
   int      expected_seconds;
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
   string   m_last_error;
   datetime m_last_protect_try;   // repairs are attempted at most every 5s
   //--- what we are about to open, so the new state is exact and not guessed
   bool     m_expect_new;
   int      m_expect_dir;
   double   m_expect_entry, m_expect_sl, m_expect_tp1, m_expect_tp2, m_expect_tp3;
   int      m_expect_seconds;

   int      FindState(const ulong ticket) const;
   int      FreeSlot(void) const;
   void     DropState(const int idx);
   bool     AddStateFromBroker(const ulong ticket);
   void     UpdateStateFromBroker(const int idx);
   bool     EnsureProtection(const int idx);
   bool     PartialClose(const int idx, const double fraction, const string why);
   bool     MoveStopTo(const int idx, const double new_sl, const string why);

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
   void     Manage(void);
   void     SetExpectedDefault(const int seconds);
   bool     ClosePosition(const int idx, const string why);
   bool     CancelPending(void);

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
   m_last_error = "";
   m_last_protect_try = 0;
   m_expect_new = false;
   m_expect_dir = 0;
   m_expect_entry = 0.0; m_expect_sl = 0.0;
   m_expect_tp1 = 0.0; m_expect_tp2 = 0.0; m_expect_tp3 = 0.0;
   m_expect_seconds = 0;
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
      st[i].opened = 0;
      st[i].expected_seconds = 0;
      st[i].action = "";
     }
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

void CTradeEngine::DropState(const int idx)
  {
   if(idx < 0 || idx >= ATTE_MAX_STATES)
      return;
   //--- forget the restore notes for this ticket
   GlobalVariableDel("ATRV0_" + IntegerToString((long)m_magic) + "_" +
                     IntegerToString((long)st[idx].ticket));
   GlobalVariableDel("ATRET_" + IntegerToString((long)m_magic) + "_" +
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
   st[idx].action = "";
   st[idx].expected_seconds = 0;

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
      st[idx].sl_now = OrderGetDouble(ORDER_PRICE_SL);
      st[idx].tp3    = OrderGetDouble(ORDER_PRICE_TP);
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
      st[idx].v0         = st[idx].v_now;
      exact = true;
      m_expect_new = false;
     }

   if(!exact)
     {
      //--- RESTORE after a restart. The terminal's global variables hold
      //--- the true starting volume and expected duration; if they are
      //--- gone (fresh terminal) the ladder is inferred from how much
      //--- volume is left and whether the stop already sits at Entry.
      string gv = "ATRV0_" + IntegerToString((long)m_magic) + "_" + IntegerToString((long)ticket);
      string ge = "ATRET_" + IntegerToString((long)m_magic) + "_" + IntegerToString((long)ticket);
      if(GlobalVariableCheck(gv))
         st[idx].v0 = GlobalVariableGet(gv);
      if(GlobalVariableCheck(ge))
         st[idx].expected_seconds = (int)GlobalVariableGet(ge);

      bool sl_at_or_better =
         (st[idx].dir == 1 && st[idx].sl_now > 0.0 &&
          st[idx].sl_now >= st[idx].entry - m_point) ||
         (st[idx].dir == -1 && st[idx].sl_now > 0.0 &&
          st[idx].sl_now <= st[idx].entry + m_point);
      if(sl_at_or_better)
        {
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

   //--- remember for the next restart
   GlobalVariableSet("ATRV0_" + IntegerToString((long)m_magic) + "_" +
                     IntegerToString((long)ticket), st[idx].v0);
   if(st[idx].expected_seconds > 0)
      GlobalVariableSet("ATRET_" + IntegerToString((long)m_magic) + "_" +
                        IntegerToString((long)ticket),
                        (double)st[idx].expected_seconds);

   if(exact)
      st[idx].action = "opened";
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
         st[idx].sl_now = OrderGetDouble(ORDER_PRICE_SL);
         st[idx].tp3    = OrderGetDouble(ORDER_PRICE_TP);
        }
      return;
     }
   if(PositionSelectByTicket(st[idx].ticket))
     {
      st[idx].v_now  = PositionGetDouble(POSITION_VOLUME);
      double sl_brok = PositionGetDouble(POSITION_SL);
      double tp_brok = PositionGetDouble(POSITION_TP);
      if(sl_brok > 0.0)
         st[idx].sl_now = sl_brok;
      if(tp_brok > 0.0)
         st[idx].tp3 = tp_brok;
      //--- break-even is a fact of the stop's position, not of memory
      bool at_be = (st[idx].dir == 1)
                   ? (st[idx].sl_now >= st[idx].entry - m_point)
                   : (st[idx].sl_now > 0.0 && st[idx].sl_now <= st[idx].entry + m_point);
      if(at_be)
        {
         st[idx].be_armed = true;
         st[idx].be_locked = true;
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

   bool sent = false;
   for(int attempt = 1; attempt <= ATTE_MAX_RETRY && !sent; attempt++)
     {
      if(use_limit)
        {
         long exp_mode = SymbolInfoInteger(m_symbol, SYMBOL_EXPIRATION_MODE);
         bool can_spec = ((exp_mode & SYMBOL_EXPIRATION_SPECIFIED) != 0);
         datetime expir = TimeCurrent() + (datetime)MathMax(600, expected_seconds);
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
         rc != TRADE_RETCODE_PRICE_OFF && rc != TRADE_RETCODE_TRADE_TIMEOUT &&
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
   Print("Autotrader: ", (dir == 1 ? "BUY" : "SELL"), " ", DoubleToString(lots, 2),
         " lot opened at ", DoubleToString(e, m_digits),
         " SL ", DoubleToString(s, m_digits),
         " TP3 ", DoubleToString(t3, m_digits),
         (idx >= 0 ? " ticket " + IntegerToString((long)st[idx].ticket) : ""));
   return true;
  }

//+------------------------------------------------------------------+
bool CTradeEngine::MoveStopTo(const int idx, const double new_sl, const string why)
  {
   if(idx < 0 || !st[idx].active)
      return false;
   double sl = NormPrice(new_sl);
   double tp = NormPrice(st[idx].tp3);
   if(tp <= 0.0)
      tp = NormPrice(PositionGetDouble(POSITION_TP));
   if(!trade.PositionModify(st[idx].ticket, sl, tp))
     {
      m_last_error = "SL move failed: " + trade.ResultRetcodeDescription();
      Print("Autotrader: ", m_last_error);
      return false;
     }
   st[idx].sl_now = sl;
   st[idx].action = why;
   Print("Autotrader: stop moved to ", DoubleToString(sl, m_digits), " (", why, ")");
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
         rc != TRADE_RETCODE_PRICE_OFF && rc != TRADE_RETCODE_TRADE_TIMEOUT)
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
bool CTradeEngine::CancelPending(void)
  {
   bool any = false;
   for(int i = 0; i < ATTE_MAX_STATES; i++)
      if(st[i].active && st[i].is_pending)
        {
         if(trade.OrderDelete(st[i].ticket))
           {
            Print("Autotrader: pending entry cancelled (signal released)");
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

   double want_sl = NormPrice(st[idx].sl_now);
   double want_tp = NormPrice(st[idx].tp3);
   double tol = m_point * 0.5;

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
   if(want_sl <= 0.0)
      return false;

   if(!trade.PositionModify(st[idx].ticket, want_sl, want_tp))
     {
      m_last_error = "protection repair failed: " + trade.ResultRetcodeDescription();
      return false;
     }
   st[idx].action = "protection repaired";
   return true;
  }

//+------------------------------------------------------------------+
//| MANAGE - one pass over every trade we own                         |
//+------------------------------------------------------------------+
void CTradeEngine::Manage(void)
  {
   Sync();
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

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

      //--- keep the broker-side protection honest
      EnsureProtection(i);

      //--- TP1: bank half the lot, then the trade cannot lose any more
      if(!st[i].tp1_hit && st[i].tp1 > 0.0 &&
         ((dir == 1 && mark >= st[i].tp1) || (dir == -1 && mark <= st[i].tp1)))
        {
         if(PartialClose(i, 0.50, "TP1 hit - closed 50% of lot"))
           {
            st[i].tp1_hit = true;
            st[i].tp1_time = TimeCurrent();
            st[i].be_armed = true;
            //--- break-even: the stop moves up to the Entry price
            if(MoveStopTo(i, st[i].entry, "moved to Entry - break-even locked"))
               st[i].be_locked = true;
           }
         continue;   // one action per position per tick
        }

      //--- TP2: bank another 30% of the original lot
      if(st[i].tp1_hit && !st[i].tp2_hit && st[i].tp2 > 0.0 &&
         ((dir == 1 && mark >= st[i].tp2) || (dir == -1 && mark <= st[i].tp2)))
        {
         if(PartialClose(i, 0.30, "TP2 hit - closed 30% of lot"))
            st[i].tp2_hit = true;
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
      return "LOCKED";
   if(st[idx].be_armed)
      return "ARMED (after TP1)";
   return "not armed";
  }

string CTradeEngine::SlJourneyText(const int idx) const
  {
   if(idx < 0 || !st[idx].active)
      return "";
   string now = DoubleToString(st[idx].sl_now, m_digits);
   if(MathAbs(st[idx].sl_now - st[idx].sl_initial) < m_point * 0.5)
      return now + "  (initial)";
   bool at_be = (st[idx].dir == 1)
                ? (st[idx].sl_now >= st[idx].entry - m_point)
                : (st[idx].sl_now <= st[idx].entry + m_point);
   if(at_be)
      return now + "  (started " + DoubleToString(st[idx].sl_initial, m_digits) +
             " " + GLYPH_ARROW + " moved to Entry)";
   return now + "  (started " + DoubleToString(st[idx].sl_initial, m_digits) + ")";
  }
//+------------------------------------------------------------------+
#endif // AUTOTRADER_TRADE_ENGINE_MQH
