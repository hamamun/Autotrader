//+------------------------------------------------------------------+
//|                                                  Journal.mqh     |
//|   Every signal the EA displays is written down and then checked   |
//|   against what price actually did: did it reach TP1 before SL?    |
//|   That is how a claimed hit rate becomes a measured one.          |
//|                                                                   |
//|   Works whether or not AUTO mode is on - it measures the SIGNAL,  |
//|   not the trades.                                                 |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_JOURNAL_MQH
#define AUTOTRADER_JOURNAL_MQH

#include "Types.mqh"

#define AT_JOURNAL_MAX_PENDING 300
#define AT_JOURNAL_TIMEOUT_BARS 12      // same horizon as the labeller

struct SAtPending
  {
   datetime  bar_time;     // bar the signal was generated on
   int       tf_index;
   ENUM_AT_DIR dir;
   double    entry;
   double    sl;
   double    tp;
   double    score;
   double    confidence;
   int       checks_passed;
   int       checks_total;
  };

class CAtJournal
  {
private:
   string   m_symbol;
   string   m_file;
   int      m_handle;
   SAtPending m_pending[AT_JOURNAL_MAX_PENDING];
   int      m_pending_count;
   //--- resolved counters per timeframe
   int      m_tp[AT_MAX_TF];
   int      m_sl[AT_MAX_TF];
   int      m_timeout[AT_MAX_TF];

   void     WriteRow(const SAtPending &p,const int result,const datetime resolved);
   void     RemoveAt(const int idx);

public:
   void     Init(const string symbol,const string file);
   void     Deinit();
   void     AddSignal(const SATSignal &s,const int tf_index);
   void     CheckPending();
   string   StatsLine() const;
   int      Resolved(const int tf) const { return(m_tp[tf]+m_sl[tf]+m_timeout[tf]); }
   int      HitRate(const int tf) const;
  };

//+------------------------------------------------------------------+
void CAtJournal::Init(const string symbol,const string file)
  {
   m_symbol        = symbol;
   m_file          = file;
   m_pending_count = 0;
   for(int i=0;i<AT_MAX_TF;i++)
     {
      m_tp[i]=0; m_sl[i]=0; m_timeout[i]=0;
     }

   bool exists = FileIsExist(m_file,FILE_COMMON);
   m_handle = FileOpen(m_file,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',');
   if(m_handle==INVALID_HANDLE)
     {
      PrintFormat("[Autotrader] journal unavailable (%d) - stats will not persist.",GetLastError());
      return;
     }
   FileSeek(m_handle,0,SEEK_END);
   if(!exists)
      FileWrite(m_handle,"signal_time","symbol","tf","dir","score","confidence",
                "entry","sl","tp","checks","result","resolved_time");
  }

//+------------------------------------------------------------------+
void CAtJournal::Deinit()
  {
   if(m_handle!=INVALID_HANDLE)
     {
      FileClose(m_handle);
      m_handle=INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
void CAtJournal::RemoveAt(const int idx)
  {
   for(int i=idx;i<m_pending_count-1;i++)
      m_pending[i]=m_pending[i+1];
   m_pending_count--;
  }

//+------------------------------------------------------------------+
void CAtJournal::WriteRow(const SAtPending &p,const int result,const datetime resolved)
  {
   if(m_handle==INVALID_HANDLE)
      return;
   string tfname = (p.tf_index==0 ? "M5" : (p.tf_index==1 ? "M15" : "M30"));
   string dirname= (p.dir==AT_BUY ? "BUY" : (p.dir==AT_SELL ? "SELL" : "HOLD"));
   FileWrite(m_handle,
             TimeToString(p.bar_time,TIME_DATE|TIME_MINUTES),m_symbol,tfname,dirname,
             DoubleToString(p.score,2),DoubleToString(p.confidence,1),
             DoubleToString(p.entry,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS)),
             DoubleToString(p.sl,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS)),
             DoubleToString(p.tp,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS)),
             StringFormat("%d/%d",p.checks_passed,p.checks_total),
             (result==1 ? "TP1" : (result==-1 ? "SL" : "TIMEOUT")),
             TimeToString(resolved,TIME_DATE|TIME_MINUTES));
   FileFlush(m_handle);
  }

