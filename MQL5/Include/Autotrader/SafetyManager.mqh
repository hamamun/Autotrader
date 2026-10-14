//+------------------------------------------------------------------+
//| SafetyManager.mqh                                                 |
//| Autotrader Phase 5 - the safety layer.                            |
//|                                                                   |
//| Owner decision: NO session blocking - the EA may trade whenever   |
//| conditions suit. This layer is therefore only a FREEZE, and it    |
//| freezes for one honest reason at a time:                          |
//|   * trading is not permitted (terminal / EA / account / symbol)   |
//|   * the broker quote is stale or the market is shut               |
//|   * the spread is more expensive than this symbol's own limit     |
//|   * a HIGH-impact news event is imminent or just landed           |
//|   * today's loss limit has been reached -> stand down until tomorrow|
//|   * equity has fallen through the drawdown floor                  |
//|   * a gap shock just happened (open vs previous close)            |
//|                                                                   |
//| It only stops NEW trades. Open trades keep being managed - their  |
//| stop, break-even and ladder never get abandoned.                  |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_SAFETY_MANAGER_MQH
#define AUTOTRADER_SAFETY_MANAGER_MQH

//--- news freeze window (minutes before / after a HIGH impact event)
#define ATSF_NEWS_AHEAD_MIN  30
#define ATSF_NEWS_AFTER_MIN  15
//--- account protection, auto-derived (3 x the 1% risk baseline)
#define ATSF_DAILY_LOSS_PCT   3.0
#define ATSF_EQUITY_FLOOR_PCT 15.0
//--- gap shock: opening jump bigger than this many ATRs freezes entries
#define ATSF_GAP_ATR          3.0
#define ATSF_GAP_BARS         3

class CSafetyManager
  {
private:
   bool      m_can_open;
   bool      m_alert;          // true = the STATUS row should be red
   string    m_block;          // "" = nothing is blocking a new trade
   //--- news
   bool      m_calendar_ok;
   bool      m_calendar_warned;
   datetime  m_news_checked;
   datetime  m_freeze_from;
   datetime  m_freeze_to;
   string    m_news_what;
   //--- day accounting
   int       m_day_key;
   double    m_day_start_equity;
   double    m_day_realized;
   double    m_peak_equity;
   bool      m_standdown;
   string    m_standdown_why;
   //--- gap shock
   int       m_gap_bars_left;
   long      m_account;

   int       DayKey(void) const;
   void      LoadState(void);
   void      SaveState(void);
   bool      ScanNewsCurrency(CSymbolIntelligence &profile, const string currency,
                              const datetime from, const datetime to);

public:
              CSafetyManager(void);
   void       Init(void);
   //--- feed today's realised result (from the stats keeper) then refresh
   void       SetDayRealized(const double value);
   //--- called by the EA on every new bar of the lane timeframe
   void       CheckGap(const double open_now, const double close_prev, const double atr);
   //--- main pass
   void       Refresh(CSymbolIntelligence &profile, const int quote_age_sec);

   bool       CanOpen(void)     const { return m_can_open; }
   bool       Alert(void)       const { return m_alert; }
   string     Block(void)       const { return m_block; }
   string     NewsWhat(void)    const { return m_news_what; }
   double     DayStartEquity(void) const { return m_day_start_equity; }
   double     DayRealized(void) const { return m_day_realized; }
   double     DailyLimitMoney(void) const { return m_day_start_equity * ATSF_DAILY_LOSS_PCT / 100.0; }
   bool       Standdown(void)   const { return m_standdown; }
   bool       CalendarActive(void) const { return m_calendar_ok; }
  };

//+------------------------------------------------------------------+
CSafetyManager::CSafetyManager(void)
  {
   m_can_open = false;
   m_alert = false;
   m_block = "";
   m_calendar_ok = true;
   m_calendar_warned = false;
   m_news_checked = 0;
   m_freeze_from = 0;
   m_freeze_to = 0;
   m_news_what = "";
   m_day_key = 0;
   m_day_start_equity = 0.0;
   m_day_realized = 0.0;
   m_peak_equity = 0.0;
   m_standdown = false;
   m_standdown_why = "";
   m_gap_bars_left = 0;
   m_account = 0;
  }

int CSafetyManager::DayKey(void) const
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

//+------------------------------------------------------------------+
//| day-start equity and peak equity live in terminal global          |
//| variables, so a restart or a reconnection cannot erase them.      |
//+------------------------------------------------------------------+
void CSafetyManager::LoadState(void)
  {
   m_account = AccountInfoInteger(ACCOUNT_LOGIN);
   string gk = "ATREQ_" + IntegerToString(m_account) + "_" + IntegerToString(m_day_key);
   string pk = "ATRPEAK_" + IntegerToString(m_account);

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(GlobalVariableCheck(gk))
      m_day_start_equity = GlobalVariableGet(gk);
   else
     {
      m_day_start_equity = eq;
      GlobalVariableSet(gk, eq);
     }
   if(GlobalVariableCheck(pk))
      m_peak_equity = GlobalVariableGet(pk);
   else
      m_peak_equity = eq;
   if(eq > m_peak_equity)
     {
      m_peak_equity = eq;
      GlobalVariableSet(pk, eq);
     }
  }

void CSafetyManager::SaveState(void)
  {
   string gk = "ATREQ_" + IntegerToString(m_account) + "_" + IntegerToString(m_day_key);
   GlobalVariableSet(gk, m_day_start_equity);
   string pk = "ATRPEAK_" + IntegerToString(m_account);
   GlobalVariableSet(pk, m_peak_equity);
  }

