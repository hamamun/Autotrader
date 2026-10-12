//+------------------------------------------------------------------+
//|                                             SignalEngine.mqh     |
//|   Multi timeframe confluence engine: M30 bias / M15 setup /      |
//|   M5 trigger. Pure MQL5, no external dependency.                 |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_SIGNAL_ENGINE_MQH
#define AUTOTRADER_SIGNAL_ENGINE_MQH

#include "Types.mqh"

//--- indicator handles of one timeframe
struct SATfInd
  {
   int h_ema_fast;
   int h_ema_slow;
   int h_ema_bias;
   int h_atr;
   int h_adx;
   int h_rsi;
   int h_macd;

   void Reset()
     {
      h_ema_fast = INVALID_HANDLE;
      h_ema_slow = INVALID_HANDLE;
      h_ema_bias = INVALID_HANDLE;
      h_atr      = INVALID_HANDLE;
      h_adx      = INVALID_HANDLE;
      h_rsi      = INVALID_HANDLE;
      h_macd     = INVALID_HANDLE;
     }

   bool Valid() const
     {
      return (h_ema_fast != INVALID_HANDLE && h_ema_slow != INVALID_HANDLE &&
              h_ema_bias != INVALID_HANDLE && h_atr      != INVALID_HANDLE &&
              h_adx      != INVALID_HANDLE && h_rsi      != INVALID_HANDLE &&
              h_macd     != INVALID_HANDLE);
     }
  };

//+------------------------------------------------------------------+
class CAtSignalEngine
  {
private:
   string           m_symbol;
   SATSettings      m_cfg;
   ENUM_TIMEFRAMES  m_tf[AT_MAX_TF];
   SATfInd          m_ind[AT_MAX_TF];
   datetime         m_last_bar[AT_MAX_TF];
   //--- cache so we do not recompute on every tick
   SATSignal        m_cache[AT_MAX_TF];
   datetime         m_cache_bar[AT_MAX_TF];

   //--- raw buffer read, shift 1 = last closed bar
   double           Buf(const int handle,const int buffer,const int shift) const;
   bool             BuildHandles();
   double           IndATR(const int i,in int shift) const;
   double           SwingLow(const int i,const int bars) const;
   double           SwingHigh(const int i,const int bars) const;

   double           TrendVote(const int i,double &stretch_atr) const;
   double           MomentumVote(const int i) const;
   double           StructureVote(const int i) const;

   bool             SessionOK() const;
   bool             NewsBlocked() const;

public:
   void             Init(const string symbol,const SATSettings &cfg);
   void             Deinit();
   bool             Ready() const;
   bool             NewBar(const int i);
   int              Count() const { return AT_MAX_TF; }
   int              IndexOf(const ENUM_TIMEFRAMES tf) const;
   ENUM_TIMEFRAMES  Tf(const int i) const { return m_tf[i]; }
   ENUM_AT_ROLE     Role(const int i) const;
   bool             Evaluate(const int i,SATSignal &out,int &checks_passed,int &checks_total);
   bool             BuildFeatures(double &f[]) const;
   SATSettings      Cfg() const { return m_cfg; }
   void             Configure(const SATSettings &cfg) { m_cfg = cfg; }
  };

//+------------------------------------------------------------------+
void CAtSignalEngine::Init(const string symbol,const SATSettings &cfg)
  {
   m_symbol = symbol;
   m_cfg    = cfg;

   m_tf[0] = PERIOD_M5;    // trigger
   m_tf[1] = PERIOD_M15;   // setup
   m_tf[2] = PERIOD_M30;   // bias

   for(int i=0;i<AT_MAX_TF;i++)
     {
      m_ind[i].Reset();
      m_last_bar[i]  = 0;
      m_cache_bar[i] = 0;
      ZeroMemory(m_cache[i]);
     }
  }

//+------------------------------------------------------------------+
void CAtSignalEngine::Deinit()
  {
   for(int i=0;i<AT_MAX_TF;i++)
     {
      if(m_ind[i].h_ema_fast!=INVALID_HANDLE) IndicatorRelease(m_ind[i].h_ema_fast);
      if(m_ind[i].h_ema_slow!=INVALID_HANDLE) IndicatorRelease(m_ind[i].h_ema_slow);
      if(m_ind[i].h_ema_bias!=INVALID_HANDLE) IndicatorRelease(m_ind[i].h_ema_bias);
      if(m_ind[i].h_atr     !=INVALID_HANDLE) IndicatorRelease(m_ind[i].h_atr);
      if(m_ind[i].h_adx     !=INVALID_HANDLE) IndicatorRelease(m_ind[i].h_adx);
      if(m_ind[i].h_rsi     !=INVALID_HANDLE) IndicatorRelease(m_ind[i].h_rsi);
      if(m_ind[i].h_macd    !=INVALID_HANDLE) IndicatorRelease(m_ind[i].h_macd);
      m_ind[i].Reset();
     }
  }