//+------------------------------------------------------------------+
void CAtJournal::AddSignal(const SATSignal &s,const int tf_index)
  {
   if(s.dir==AT_HOLD || m_pending_count>=AT_JOURNAL_MAX_PENDING)
      return;
   SAtPending p;
   p.bar_time      = s.bar_time;
   p.tf_index      = tf_index;
   p.dir           = s.dir;
   p.entry         = s.entry;
   p.sl            = s.sl;
   p.tp            = s.tp1;
   p.score         = s.score;
   p.confidence    = s.confidence;
   p.checks_passed = s.checks_passed;
   p.checks_total  = s.checks_total;
   m_pending[m_pending_count++] = p;
  }

//+------------------------------------------------------------------+
//| Called once per closed M5 bar. Resolves signals on M5 highs/lows. |
//+------------------------------------------------------------------+
void CAtJournal::CheckPending()
  {
   for(int i=m_pending_count-1;i>=0;i--)
     {
      //--- how many closed M5 bars since the signal
      int idx = iBarShift(m_symbol,PERIOD_M5,m_pending[i].bar_time,false);
      if(idx<1)
         continue;

      int result = 0;
      datetime resolved_time = 0;
      int bars = MathMin(idx,AT_JOURNAL_TIMEOUT_BARS);

      for(int b=idx;b>b-index_of_first_closed(bars) && b>=1;b--)
        {
         double hi = iHigh(m_symbol,PERIOD_M5,b);
         double lo = iLow(m_symbol,PERIOD_M5,b);
         if(m_pending[i].dir==AT_BUY)
           {
            if(lo<=m_pending[i].sl) { result=-1; resolved_time=iTime(m_symbol,PERIOD_M5,b); break; }
            if(hi>=m_pending[i].tp) { result= 1; resolved_time=iTime(m_symbol,PERIOD_M5,b); break; }
           }
         else if(m_pending[i].dir==AT_SELL)
           {
            if(hi>=m_pending[i].sl) { result=-1; resolved_time=iTime(m_symbol,PERIOD_M5,b); break; }
            if(lo<=m_pending[i].tp) { result= 1; resolved_time=iTime(m_symbol,PERIOD_M5,b); break; }
           }
        }

      if(result==0 && bars_since>=AT_JOURNAL_TIMEOUT_BARS)
        {
         //--- time is up, count it as a timeout with whatever the move was
         result        = 2;
         resolved_time = iTime(m_symbol,PERIOD_M5,1);
        }

      if(result==0)
         continue;

      if(result==1)        m_tp[m_pending[i].tf_index]++;
      else if(result==-1)  m_sl[m_pending[i].tf_index]++;
      else                 m_timeout[m_pending[i].tf_index]++;

      WriteRow(m_pending[i],(result==1?1:(result==-1?-1:0)),resolved_time);
      RemoveAt(i);
     }
  }

//+------------------------------------------------------------------+
int CAtJournal::HitRate(const int tf) const
  {
   int decided = m_tp[tf]+m_sl[tf];
   if(decided<=0)
      return(-1);
   return((int)MathRound(100.0*m_tp[tf]/decided));
  }

//+------------------------------------------------------------------+
string CAtJournal::StatsLine() const
  {
   string s = "Measured signal hit rate (TP1 before SL):";
   for(int i=0;i<AT_MAX_TF;i++)
     {
      string tfname = (i==0?"M5":(i==1?"M15":"M30"));
      int n = Resolved(i);
      if(n<=0)
        {
         s += StringFormat("   %s -- (n=0)",tfname);
         continue;
        }
      int hr = HitRate(i);
      s += StringFormat("   %s %d%% (n=%d)",tfname,hr,n);
     }
   return(s);
  }

#endif // AUTOTRADER_JOURNAL_MQH
//+------------------------------------------------------------------+