void CSafetyManager::Init(void)
  {
   m_day_key = DayKey();
   LoadState();
   //--- old day-start snapshots are cleaned out once a week
   GlobalVariablesFlush();
  }

void CSafetyManager::SetDayRealized(const double value)
  {
   m_day_realized = value;
  }

//+------------------------------------------------------------------+
//| a new bar opened with a jump - freeze entries for a few bars      |
//+------------------------------------------------------------------+
void CSafetyManager::CheckGap(const double open_now, const double close_prev,
                              const double atr)
  {
   if(atr <= 0.0 || open_now <= 0.0 || close_prev <= 0.0)
      return;
   if(MathAbs(open_now - close_prev) >= ATSF_GAP_ATR * atr)
      m_gap_bars_left = ATSF_GAP_BARS;
   else if(m_gap_bars_left > 0)
      m_gap_bars_left--;
  }

//+------------------------------------------------------------------+
//| HIGH-impact news for this symbol's own currencies                 |
//+------------------------------------------------------------------+
bool CSafetyManager::ScanNewsCurrency(CSymbolIntelligence &profile,
                                      const string currency,
                                      const datetime from, const datetime to)
  {
   if(currency == "")
      return false;
   MqlCalendarValue values[];
   if(!CalendarValueHistory(values, from, to, NULL, currency))
      return false;

   int total = ArraySize(values);
   for(int i = 0; i < total; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;
      datetime t = values[i].time;
      datetime f = t - ATSF_NEWS_AHEAD_MIN * 60;
      datetime g = t + ATSF_NEWS_AFTER_MIN * 60;
      if(m_freeze_from == 0 || f < m_freeze_from) m_freeze_from = f;
      if(g > m_freeze_to)                          m_freeze_to = g;
      m_news_what = currency + " news";
     }
   return true;
  }

//+------------------------------------------------------------------+
//| main pass                                                         |
//+------------------------------------------------------------------+
void CSafetyManager::Refresh(CSymbolIntelligence &profile, const int quote_age_sec)
  {
   datetime now = TimeCurrent();

   //--- a new trading day? restart the day's accounting
   int dk = DayKey();
   if(dk != m_day_key)
     {
      m_day_key = dk;
      m_standdown = false;
      m_standdown_why = "";
      m_day_realized = 0.0;
      LoadState();
     }

   //--- keep the equity high-water mark current
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > m_peak_equity)
     {
      m_peak_equity = eq;
      SaveState();
     }

   //--- news scan is expensive: once every 5 minutes is plenty
   if(m_calendar_ok && (m_news_checked == 0 || now - m_news_checked >= 300))
     {
      m_news_checked = now;
      m_freeze_from = 0;
      m_freeze_to = 0;
      m_news_what = "";
      datetime from = now - ATSF_NEWS_AFTER_MIN * 60;
      datetime to   = now + ATSF_NEWS_AHEAD_MIN * 60;
      bool got1 = ScanNewsCurrency(profile, profile.ProfitCurrency(), from, to);
      bool got2 = ScanNewsCurrency(profile, profile.BaseCurrency(), from, to);
      if(!got1 && !got2)
        {
         m_calendar_ok = true;      // try again later - the calendar may be busy
         if(!m_calendar_warned)
           {
            m_calendar_warned = true;
            Print("Autotrader: economic calendar unavailable - news guard inactive");
           }
        }
     }

   m_block = "";
   m_alert = false;

   //--- 1. is trading permitted at all?
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      m_block = "terminal trading is disabled";
   else if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      m_block = "this EA is not allowed to trade";
   else if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      m_block = "account trading is disabled";
   else if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      m_block = "expert trading is disabled on this account";
   else if(!profile.TradeEnabled())
      m_block = "broker has closed trading on this symbol";

   //--- 2. is the quote alive?
   if(m_block == "" && quote_age_sec > 120)
     {
      MqlDateTime wd;
      TimeToStruct(now, wd);
      bool weekend = (wd.day_of_week == 0 || wd.day_of_week == 6);
      if(weekend && profile.SymbolClass() != AT_CLASS_CRYPTO)
         m_block = "market closed for the weekend";
      else
         m_block = "no fresh broker quote";
     }

   //--- 3. is this symbol's spread still cheap enough?
   if(m_block == "" && !profile.SpreadOk())
      m_block = StringFormat("spread too expensive (%d pts vs %.0f limit)",
                             (int)profile.SpreadNowPts(), profile.SpreadLimitPts());

   //--- 4. news freeze
   if(m_block == "" && m_freeze_from != 0 && now >= m_freeze_from && now <= m_freeze_to)
     {
      m_block = "news freeze - " + m_news_what;
      m_alert = true;
     }

   //--- 5. gap shock
   if(m_block == "" && m_gap_bars_left > 0)
      m_block = StringFormat("gap shock - waiting %d bar(s)", m_gap_bars_left);

   //--- 6. today's loss limit
   double limit = DailyLimitMoney();
   if(limit > 0.0 && m_day_realized <= -limit)
     {
      m_standdown = true;
      m_standdown_why = StringFormat("daily loss limit reached (%.2f of %.2f)",
                                     m_day_realized, limit);
     }
   if(m_block == "" && m_standdown)
     {
      m_block = "stand-down until tomorrow - " + m_standdown_why;
      m_alert = true;
     }

   //--- 7. equity floor
   if(m_block == "" && m_peak_equity > 0.0 &&
      eq < m_peak_equity * (1.0 - ATSF_EQUITY_FLOOR_PCT / 100.0))
     {
      m_block = "equity floor breached - trading paused";
      m_alert = true;
     }

   m_can_open = (m_block == "");
  }
//+------------------------------------------------------------------+
#endif // AUTOTRADER_SAFETY_MANAGER_MQH
