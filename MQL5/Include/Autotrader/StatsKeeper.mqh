//+------------------------------------------------------------------+
//| StatsKeeper.mqh                                                   |
//| Autotrader Phase 6 - the scoreboard and the audit trail.          |
//|                                                                   |
//| Counting follows the OWNER'S RULE exactly:                        |
//|   closed at ANY positive value = Win                              |
//|   closed at ANY negative value = Loss                             |
//|   closed at exactly zero       = BE (counted separately)          |
//| and ONE trade = ONE result, even though the TP ladder closes it   |
//| in three pieces. That is why the deals are grouped by their       |
//| position id and summed: TP1+TP2+TP3 all hitting is a single Win   |
//| (PLAN section 1, case 1).                                         |
//|                                                                   |
//| The numbers come from the broker's own deal history, so they      |
//| survive restarts, reconnections and re-attaching the EA.          |
//| Every signal and every order action is also appended to           |
//| MQL5\Files\Autotrader_log.csv for research-target auditing.       |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_STATS_KEEPER_MQH
#define AUTOTRADER_STATS_KEEPER_MQH

#define ATST_LOG_FILE     "Autotrader_log.csv"
#define ATST_LOG_MAX_BYTES 4000000

class CStatsKeeper
  {
private:
   string   m_symbol;
   ulong    m_magic;
   string   m_lane_tag;
   int      m_day_key;
   //--- counters
   int      m_sig_today, m_sig_all;
   int      m_win_today, m_loss_today, m_be_today;
   int      m_win_all,   m_loss_all,   m_be_all;
   double   m_net_today, m_net_all;
   datetime m_last_scan;
   //--- grouping of closing deals per position (one trade = one result)
   ulong    g_pid[];
   double   g_net[];
   double   g_gross[];
   double   g_swap[];
   double   g_commission[];
   double   g_fee[];
   datetime g_last[];
   int      g_n;
   datetime g_open_t[];   // when the trade opened (first entry deal)
   int      g_dir[];      // 1 = BUY, 2 = SELL
   double   g_entry[];    // entry price
   double   g_vol[];      // total lots entered
   bool     g_live[];     // still has an open position -> not finished yet
   //--- trades already written to the audit log (Phase 7 reads them)
   ulong    l_pid[];
   int      l_n;
   datetime m_log_from;   // only trades that finish after the EA started

   int      DayKey(void) const;
   int      FindGroup(const ulong pid);
   void     AddGroup(const ulong pid);
   bool     WriteHeader(void);
   bool     PrepareLog(void);
   bool     IsLogged(const ulong pid) const;
   void     LogTrade(const int idx);

public:
            CStatsKeeper(void);
   bool     Init(const string symbol, const ulong magic, const string lane_tag);
   //--- a new signal was published (latched) -> count it and log it
   void     OnSignal(const int dir, const int score, const int threshold,
                     const string regime, const double entry, const double sl,
                     const double tp1, const double tp2, const double tp3,
                     const string detail);
   //--- one machine-readable two-sided assessment per closed lane bar
   void     OnAssessment(const int bias_dir, const int buy_score, const int sell_score,
                        const int threshold, const string regime,
                        const double entry, const double sl, const double tp1,
                        const double tp2, const double tp3, const long spread_pts,
                        const bool eligible, const string detail);
   //--- general audit line
   void     Log(const string event, const string detail);
   //--- rescan the broker history (throttled internally)
   bool     Scan(const bool force);

   int      WinToday(void)  const { return m_win_today; }
   int      LossToday(void) const { return m_loss_today; }
   int      BeToday(void)   const { return m_be_today; }
   int      WinAll(void)    const { return m_win_all; }
   int      LossAll(void)   const { return m_loss_all; }
   int      BeAll(void)     const { return m_be_all; }
   int      SigToday(void)  const { return m_sig_today; }
   int      SigAll(void)    const { return m_sig_all; }
   double   NetToday(void)  const { return m_net_today; }
   double   NetAll(void)    const { return m_net_all; }
   string   TodayText(void) const;
   string   AllTimeText(void) const;
  };

//+------------------------------------------------------------------+
CStatsKeeper::CStatsKeeper(void)
  {
   m_symbol = "";
   m_magic = 0;
   m_lane_tag = "";
   m_day_key = 0;
   m_sig_today = 0; m_sig_all = 0;
   m_win_today = 0; m_loss_today = 0; m_be_today = 0;
   m_win_all = 0;   m_loss_all = 0;   m_be_all = 0;
   m_net_today = 0.0; m_net_all = 0.0;
   m_last_scan = 0;
   g_n = 0;
   l_n = 0;
   m_log_from = 0;
  }

int CStatsKeeper::DayKey(void) const
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

