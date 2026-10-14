//+------------------------------------------------------------------+
//| MarketData.mqh                                                    |
//| Autotrader Phase 3 - multi-timeframe bar cache.                   |
//|                                                                   |
//| In plain words: one of these holds the recent CLOSED bars of one  |
//| timeframe. The direction engine keeps three of them (M30 bias,    |
//| M15 setup, M5 trigger) no matter which chart timeframe the EA is  |
//| attached to - that is what makes "one EA, any chart" work.        |
//|                                                                   |
//| Only closed bars are ever copied (start_pos = 1), so nothing here |
//| can repaint. new_bar tells the engine "a bar just closed on this  |
//| timeframe" - that is the moment the heavy maths runs, instead of  |
//| on every tick.                                                    |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_MARKET_DATA_MQH
#define AUTOTRADER_MARKET_DATA_MQH

class CMarketData
  {
public:
   //--- r[0] = newest CLOSED bar (series order). Public so the
   //--- indicator/smart-money/volume functions can read it directly.
   MqlRates        r[];
   int             n;            // how many closed bars we hold
   bool            ready;        // enough history for the maths
   bool            new_bar;      // true on the refresh that saw a close
   datetime        forming;      // open time of the still-forming bar
   datetime        bar_time;     // open time of the newest closed bar
   string          sym;
   ENUM_TIMEFRAMES tf;
   int             need;         // bars requested

private:
   bool            m_first;

public:
                     CMarketData(void);

   bool              Setup(const string symbol, const ENUM_TIMEFRAMES timeframe,
                           const int bars_needed);
   //--- copy the closed bars again; returns false when history is short
   bool              Refresh(void);

   //--- safe accessors (0 = newest closed bar); 0.0 when out of range
   double            Open(const int i)    const;
   double            High(const int i)    const;
   double            Low(const int i)     const;
   double            Close(const int i)   const;
   long              Volume(const int i)  const;
   datetime          Time(const int i)    const;
   int               MinutesPerBar(void)  const;
  };

//+------------------------------------------------------------------+
CMarketData::CMarketData(void)
  {
   n        = 0;
   ready    = false;
   new_bar  = false;
   forming  = 0;
   bar_time = 0;
   sym      = "";
   tf       = PERIOD_CURRENT;
   need     = 0;
   m_first  = true;
  }

//+------------------------------------------------------------------+
bool CMarketData::Setup(const string symbol, const ENUM_TIMEFRAMES timeframe,
                        const int bars_needed)
  {
   sym   = symbol;
   tf    = timeframe;
   need  = bars_needed;
   m_first = true;
   new_bar = false;
   return true;
  }

//+------------------------------------------------------------------+
//| Copy closed bars. start_pos = 1 -> the live bar is never in here. |
//+------------------------------------------------------------------+
bool CMarketData::Refresh(void)
  {
   new_bar = false;
   if(sym == "" || need <= 0)
      return false;

   //--- what bar is currently forming? (used only to detect a close)
   datetime f = iTime(sym, tf, 0);
   if(f == 0)
      f = (datetime)SeriesInfoInteger(sym, tf, SERIES_LASTBAR_DATE);

   int copied = CopyRates(sym, tf, 1, need, r);
   if(copied <= 0)
     {
      n     = 0;
      ready = false;
      return false;
     }
   ArraySetAsSeries(r, true);
   n        = copied;
   bar_time = r[0].time;
   ready    = (n >= (int)MathMin(need, 120));

   //--- a close happened when the forming bar's open time moved on
   if(!m_first && f != 0 && forming != 0 && f != forming)
      new_bar = true;
   if(f != 0)
      forming = f;
   m_first = false;
   return ready;
  }

//+------------------------------------------------------------------+
double CMarketData::Open(const int i) const
  { return (i >= 0 && i < n) ? r[i].open : 0.0; }
double CMarketData::High(const int i) const
  { return (i >= 0 && i < n) ? r[i].high : 0.0; }
double CMarketData::Low(const int i) const
  { return (i >= 0 && i < n) ? r[i].low : 0.0; }
double CMarketData::Close(const int i) const
  { return (i >= 0 && i < n) ? r[i].close : 0.0; }
long CMarketData::Volume(const int i) const
  { return (i >= 0 && i < n) ? r[i].tick_volume : 0; }
datetime CMarketData::Time(const int i) const
  { return (i >= 0 && i < n) ? r[i].time : 0; }

int CMarketData::MinutesPerBar(void) const
  {
   int s = PeriodSeconds(tf);
   return (s > 0) ? s / 60 : 5;
  }
//+------------------------------------------------------------------+
#endif // AUTOTRADER_MARKET_DATA_MQH