//+------------------------------------------------------------------+
//| Create indicator handles once per timeframe (avoid handle leak)  |
//+------------------------------------------------------------------+
bool CAtSignalEngine::Ready() const
  {
   for(int i=0;i<AT_MAX_TF;i++)
     {
      if(!m_ind[i].Valid())
         return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| helper: create handles lazily                                    |
//+------------------------------------------------------------------+
bool CAtSignalEngine::BuildHandles()
  {
   for(int i=0;i<AT_MAX_TF;i++)
     {
      if(m_ind[i].Valid())
         continue;
      ENUM_TIMEFRAMES tf = m_tf[i];
      m_ind[i].h_ema_fast = iMA(m_symbol,tf,m_cfg.ema_fast,0,MODE_EMA,PRICE_CLOSE);
      m_ind[i].h_ema_slow = iMA(m_symbol,tf,m_cfg.ema_slow,0,MODE_EMA,PRICE_CLOSE);
      m_ind[i].h_ema_bias = iMA(m_symbol,tf,m_cfg.ema_bias,0,MODE_EMA,PRICE_CLOSE);
      m_ind[i].h_atr      = iATR(m_symbol,tf,m_cfg.atr_period);
      m_ind[i].h_adx      = iADX(m_symbol,tf,m_cfg.adx_period);
      m_ind[i].h_rsi      = iRSI(m_symbol,tf,m_cfg.rsi_period,PRICE_CLOSE);
      m_ind[i].h_macd     = iMACD(m_symbol,tf,m_cfg.macd_fast,m_cfg.macd_slow,m_cfg.macd_signal,PRICE_CLOSE);
     }
   return(Ready());
  }

//+------------------------------------------------------------------+
double CAtSignalEngine::Buf(const int handle,const int buffer,const int shift) const
  {
   if(handle==INVALID_HANDLE)
      return(0.0);
   double tmp[];
   if(CopyBuffer(handle,buffer,shift,1,tmp)!=1)
      return(0.0);
   return(tmp[0]);
  }

//+------------------------------------------------------------------+
double CAtSignalEngine::IndATR(const int i,const int shift) const
  {
   return(Buf(m_ind[i].h_atr,0,shift));
  }

//+------------------------------------------------------------------+
double CAtSignalEngine::SwingLow(const int i,const int bars) const
  {
   int idx = iLowest(m_symbol,m_tf[i],MODE_LOW,bars,1);
   if(idx<0)
      return(0.0);
   return(iLow(m_symbol,m_tf[i],idx));
  }

//+------------------------------------------------------------------+
double CAtSignalEngine::SwingHigh(const int i,const int bars) const
  {
   int idx = iHighest(m_symbol,m_tf[i],MODE_HIGH,bars,1);
   if(idx<0)
      return(0.0);
   return(iHigh(m_symbol,m_tf[i],idx));
  }

//+------------------------------------------------------------------+
//| 1) TREND vote  (-1 .. +1)  uses EMA stack + slope + HTF bias      |
//+------------------------------------------------------------------+
double CAtSignalEngine::TrendVote(const int i,double &stretch_atr) const
  {
   double emaF  = Buf(m_ind[i].h_ema_fast,0,1);
   double emaS  = Buf(m_ind[i].h_ema_slow,0,1);
   double emaB  = Buf(m_ind[i].h_ema_bias,0,1);
   double emaS3 = Buf(m_ind[i].h_ema_slow,0,4);
   double close = iClose(m_symbol,m_tf[i],1);
   double atr   = IndATR(i,1);

   stretch_atr = (atr>0.0) ? MathAbs(close-emaB)/atr : 0.0;

   double vote = 0.0;

   if(emaF>emaS && close>emaB)
      vote += 1.0;
   else
      if(emaF<emaS && close<emaB)
         vote -= 1.0;

   //--- slope of the slow EMA (3 bars) adds / removes conviction
   if(emaS3>0.0)
     {
      double slope = (emaS-emaS3)/emaS3;
      vote += MathMax(-0.5,MathMin(0.5,slope*400.0));
     }

   return(MathMax(-1.0,MathMin(1.0,vote)));
  }

//+------------------------------------------------------------------+
//| 2) MOMENTUM vote (-1 .. +1) MACD histogram + RSI                  |
//+------------------------------------------------------------------+
double CAtSignalEngine::MomentumVote(const int i) const
  {
   //--- iMACD exposes only main(0) and signal(1); histogram = main - signal
   double macd_hist   = Buf(m_ind[i].h_macd,0,1)-Buf(m_ind[i].h_macd,1,1);
   double macd_hist2  = Buf(m_ind[i].h_macd,0,2)-Buf(m_ind[i].h_macd,1,2);
   double rsi         = Buf(m_ind[i].h_rsi,0,1);
   double atr         = IndATR(i,1);
   double vote        = 0.0;

   //--- MACD histogram: sign + rising/falling
   if(macd_hist>0.0)
      vote += 0.6;
   else
      if(macd_hist<0.0)
         vote -= 0.6;

   if(macd_hist>macd_hist2)
      vote += 0.2;
   else
      if(macd_hist<macd_hist2)
         vote -= 0.2;

   //--- RSI above / below 50, damped at extremes
   if(rsi>50.0)
      vote += 0.2 * MathMin(1.0,(rsi-50.0)/20.0);
   else
      if(rsi<50.0)
         vote -= 0.2 * MathMin(1.0,(50.0-rsi)/20.0);

   //--- exhaustion: extreme RSI reduces the vote
   if(rsi>=m_cfg.rsi_overbought && vote>0.0)
      vote *= 0.5;
   if(rsi<=m_cfg.rsi_oversold && vote<0.0)
      vote *= 0.5;

   if(atr<=0.0)
      vote = 0.0;

   return(MathMax(-1.0,MathMin(1.0,vote)));
  }

//+------------------------------------------------------------------+
//| 3) STRUCTURE vote (-1 .. +1)  break of swing + higher highs       |
//+------------------------------------------------------------------+
double CAtSignalEngine::StructureVote(const int i) const
  {
   int    lb    = m_cfg.swing_lookback;
   double hi    = SwingHigh(i,lb);
   double lo    = SwingLow(i,lb);
   double close = iClose(m_symbol,m_tf[i],1);
   double atr   = IndATR(i,1);
   if(atr<=0.0 || hi<=lo)
      return(0.0);

   double pos = (close-lo)/(hi-lo);     // 0 = at lows, 1 = at highs
   double vote = 0.0;

   if(pos>0.75)
      vote = 0.8;
   else
      if(pos<0.25)
         vote = -0.8;
      else
         vote = (pos-0.5)*0.8;

   //--- last two closed bars: higher high + higher low = continuation
   double h1 = iHigh(m_symbol,m_tf[i],1), h2 = iHigh(m_symbol,m_tf[i],2);
   double l1 = iLow(m_symbol,m_tf[i],1),  l2 = iLow(m_symbol,m_tf[i],2);
   if(h1>h2 && l1>l2)
      vote += 0.2;
   if(h1<h2 && l1<l2)
      vote -= 0.2;

   return(MathMax(-1.0,MathMin(1.0,vote)));
  }

//+------------------------------------------------------------------+
bool CAtSignalEngine::SessionOK() const
  {
   if(!m_cfg.use_session_filter)
      return(true);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   int h = dt.hour;
   bool london = (m_cfg.london_start<=m_cfg.london_end)
                 ? (h>=m_cfg.london_start && h<m_cfg.london_end)
                 : (h>=m_cfg.london_start || h<m_cfg.london_end);
   bool ny     = (m_cfg.ny_start<=m_cfg.ny_end)
                 ? (h>=m_cfg.ny_start && h<m_cfg.ny_end)
                 : (h>=m_cfg.ny_start || h<m_cfg.ny_end);
   return(london || ny);
  }

//+------------------------------------------------------------------+
bool CAtSignalEngine::NewsBlocked() const
  {
   if(!m_cfg.use_news_filter)
      return(false);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   int now_min  = dt.hour*60+dt.min;
   int news_min = m_cfg.news_hour*60+m_cfg.news_minute;
   int diff     = now_min-news_min;
   if(diff<0)
      diff += 1440;
   return(diff <= m_cfg.news_block_minutes);
  }

//+------------------------------------------------------------------+
int CAtSignalEngine::IndexOf(const ENUM_TIMEFRAMES tf) const
  {
   for(int i=0;i<AT_MAX_TF;i++)
      if(m_tf[i]==tf)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
ENUM_AT_ROLE CAtSignalEngine::Role(const int i) const
  {
   if(i==0) return(AT_ROLE_TRIGGER);
   if(i==1) return(AT_ROLE_SETUP);
   return(AT_ROLE_BIAS);
  }

//+------------------------------------------------------------------+
bool CAtSignalEngine::NewBar(const int i)
  {
   datetime t = iTime(m_symbol,m_tf[i],0);
   if(t==0)
      return(false);
   if(t!=m_last_bar[i])
     {
      m_last_bar[i] = t;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| MAIN: evaluate one timeframe                                     |
//| Only closed bars (shift 1) are used -> signals never repaint.     |
//+------------------------------------------------------------------+
bool CAtSignalEngine::Evaluate(const int i,SATSignal &out,int &checks_passed,int &checks_total)
  {
   if(!BuildHandles())
      return(false);

   ENUM_TIMEFRAMES tf = m_tf[i];
   double stretch = 0.0;
   double trend   = TrendVote(i,stretch);
   double momo    = MomentumVote(i);
   double struct_ = StructureVote(i);

   double wsum = m_cfg.w_trend+m_cfg.w_momentum+m_cfg.w_structure;
   if(wsum<=0.0)
      wsum = 1.0;

   double score = (trend*m_cfg.w_trend + momo*m_cfg.w_momentum + struct_*m_cfg.w_structure)/wsum;

   double adx = Buf(m_ind[i].h_adx,0,1);
   double atr = IndATR(i,1);
   if(atr<=0.0)
      return(false);

   //--- choppy market halves conviction
   bool trending = (adx>=m_cfg.adx_min);
   if(!trending)
      score *= 0.5;

   double score100 = MathMax(-100.0,MathMin(100.0,score*100.0));

   out.tf        = tf;
   out.role      = Role(i);
   out.score     = score100;
   out.atr       = atr;
   out.bar_time  = iTime(m_symbol,tf,1);
   out.dir       = AT_HOLD;
   out.reason    = "";

   //--- direction from score, HOLD inside the dead zone
   if(score100>= m_cfg.score_threshold)
      out.dir = AT_BUY;
   else
      if(score100<=-m_cfg.score_threshold)
         out.dir = AT_SELL;

   //--- higher timeframe veto: M5/M15 may not fight the M30 bias
   if(i<2 && out.dir!=AT_HOLD)
     {
      SATSignal bias;
      int cp=0,ct=0;
      //--- note: bias is read from cache to avoid recursion
      if(m_cache_bar[2]!=0)
        {
         bias = m_cache[2];
         if(bias.dir!=AT_HOLD && bias.dir!=out.dir)
           {
            out.reason = "Blocked: against M30 bias";
            out.dir    = AT_HOLD;
           }
        }
     }

   //--- levels -----------------------------------------------------
   double ask = SymbolInfoDouble(m_symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(m_symbol,SYMBOL_BID);
   double entry = (out.dir==AT_BUY) ? ask : (out.dir==AT_SELL ? bid : (ask+bid)/2.0);

   double sl_dist = m_cfg.sl_atr_mult*atr;
   if(out.dir==AT_BUY)
     {
      double sw = SwingLow(i,m_cfg.swing_lookback);
      if(sw>0.0 && entry-sw>0.0 && (entry-sw)<sl_dist*1.6)
         sl_dist = MathMax(sl_dist*0.6,entry-sw);
      out.entry = entry;
      out.sl    = NormalizeDouble(entry-sl_dist,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS));
      out.tp1   = NormalizeDouble(entry+sl_dist*m_cfg.tp1_rr,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS));
      out.tp2   = NormalizeDouble(entry+sl_dist*m_cfg.tp2_rr,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS));
     }
   else
      if(out.dir==AT_SELL)
        {
         double sw = SwingHigh(i,m_cfg.swing_lookback);
         if(sw>0.0 && sw-entry>0.0 && (sw-entry)<sl_dist*1.6)
            sl_dist = MathMax(sl_dist*0.6,sw-entry);
         out.entry = entry;
         out.sl    = NormalizeDouble(entry+sl_dist,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS));
         out.tp1   = NormalizeDouble(entry-sl_dist*m_cfg.tp1_rr,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS));
         out.tp2   = NormalizeDouble(entry-sl_dist*m_cfg.tp2_rr,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS));
        }
   out.rr = m_cfg.tp1_rr;

   //--- 10 point checklist ------------------------------------------
   int passed = 0, total = 0;
   string fail = "";

   total++; if(trending)                    passed++; else fail = "ADX too low";
   total++; if(atr>0.0)                     passed++; else fail = "low volatility";

   double spread_pts = (double)SymbolInfoInteger(m_symbol,SYMBOL_SPREAD);
   total++;
   if(m_cfg.max_spread_points<=0.0 || spread_pts<=m_cfg.max_spread_points)
      passed++;
   else
      fail = "spread too high";

   double atr_pts = atr/SymbolInfoDouble(m_symbol,SYMBOL_POINT);
   total++;
   if(m_cfg.min_atr_points<=0.0 || atr_pts>=m_cfg.min_atr_points)
      passed++;
   else
      fail = "volatility too low";
   total++;
   if(m_cfg.max_atr_points<=0.0 || atr_pts<=m_cfg.max_atr_points)
      passed++;
   else
      fail = "volatility too high";

   total++; if(SessionOK())                 passed++; else fail = "outside session";
   total++; if(!NewsBlocked())              passed++; else fail = "news window";

   total++;
   if(stretch<=m_cfg.max_ext_atr)
      passed++;
   else
      fail = "over-extended from EMA";

   total++;
   if(out.dir!=AT_HOLD)
      passed++;
   else
      if(fail=="")
         fail = "no edge (score below threshold)";

   //--- HTF alignment
   total++;
   if(i==2)
     {
      double d1 = Buf(m_ind[2].h_ema_bias,0,1);
      double c  = iClose(m_symbol,tf,1);
      if(out.dir==AT_HOLD || (out.dir==AT_BUY && c>d1) || (out.dir==AT_SELL && c<d1))
         passed++;
      else
         fail = "against higher timeframe";
     }
   else
     {
      if(m_cache_bar[2]!=0 && (out.dir==AT_HOLD || m_cache[2].dir==AT_HOLD || m_cache[2].dir==out.dir))
         passed++;
      else
         fail = "against M30 bias";
     }

   out.checks_total  = total;
   out.checks_passed = passed;
   out.tradeable     = (out.dir!=AT_HOLD && passed==total);
   out.confidence    = MathMax(0.0,MathMin(100.0,
                       0.70*MathAbs(score100) + 0.30*(100.0*passed/total)));

   if(out.reason=="" && out.dir==AT_HOLD && fail!="")
      out.reason = fail;

   //--- cache ------------------------------------------------------
   m_cache[i]     = out;
   m_cache_bar[i] = iTime(m_symbol,tf,0);

   checks_passed = passed;
   checks_total  = total;
   return(true);
  }