//+------------------------------------------------------------------+
//| commas would break the CSV columns - keep the log tidy            |
//+------------------------------------------------------------------+
string ATST_Safe(const string s)
  {
   string out = s;
   StringReplace(out, ",", ";");
   StringReplace(out, "\n", " ");
   StringReplace(out, "\r", " ");
   return out;
  }

//+------------------------------------------------------------------+
bool CStatsKeeper::Init(const string symbol, const ulong magic, const string lane_tag)
  {
   m_symbol   = symbol;
   m_magic    = magic;
   m_lane_tag = lane_tag;
   m_day_key  = DayKey();
   m_log_from = TimeCurrent();   // trades finishing from now on are logged

   //--- signal counters live in terminal global variables, so they
   //--- survive a restart (the magic number already encodes symbol+TF)
   string g_all = "ATRSIG_" + IntegerToString((long)magic);
   string g_day = g_all + "_D" + IntegerToString(m_day_key);
   m_sig_all   = GlobalVariableCheck(g_all) ? (int)GlobalVariableGet(g_all) : 0;
   m_sig_today = GlobalVariableCheck(g_day) ? (int)GlobalVariableGet(g_day) : 0;

   WriteHeader();
   Scan(true);
   return true;
  }

//+------------------------------------------------------------------+
bool CStatsKeeper::WriteHeader(void)
  {
   if(FileIsExist(ATST_LOG_FILE))
      return true;
   int h = FileOpen(ATST_LOG_FILE, FILE_WRITE | FILE_CSV | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return false;
   FileWrite(h, "time", "symbol", "lane", "event", "dir", "score", "threshold",
             "regime", "bid", "entry", "sl", "tp1", "tp2", "tp3", "lots", "detail");
   FileClose(h);
   return true;
  }

//+------------------------------------------------------------------+
bool CStatsKeeper::PrepareLog(void)
  {
   if(FileIsExist(ATST_LOG_FILE))
     {
      long sz = FileGetInteger(ATST_LOG_FILE, FILE_SIZE);
      if(sz > ATST_LOG_MAX_BYTES)
         FileDelete(ATST_LOG_FILE);
     }
   if(!FileIsExist(ATST_LOG_FILE))
      return WriteHeader();
   return true;
  }

//+------------------------------------------------------------------+
void CStatsKeeper::Log(const string event, const string detail)
  {
   if(!PrepareLog())
      return;

   int h = FileOpen(ATST_LOG_FILE, FILE_READ | FILE_WRITE | FILE_CSV | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   int d = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   FileWrite(h,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             m_symbol, m_lane_tag, ATST_Safe(event), "-", 0, 0, "-",
             DoubleToString(SymbolInfoDouble(m_symbol, SYMBOL_BID), d),
             "-", "-", "-", "-", "-", "-",
             ATST_Safe(detail));
   FileClose(h);
  }

//+------------------------------------------------------------------+
void CStatsKeeper::OnSignal(const int dir, const int score, const int threshold,
                            const string regime, const double entry, const double sl,
                            const double tp1, const double tp2, const double tp3,
                            const string detail)
  {
   //--- a new day? reset the daily signal counter handle
   int dk = DayKey();
   if(dk != m_day_key)
     {
      m_day_key = dk;
      m_sig_today = 0;
     }

   m_sig_all++;
   m_sig_today++;
   string g_all = "ATRSIG_" + IntegerToString((long)m_magic);
   string g_day = g_all + "_D" + IntegerToString(m_day_key);
   GlobalVariableSet(g_all, (double)m_sig_all);
   GlobalVariableSet(g_day, (double)m_sig_today);

   if(!PrepareLog())
      return;
   int h = FileOpen(ATST_LOG_FILE, FILE_READ | FILE_WRITE | FILE_CSV | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   int d = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   string dir_s = (dir == 1) ? "BUY" : ((dir == 2) ? "SELL" : "HOLD");
   FileWrite(h,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             m_symbol, m_lane_tag, "SIGNAL", dir_s, score, threshold,
             ATST_Safe(regime),
             DoubleToString(SymbolInfoDouble(m_symbol, SYMBOL_BID), d),
             DoubleToString(entry, d), DoubleToString(sl, d),
             DoubleToString(tp1, d), DoubleToString(tp2, d),
             DoubleToString(tp3, d), "-",
             ATST_Safe(detail));
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Every closed lane bar is retained for side-by-side validation.    |
//+------------------------------------------------------------------+
void CStatsKeeper::OnAssessment(const int bias_dir, const int buy_score,
                                const int sell_score, const int threshold,
                                const string regime, const double entry,
                                const double sl, const double tp1,
                                const double tp2, const double tp3,
                                const long spread_pts, const bool eligible,
                                const string detail)
  {
   if(!PrepareLog())
      return;
   int h = FileOpen(ATST_LOG_FILE, FILE_READ | FILE_WRITE | FILE_CSV | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   int d = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   string dir_s = (bias_dir == 1) ? "BUY" : ((bias_dir == -1) ? "SELL" : "MIXED");
   int selected = (bias_dir == 1) ? buy_score :
                  ((bias_dir == -1) ? sell_score : (int)MathMax(buy_score, sell_score));
   string meta = StringFormat("buy=%d;sell=%d;gap=%d;spread_pts=%d;auto_trade_eligible=%s;",
                              buy_score, sell_score, buy_score - sell_score,
                              (int)spread_pts, (eligible ? "true" : "false"));
   FileWrite(h,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             m_symbol, m_lane_tag, "ASSESS", dir_s, selected, threshold,
             ATST_Safe(regime),
             DoubleToString(SymbolInfoDouble(m_symbol, SYMBOL_BID), d),
             DoubleToString(entry, d), DoubleToString(sl, d),
             DoubleToString(tp1, d), DoubleToString(tp2, d),
             DoubleToString(tp3, d), "-",
             ATST_Safe(meta + detail));
   FileClose(h);
  }

//+------------------------------------------------------------------+
int CStatsKeeper::FindGroup(const ulong pid)
  {
   for(int i = 0; i < g_n; i++)
      if(g_pid[i] == pid)
         return i;
   return -1;
  }

void CStatsKeeper::AddGroup(const ulong pid)
  {
   g_n++;
   ArrayResize(g_pid, g_n);
   ArrayResize(g_net, g_n);
   ArrayResize(g_gross, g_n);
   ArrayResize(g_swap, g_n);
   ArrayResize(g_commission, g_n);
   ArrayResize(g_fee, g_n);
   ArrayResize(g_last, g_n);
   ArrayResize(g_open_t, g_n);
   ArrayResize(g_dir, g_n);
   ArrayResize(g_entry, g_n);
   ArrayResize(g_vol, g_n);
   ArrayResize(g_live, g_n);
   g_pid[g_n - 1]        = pid;
   g_net[g_n - 1]        = 0.0;
   g_gross[g_n - 1]      = 0.0;
   g_swap[g_n - 1]       = 0.0;
   g_commission[g_n - 1] = 0.0;
   g_fee[g_n - 1]        = 0.0;
   g_last[g_n - 1]       = 0;
   g_open_t[g_n - 1] = 0;
   g_dir[g_n - 1]    = 0;
   g_entry[g_n - 1]  = 0.0;
   g_vol[g_n - 1]    = 0.0;
   g_live[g_n - 1]   = false;
  }

//+------------------------------------------------------------------+
bool CStatsKeeper::IsLogged(const ulong pid) const
  {
   for(int i = 0; i < l_n; i++)
      if(l_pid[i] == pid)
         return true;
   return false;
  }

//+------------------------------------------------------------------+
//| one finished trade -> one audit line (Phase 7 reads these)        |
//| detail = result;net;open time;minutes open;lots                  |
//+------------------------------------------------------------------+
void CStatsKeeper::LogTrade(const int idx)
  {
   ArrayResize(l_pid, l_n + 1);
   l_pid[l_n] = g_pid[idx];
   l_n++;

   double net = g_net[idx];
   string res = (MathAbs(net) < 0.005) ? "BE" : ((net > 0) ? "WIN" : "LOSS");
   int minutes = (int)((g_last[idx] - g_open_t[idx]) / 60);
   string detail = StringFormat("result=%s;net=%.2f;gross=%.2f;swap=%.2f;commission=%.2f;fee=%.2f;position_id=%s;open=%s;minutes=%d;lots=%.2f",
                                res, net, g_gross[idx], g_swap[idx],
                                g_commission[idx], g_fee[idx],
                                IntegerToString((long)g_pid[idx]),
                                TimeToString(g_open_t[idx], TIME_DATE | TIME_SECONDS),
                                minutes, g_vol[idx]);

   if(!PrepareLog())
      return;
   int h = FileOpen(ATST_LOG_FILE, FILE_READ | FILE_WRITE | FILE_CSV | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   int d = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   FileWrite(h,
             TimeToString(g_last[idx], TIME_DATE | TIME_SECONDS),
             m_symbol, m_lane_tag, "TRADE", (g_dir[idx] == 1) ? "BUY" : "SELL",
             "-", "-", "-", "-",
             DoubleToString(g_entry[idx], d), "-", "-", "-", "-",
             DoubleToString(g_vol[idx], 2),
             ATST_Safe(detail));
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| walk the broker's deal history and apply the owner's rule         |
//+------------------------------------------------------------------+
bool CStatsKeeper::Scan(const bool force)
  {
   datetime now = TimeCurrent();
   if(!force && m_last_scan > 0 && now - m_last_scan < 20)
      return false;
   m_last_scan = now;

   int dk = DayKey();
   if(dk != m_day_key)
     {
      m_day_key = dk;
      m_sig_today = 0;
      string g_all = "ATRSIG_" + IntegerToString((long)m_magic);
      string g_day = g_all + "_D" + IntegerToString(m_day_key);
      m_sig_today = GlobalVariableCheck(g_day) ? (int)GlobalVariableGet(g_day) : 0;
     }

   if(!HistorySelect(0, now + 3600))
      return false;

   g_n = 0;
   ArrayResize(g_pid, 0);
   ArrayResize(g_net, 0);
   ArrayResize(g_gross, 0);
   ArrayResize(g_swap, 0);
   ArrayResize(g_commission, 0);
   ArrayResize(g_fee, 0);
   ArrayResize(g_last, 0);

   MqlDateTime d0;
   TimeToStruct(now, d0);
   d0.hour = 0; d0.min = 0; d0.sec = 0;
   datetime day_start = StructToTime(d0);

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_magic)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != m_symbol)
         continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      ulong pid = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

      int idx = FindGroup(pid);
      if(idx < 0)
        {
         AddGroup(pid);
         idx = g_n - 1;
        }

      //--- the opening deal gives the trade's start, direction and price.
      //--- Its commission/fee is still included below in the full net cost.
      if(entry == DEAL_ENTRY_IN)
        {
         if(g_open_t[idx] == 0 || t < g_open_t[idx])
           {
            g_open_t[idx] = t;
            g_dir[idx]    = (HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_BUY) ? 1 : 2;
            g_entry[idx]  = HistoryDealGetDouble(ticket, DEAL_PRICE);
           }
         g_vol[idx] += HistoryDealGetDouble(ticket, DEAL_VOLUME);
        }

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double fee = HistoryDealGetDouble(ticket, DEAL_FEE);
      g_gross[idx] += profit;
      g_swap[idx] += swap;
      g_commission[idx] += commission;
      g_fee[idx] += fee;
      g_net[idx] += profit + swap + commission + fee;

      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
         if(t > g_last[idx])
            g_last[idx] = t;
     }


   //--- a trade that still has an open position is NOT finished yet:
   //--- its first partial may be banked, but it must not count as a
   //--- Win or Loss until the whole position is closed
   for(int i = 0; i < g_n; i++)
      g_live[i] = false;
   for(int p = 0; p < PositionsTotal(); p++)
     {
      ulong pt = PositionGetTicket(p);
      if(pt == 0)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol)
         continue;
      int k = FindGroup((ulong)PositionGetInteger(POSITION_IDENTIFIER));
      if(k >= 0)
         g_live[k] = true;
     }

   //--- one group = one trade = one result (owner's rule)
   m_win_today = 0; m_loss_today = 0; m_be_today = 0;
   m_win_all = 0;   m_loss_all = 0;   m_be_all = 0;
   m_net_today = 0.0; m_net_all = 0.0;

   for(int i = 0; i < g_n; i++)
     {
      if(g_live[i])
         continue;
      double net = g_net[i];
      //--- treat anything under half a cent as exactly zero = BE
      bool is_be = (MathAbs(net) < 0.005);
      if(is_be)        m_be_all++;
      else if(net > 0) m_win_all++;
      else             m_loss_all++;
      m_net_all += net;

      if(g_last[i] >= day_start)
        {
         if(is_be)        m_be_today++;
         else if(net > 0) m_win_today++;
         else             m_loss_today++;
         m_net_today += net;
        }
     }

   //--- write each finished trade to the audit log once (Phase 7 reads it)
   for(int i = 0; i < g_n; i++)
     {
      if(g_live[i] || g_open_t[i] == 0 || g_last[i] <= m_log_from || IsLogged(g_pid[i]))
         continue;
      LogTrade(i);
     }
   return true;
  }

//+------------------------------------------------------------------+
string CStatsKeeper::TodayText(void) const
  {
   return StringFormat("Today: Num of Signal: %d, Win: %d, Loss: %d, BE: %d",
                       m_sig_today, m_win_today, m_loss_today, m_be_today);
  }

string CStatsKeeper::AllTimeText(void) const
  {
   return StringFormat("All Time: Num of Signal: %d, Win: %d, Loss: %d, BE: %d",
                       m_sig_all, m_win_all, m_loss_all, m_be_all);
  }
//+------------------------------------------------------------------+
#endif // AUTOTRADER_STATS_KEEPER_MQH
