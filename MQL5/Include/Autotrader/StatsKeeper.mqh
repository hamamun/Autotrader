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
//| MQL5\Files\Autotrader_log.csv for later auditing of the 98%.      |
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
   datetime g_last[];
   int      g_n;

   int      DayKey(void) const;
   int      FindGroup(const ulong pid);
   void     AddGroup(const ulong pid);
   bool     WriteHeader(void);

public:
            CStatsKeeper(void);
   bool     Init(const string symbol, const ulong magic, const string lane_tag);
   //--- a new signal was published (latched) -> count it and log it
   void     OnSignal(const int dir, const int score, const int threshold,
                     const string regime, const string detail);
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
void CStatsKeeper::Log(const string event, const string detail)
  {
   //--- rotate: the counters come from the broker history, never from
   //--- this file, so an oversized log is simply started again
   if(FileIsExist(ATST_LOG_FILE))
     {
      long sz = FileGetInteger(ATST_LOG_FILE, FILE_SIZE);
      if(sz > ATST_LOG_MAX_BYTES)
        {
         FileDelete(ATST_LOG_FILE);
         WriteHeader();
        }
     }

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
                            const string regime, const string detail)
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

   int h = FileOpen(ATST_LOG_FILE, FILE_READ | FILE_WRITE | FILE_CSV | FILE_SHARE_READ, ',');
   if(h != INVALID_HANDLE)
     {
      FileSeek(h, 0, SEEK_END);
      int d = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      string dir_s = (dir == 1) ? "BUY" : ((dir == 2) ? "SELL" : "HOLD");
      FileWrite(h,
                TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                m_symbol, m_lane_tag, "SIGNAL", dir_s, score, threshold,
                ATST_Safe(regime),
                DoubleToString(SymbolInfoDouble(m_symbol, SYMBOL_BID), d),
                DoubleToString(0.0, d), DoubleToString(0.0, d),
                DoubleToString(0.0, d), DoubleToString(0.0, d),
                DoubleToString(0.0, d), DoubleToString(0.0, 2),
                ATST_Safe(detail));
      FileClose(h);
     }
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
   ArrayResize(g_last, g_n);
   g_pid[g_n - 1]  = pid;
   g_net[g_n - 1]  = 0.0;
   g_last[g_n - 1] = 0;
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
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;

      ulong pid = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      double net = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                   HistoryDealGetDouble(ticket, DEAL_SWAP) +
                   HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

      int idx = FindGroup(pid);
      if(idx < 0)
        {
         AddGroup(pid);
         idx = g_n - 1;
        }
      g_net[idx] += net;
      if(t > g_last[idx])
         g_last[idx] = t;
     }

   //--- one group = one trade = one result (owner's rule)
   m_win_today = 0; m_loss_today = 0; m_be_today = 0;
   m_win_all = 0;   m_loss_all = 0;   m_be_all = 0;
   m_net_today = 0.0; m_net_all = 0.0;

   for(int i = 0; i < g_n; i++)
     {
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