//+------------------------------------------------------------------+
//| Feature vector for the ONNX model.                               |
//| Order is frozen - see docs/FEATURE_CONTRACT.md                   |
//+------------------------------------------------------------------+
bool CAtSignalEngine::BuildFeatures(double &f[]) const
  {
   if(!Ready())
      return(false);
   ArrayResize(f,AT_FEATURE_COUNT);
   ArrayInitialize(f,0.0);

   int k = 0;
   for(int i=0;i<AT_MAX_TF;i++)
     {
      double atr = IndATR(i,1);
      if(atr<=0.0)
         atr = 1e-9;

      double close = iClose(m_symbol,m_tf[i],1);
      double ef    = Buf(m_ind[i].h_ema_fast,0,1);
      double es    = Buf(m_ind[i].h_ema_slow,0,1);
      double eb    = Buf(m_ind[i].h_ema_bias,0,1);
      double ef3   = Buf(m_ind[i].h_ema_fast,0,4);
      double es3   = Buf(m_ind[i].h_ema_slow,0,4);
      double adx   = Buf(m_ind[i].h_adx,0,1);
      double pdi   = Buf(m_ind[i].h_adx,1,1);
      double ndi   = Buf(m_ind[i].h_adx,2,1);
      double rsi   = Buf(m_ind[i].h_rsi,0,1);
      double hist  = Buf(m_ind[i].h_macd,0,1)-Buf(m_ind[i].h_macd,1,1);
      double hist2 = Buf(m_ind[i].h_macd,0,2)-Buf(m_ind[i].h_macd,1,2);

      f[k++] = (ef-es)/atr;                       // 1  EMA spread in ATR
      f[k++] = (ef-ef3)/atr;                      // 2  fast EMA slope
      f[k++] = (es-es3)/atr;                      // 3  slow EMA slope
      f[k++] = (close-eb)/atr;                    // 4  stretch from bias EMA
      f[k++] = adx/100.0;                         // 5  trend strength
      f[k++] = (pdi-ndi)/100.0;                   // 6  directional pressure
      f[k++] = (rsi-50.0)/50.0;                   // 7  RSI centered
      f[k++] = (hist*2.0-hist2)/atr;              // 8  MACD histogram change
      //--- note: 8 features per TF x 3 TF = 24
      if(k>=AT_FEATURE_COUNT)
         break;
     }
   return(k==AT_FEATURE_COUNT);
  }

#endif // AUTOTRADER_SIGNAL_ENGINE_MQH
//+------------------------------------------------------------------+
