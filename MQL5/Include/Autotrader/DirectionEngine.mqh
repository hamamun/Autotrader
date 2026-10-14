//+------------------------------------------------------------------+
//| DirectionEngine.mqh                                               |
//| Autotrader Phase 3 - the direction & confidence judge.            |
//|                                                                   |
//| This is the heart of the 98% motto. Its whole personality is:     |
//| SAY NOTHING unless the evidence is overwhelming. HOLD is the      |
//| default state; BUY/SELL is the rare exception.                    |
//|                                                                   |
//| How it works, in plain words:                                     |
//|  1. It always reads three timeframes - M30 (the bias), M15 (the   |
//|     setup) and M5 (the trigger) - whatever chart it sits on.      |
//|     The chart's own timeframe decides WHICH product is reported   |
//|     (owner decision: Option A, one direction per chart).          |
//|  2. Eight groups of evidence are scored 0..100 and blended with   |
//|     weights that change with the regime (a trend weights bias and |
//     momentum; a range weights zones and volume).                  |
//|  3. Hard gates can veto a trade outright: M5/M15 may never fight  |
//|     M30, VOLATILE/QUIET/TRANSITION stand aside, the wrong side of |
//|     a range is not an edge, an absurd stop is not a trade, a thin |
//|     risk:reward is not a trade, an unreachable target is not a    |
//|     trade, an expensive spread is not a trade.                    |
//|  4. The score must clear the symbol's own auto-set threshold      |
//|     (Symbol Intelligence: ~85 calm forex, ~90+ crypto).           |
//|  5. Hysteresis: a signal is LATCHED. It is held until it is       |
//|     genuinely invalidated (score falls well below the line, a     |
//|     gate trips, it grows too old) - so the panel never flickers   |
//|     between BUY and HOLD on tiny price wiggles.                   |
//|  6. When it does speak, it prints REAL numbers: an entry that     |
//|     exists, a stop that respects the broker's minimum distance    |
//|     and the spread, and a target reachable inside the lane's      |
//|     window. Every rejection reason is written down for the audit  |
//|     trail.                                                        |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_DIRECTION_ENGINE_MQH
#define AUTOTRADER_DIRECTION_ENGINE_MQH

//--- which direction product this chart reports (owner decision: Option A)
enum ENUM_AT_LANE
  {
   AT_LANE_M5  = 0,   // scalping trigger
   AT_LANE_M15 = 1,   // short-term setup
   AT_LANE_M30 = 2    // intraday bias
  };

//--- the three possible answers
enum ENUM_AT_SIG
  {
   AT_SIG_HOLD = 0,
   AT_SIG_BUY  = 1,
   AT_SIG_SELL = 2
  };

//--- how many bars each timeframe needs before it may speak
#define ATDE_BARS_M30   260
#define ATDE_BARS_M15   300
#define ATDE_BARS_M5    340

//--- score release band: a latched signal is dropped only when the
//--- score falls this far BELOW the threshold (anti-flicker)
#define ATDE_RELEASE_BAND 8

int ATDE_Sign(const double v)
  {
   if(v > 0.0) return 1;
   if(v < 0.0) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| One timeframe, fully analysed. Three of these = M30 + M15 + M5.   |
//+------------------------------------------------------------------+
class CTFAnalysis
  {
public:
   CMarketData   md;
   CRegimeEngine regime;
   SATSmcInfo    smc;
   SATVolumeInfo vol;

   bool   ready;
   bool   new_bar;
   int    minutes;             // minutes per bar on this timeframe
   double atr;                 // current wiggle, price units
   double atr_base;            // its own longer-run normal
   double atr_ratio;           // atr / atr_base
   double eff;                 // efficiency ratio (how straight)
   double ema20, ema50, ema100, ema200;
   double nw, nw_mae, nw_up, nw_lo, nw_slope;   // Nadaraya-Watson + envelope
   double kalman, kalman_slope;                 // Kalman trend line
   double ss;                                   // Ehlers Super Smoother
   double decy_osc;                             // Ehlers Decycler Oscillator %
   double lrsi;                                 // Ehlers Laguerre RSI 0..1
   double range_hi, range_lo;                   // recent 60-bar range
   double close0;

                     CTFAnalysis(void);
   bool              Setup(const string symbol, const ENUM_TIMEFRAMES tf,
                           const int bars);
   bool              Analyse(const bool pull_bars);   // the heavy pass
  };

//+------------------------------------------------------------------+
CTFAnalysis::CTFAnalysis(void)
  {
   ready   = false;
   new_bar = false;
   minutes = 5;
   atr = 0.0; atr_base = 0.0; atr_ratio = 1.0; eff = 0.0;
   ema20 = 0.0; ema50 = 0.0; ema100 = 0.0; ema200 = 0.0;
   nw = 0.0; nw_mae = 0.0; nw_up = 0.0; nw_lo = 0.0; nw_slope = 0.0;
   kalman = 0.0; kalman_slope = 0.0;
   ss = 0.0; decy_osc = 0.0; lrsi = 0.5;
   range_hi = 0.0; range_lo = 0.0;
   close0 = 0.0;
   //--- never let a caller read uninitialised evidence: clear both
   //--- evidence structs before the first analysis
   CSmartMoney sm0;
   sm0.Reset(smc);
   CVolumeFlow vf0;
   vf0.Reset(vol);
  }

bool CTFAnalysis::Setup(const string symbol, const ENUM_TIMEFRAMES tf,
                        const int bars)
  {
   md.Setup(symbol, tf, bars);
   minutes = md.MinutesPerBar();
   ready   = false;
   return true;
  }

//+------------------------------------------------------------------+
//| The heavy pass: pull the closed bars, then measure everything.    |
//+------------------------------------------------------------------+
bool CTFAnalysis::Analyse(const bool pull_bars)
  {
   if(pull_bars)
     {
      new_bar = false;
      if(!md.Refresh())
        {
         ready = false;
         return false;
        }
      new_bar = md.new_bar;
     }
   minutes = md.MinutesPerBar();
   if(md.n <= 0)
     {
      ready = false;
      return false;
     }

   int n = md.n;
   if(n < 120)
     {
      ready = false;
      return false;
     }

   //--- regime (its own closed-bar classification, specific labels)
   regime.Refresh(md.sym, md.tf);

   close0 = md.r[0].close;

   //--- volatility: the symbol's own ruler
   atr      = ATMI_Atr(md.r, 14, 0);
   atr_base = ATMI_Atr(md.r, 14, 60);
   if(atr <= 0.0)
     {
      ready = false;
      return false;
     }
   atr_ratio = (atr_base > 0.0) ? atr / atr_base : 1.0;
   eff       = ATMI_Efficiency(md.r, 20, 0);

   //--- averages
   ema20  = ATMI_Ema(md.r, 20, 0);
   ema50  = ATMI_Ema(md.r, 50, 0);
   ema100 = ATMI_Ema(md.r, 100, 0);
   ema200 = (n > 205) ? ATMI_Ema(md.r, 200, 0) : ema100;

   //--- Nadaraya-Watson, non-repainting, bandwidth adapts to how wild
   //--- the market is right now (calm = tight fit, wild = smoother fit)
   double h = 3.5 + 5.0 * MathMin(1.0, MathMax(0.0, atr_ratio - 0.70));
   int lb = MathMin(70, n - 4);
   double mae2 = 0.0;
   nw      = ATMI_NW(md.r, lb, h, 0, nw_mae);
   double nw_prev = ATMI_NW(md.r, lb, h, 5, mae2);
   nw_up   = nw + 2.0 * nw_mae;
   nw_lo   = nw - 2.0 * nw_mae;
   nw_slope = (nw > 0.0 && nw_prev > 0.0) ? (nw - nw_prev) / atr / 5.0 : 0.0;

   //--- Kalman: noise terms come from the symbol's own wiggle
   double kq = atr * atr * 0.020;
   double kr = atr * atr * 0.350;
   kalman       = ATMI_Kalman(md.r, kq, kr, 0);
   kalman_slope = ATMI_KalmanSlope(md.r, kq, kr, 5, atr);

   //--- Ehlers DSP family
   ss       = ATMI_SuperSmoother(md.r, 10, 0);
   decy_osc = ATMI_DecyclerOscPct(md.r, 20, 0);
   //--- adaptive gamma: a clean move gets a faster filter, chop gets a slower one
   double gamma = 0.28 + 0.42 * MathMin(1.0, MathMax(0.0, eff));
   lrsi = ATMI_LaguerreRSI(md.r, gamma, 0);

   //--- recent range
   range_hi = ATMI_Highest(md.r, 60, 0);
   range_lo = ATMI_Lowest(md.r, 60, 0);

   //--- smart money + volume flow on the same closed bars
   CSmartMoney sm;
   sm.Analyse(md.r, MathMin(180, n - 5), atr, smc);
   CVolumeFlow vf;
   vf.Analyse(md.r, MathMin(200, n), atr, vol);

   ready = true;
   return true;
  }

//+------------------------------------------------------------------+
//| The judge                                                         |
//+------------------------------------------------------------------+
class CDirectionEngine
  {
public:
   CTFAnalysis a30, a15, a5;

private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_chart_tf;
   ENUM_AT_LANE    m_lane;
   bool            m_ready;

   //--- the answer
   int             m_dir;          // AT_SIG_*
   int             m_eval_dir;     // direction the score was computed for
   int             m_score;        // 0..100
   int             m_threshold;    // from Symbol Intelligence
   int             m_vote;         // raw direction vote, for the audit trail
   bool            m_tradable;     // every hard gate passed

   //--- evidence parts, 0..100 each (the audit trail)
   int             m_p_bias, m_p_struct, m_p_trigger, m_p_zone;
   int             m_p_momentum, m_p_volume, m_p_fitness, m_p_quote;
   //--- what the printed parts describe (owner report, 14 Oct 2026):
   //--- +1/-1 = the side, 0 = nothing to show; provisional = no signal yet
   int             m_parts_side;
   int             m_parts_score;
   bool            m_prov;

   //--- the real, reachable plan
   double          m_entry, m_sl, m_tp1, m_tp2, m_tp3;
   double          m_sl_dist, m_tp_dist, m_rr;
   int             m_expected_min;
   bool            m_use_limit;
   int             m_digits;

   //--- latch (hysteresis)
   int             m_latch_dir;
   int             m_latch_score;
   datetime        m_latch_time;
   datetime        m_latch_bar;
   bool            m_latch_traded;
   datetime        m_traded_bar;

   //--- why not
   string          m_veto;         // "" = no veto
   string          m_reason;       // plain-words explanation
   datetime        m_last_heavy;
   bool            m_lane_new_bar; // the lane timeframe just closed a bar
   datetime        m_lane_bar_time;
   double          m_lane_atr;

   CTFAnalysis*    LaneTF(void);
   bool            RegimeAllows(const ENUM_AT_REGIME kind, const int dir) const;
   int             LaneMaxMinutes(void) const;

public:
                     CDirectionEngine(void);

   bool              Setup(const string symbol, const ENUM_TIMEFRAMES chart_tf);
   //--- run the judge. spread/quote facts come from the live ticker,
   //--- the profile from Symbol Intelligence.
   bool              Refresh(CSymbolIntelligence &profile,
                             const bool force,
                             const long spread_pts,
                             const double spread_limit_pts,
                             const int quote_age_sec);

   void              MarkTraded(void);   // the EA acted on this latch
   void              ClearLatch(void);   // trade finished, start fresh

   //--- getters
   bool              Ready(void)          const { return m_ready; }
   int               Dir(void)            const { return m_dir; }
   int               Score(void)          const { return m_score; }
   int               Threshold(void)      const { return m_threshold; }
   int               Vote(void)           const { return m_vote; }
   bool              Tradable(void)       const { return m_tradable; }
   double            Entry(void)          const { return m_entry; }
   double            Sl(void)             const { return m_sl; }
   double            Tp1(void)            const { return m_tp1; }
   double            Tp2(void)            const { return m_tp2; }
   double            Tp3(void)            const { return m_tp3; }
   double            SlDist(void)         const { return m_sl_dist; }
   double            TpDist(void)         const { return m_tp_dist; }
   double            Rr(void)             const { return m_rr; }
   int               ExpectedMinutes(void) const { return m_expected_min; }
   bool              UseLimit(void)       const { return m_use_limit; }
   string            Veto(void)           const { return m_veto; }
   string            Reason(void)         const { return m_reason; }
   string            RegimeDisplay(void);
   bool              LaneRegimeTradable(void);
   string            LaneName(void)       const;
   ENUM_AT_LANE      Lane(void)           const { return m_lane; }
   int               PartBias(void)       const { return m_p_bias; }
   int               PartStruct(void)     const { return m_p_struct; }
   int               PartTrigger(void)    const { return m_p_trigger; }
   int               PartZone(void)       const { return m_p_zone; }
   int               PartMomentum(void)   const { return m_p_momentum; }
   int               PartVolume(void)     const { return m_p_volume; }
   int               PartFitness(void)    const { return m_p_fitness; }
   int               PartQuote(void)      const { return m_p_quote; }
   int               PartsSide(void)       const { return m_parts_side; }
   int               PartsScore(void)      const { return m_parts_score; }
   bool              PartsProvisional(void) const { return m_prov; }
   bool              Latched(void)        const { return (m_latch_dir != 0); }
   int               LatchDir(void)       const { return m_latch_dir; }
   int               LatchAgeSec(void)    const;
   datetime          LatchTime(void)      const { return m_latch_time; }
   bool              LatchTraded(void)    const { return m_latch_traded; }
   bool              LaneNewBar(void)     const { return m_lane_new_bar; }
   datetime          LaneBarTime(void)    const { return m_lane_bar_time; }
   double            LaneAtr(void)        const { return m_lane_atr; }
   string            Audit(void)          const;
  };

//+------------------------------------------------------------------+
CDirectionEngine::CDirectionEngine(void)
  {
   m_symbol   = "";
   m_chart_tf = PERIOD_CURRENT;
   m_lane     = AT_LANE_M15;
   m_ready    = false;
   m_dir      = AT_SIG_HOLD;
   m_eval_dir = 0;
   m_score    = 0;
   m_threshold = 88;
   m_vote     = 0;
   m_tradable = false;
   m_p_bias = 0; m_p_struct = 0; m_p_trigger = 0; m_p_zone = 0;
   m_p_momentum = 0; m_p_volume = 0; m_p_fitness = 0; m_p_quote = 0;
   m_parts_side = 0; m_parts_score = 0; m_prov = false;
   m_entry = 0.0; m_sl = 0.0; m_tp1 = 0.0; m_tp2 = 0.0; m_tp3 = 0.0;
   m_sl_dist = 0.0; m_tp_dist = 0.0; m_rr = 0.0;
   m_expected_min = 0;
   m_use_limit = false;
   m_digits = 2;
   m_latch_dir = 0; m_latch_score = 0;
   m_latch_time = 0; m_latch_bar = 0;
   m_latch_traded = false; m_traded_bar = 0;
   m_veto = ""; m_reason = "calibrating";
   m_last_heavy = 0;
   m_lane_new_bar = false;
   m_lane_bar_time = 0;
   m_lane_atr = 0.0;
  }

//+------------------------------------------------------------------+
bool CDirectionEngine::Setup(const string symbol, const ENUM_TIMEFRAMES chart_tf)
  {
   m_symbol   = symbol;
   m_chart_tf = chart_tf;
   m_digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   //--- owner decision (Option A): the chart's timeframe decides which
   //--- direction PRODUCT this panel reports and trades.
   if(chart_tf == PERIOD_M5)       m_lane = AT_LANE_M5;
   else if(chart_tf == PERIOD_M15) m_lane = AT_LANE_M15;
   else                            m_lane = AT_LANE_M30;

   a30.Setup(symbol, PERIOD_M30, ATDE_BARS_M30);
   a15.Setup(symbol, PERIOD_M15, ATDE_BARS_M15);
   a5.Setup(symbol,  PERIOD_M5,  ATDE_BARS_M5);

   m_ready = false;
   m_latch_dir = 0;
   m_latch_traded = false;
   return true;
  }

//+------------------------------------------------------------------+
//| the timeframe this chart reports on                               |
//+------------------------------------------------------------------+
CTFAnalysis* CDirectionEngine::LaneTF(void)
  {
   if(m_lane == AT_LANE_M5)  return GetPointer(a5);
   if(m_lane == AT_LANE_M15) return GetPointer(a15);
   return GetPointer(a30);
  }

int CDirectionEngine::LaneMaxMinutes(void) const
  {
   if(m_lane == AT_LANE_M5)  return 480;    // scalping window
   if(m_lane == AT_LANE_M15) return 960;    // short-term window
   return 1920;                             // intraday window
  }

//+------------------------------------------------------------------+
//| the regime also decides WHICH direction is allowed. This is the   |
//| behaviour switch from PLAN 4B: trends are continued, range        |
//| extremes are faded, everything else stands aside.                 |
//+------------------------------------------------------------------+
bool CDirectionEngine::RegimeAllows(const ENUM_AT_REGIME kind, const int dir) const
  {
   switch(kind)
     {
      case AT_REGIME_TREND_UP:      return (dir == 1);
      case AT_REGIME_TREND_DOWN:    return (dir == -1);
      case AT_REGIME_PULLBACK_UP:   return (dir == 1);
      case AT_REGIME_PULLBACK_DOWN: return (dir == -1);
      case AT_REGIME_RANGE_TOP:     return (dir == -1);   // fade the top
      case AT_REGIME_RANGE_BOTTOM:  return (dir == 1);    // fade the bottom
      default:                      return false;         // HOLD territory
     }
  }

int CDirectionEngine::LatchAgeSec(void) const
  {
   if(m_latch_time == 0)
      return 0;
   return (int)(TimeCurrent() - m_latch_time);
  }

//+------------------------------------------------------------------+
string CDirectionEngine::RegimeDisplay(void)
  {
   CTFAnalysis *lt = LaneTF();
   if(lt == NULL)
      return GLYPH_DOT + " CALIBRATING " + GLYPH_DASH + " collecting price history";
   return lt.regime.Display();
  }

bool CDirectionEngine::LaneRegimeTradable(void)
  {
   CTFAnalysis *lt = LaneTF();
   if(lt == NULL)
      return false;
   return lt.regime.Tradable();
  }

string CDirectionEngine::LaneName(void) const
  {
   if(m_lane == AT_LANE_M5)  return "SCALPING (M5)";
   if(m_lane == AT_LANE_M15) return "SHORT-TERM (M15)";
   return "INTRADAY (M30)";
  }

//+------------------------------------------------------------------+
//| the audit line printed to the Experts log on every new bar        |
//+------------------------------------------------------------------+
string CDirectionEngine::Audit(void) const
  {
   string s = StringFormat("AT3 %s score=%d/%d vote=%d",
                           LaneName(), m_score, m_threshold, m_vote);

   //--- the parts are always shown (owner report, 14 Oct 2026). While no
   //--- side has been chosen they describe the provisional side and are
   //--- labelled PROV - evidence in the log, never a signal.
   if(m_parts_side == 0)
      s += " parts[n/a - no side yet]";
   else
     {
      if(m_prov)
         s += StringFormat(" PROV[%s %d]",
                           (m_parts_side == 1) ? "BUY" : "SELL", m_parts_score);
      s += StringFormat(" parts[bias %d struct %d trig %d zone %d mom %d vol %d fit %d quote %d]",
                        m_p_bias, m_p_struct, m_p_trigger, m_p_zone,
                        m_p_momentum, m_p_volume, m_p_fitness, m_p_quote);
     }

   if(m_dir == AT_SIG_HOLD)
      s += " -> HOLD: " + m_reason;
   else
      s += StringFormat(" -> %s entry=%s sl=%s tp1=%s tp3=%s rr=1:%.1f eta=%dmin",
                        (m_dir == AT_SIG_BUY ? "BUY" : "SELL"),
                        DoubleToString(m_entry, m_digits),
                        DoubleToString(m_sl, m_digits),
                        DoubleToString(m_tp1, m_digits),
                        DoubleToString(m_tp3, m_digits),
                        m_rr, m_expected_min);
   return s;
  }

//+------------------------------------------------------------------+
void CDirectionEngine::MarkTraded(void)
  {
   m_latch_traded = true;
   m_traded_bar   = m_latch_bar;
  }

void CDirectionEngine::ClearLatch(void)
  {
   m_latch_dir    = 0;
   m_latch_score  = 0;
   m_latch_time   = 0;
   m_latch_bar    = 0;
   m_latch_traded = false;
  }

//+------------------------------------------------------------------+
//| RUN THE JUDGE                                                     |
//+------------------------------------------------------------------+
bool CDirectionEngine::Refresh(CSymbolIntelligence &profile,
                               const bool force,
                               const long spread_pts,
                               const double spread_limit_pts,
                               const int quote_age_sec)
  {
   //--- pull the three timeframes (closed bars only)
   bool ok30 = a30.md.Refresh();
   bool ok15 = a15.md.Refresh();
   bool ok5  = a5.md.Refresh();

   datetime now = TimeCurrent();
   //--- "a bar just closed" is decided once, here, straight from the data
   a30.new_bar = a30.md.new_bar;
   a15.new_bar = a15.md.new_bar;
   a5.new_bar  = a5.md.new_bar;
   bool any_new_bar = (a30.new_bar || a15.new_bar || a5.new_bar);

   //--- the heavy maths runs when a bar closes (or at least every 15s,
   //--- so a very quiet symbol still keeps its picture current)
   bool heavy = force || any_new_bar || (now - m_last_heavy >= 15);
   if(heavy)
     {
      a30.Analyse(false);
      a15.Analyse(false);
      a5.Analyse(false);
      m_last_heavy = now;
     }

   m_threshold = profile.ConfidenceThreshold();
   m_digits    = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);

   CTFAnalysis *lt = LaneTF();
   CTFAnalysis *tr = GetPointer(a5);

   //=== not ready? -> stay silent ====================================
   if(!ok30 || !ok15 || !ok5 || lt == NULL || tr == NULL ||
      !a30.ready || !a15.ready || !a5.ready || !lt.ready || !profile.Ready())
     {
      m_ready    = false;
      m_dir      = AT_SIG_HOLD;
      m_tradable = false;
      m_score    = 0;
      m_parts_side = 0; m_parts_score = 0; m_prov = false;
      m_veto     = "calibrating";
      m_reason   = "collecting price history";
      m_lane_new_bar = any_new_bar;
      ClearLatch();
      return false;
     }
   m_ready = true;
   m_lane_new_bar = lt.new_bar;
   m_lane_bar_time = lt.md.bar_time;
   m_lane_atr      = lt.atr;

   double atr      = lt.atr;
   double bid      = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double spread_price = (ask > bid) ? (ask - bid) : profile.Point();
   double stops_price  = profile.StopsLevelPrice();

   m_veto   = "";
   m_reason = "";

   //=== 1. which direction is even worth scoring? ====================
   //--- a plain vote of the lane timeframe's own witnesses
   int vote = 0;
   vote += lt.regime.Direction();
   vote += lt.smc.structure_dir;
   vote += ((lt.ema20 > lt.ema50 && lt.ema50 > lt.ema100) ? 1 :
            ((lt.ema20 < lt.ema50 && lt.ema50 < lt.ema100) ? -1 : 0));
   vote += (lt.nw_slope >  0.030) ? 1 : ((lt.nw_slope < -0.030) ? -1 : 0);
   vote += (lt.kalman_slope >  0.020) ? 1 : ((lt.kalman_slope < -0.020) ? -1 : 0);
   vote += (lt.lrsi > 0.60) ? 1 : ((lt.lrsi < 0.40) ? -1 : 0);
   vote += lt.vol.cvd_dir;
   if(lt.smc.bos_dir != 0 && lt.smc.bars_since_bos <= 12)
      vote += lt.smc.bos_dir;
   m_vote = vote;

   int cand = (vote >= 3) ? 1 : ((vote <= -3) ? -1 : 0);

   //--- keep an existing latch under evaluation so the score can be
   //--- watched on the way down (that is what the release band is for)
   int eval_dir = (m_latch_dir != 0) ? m_latch_dir : cand;

   //=== 2. hard gates (a veto means HOLD, whatever the score says) ===
   if(eval_dir == 0)
      m_veto = "no clear direction yet";
   else if(!lt.regime.Tradable())
     {
      ENUM_AT_REGIME k = lt.regime.Kind();
      if(k == AT_REGIME_VOLATILE)    m_veto = "regime VOLATILE - protection mode";
      else if(k == AT_REGIME_QUIET)  m_veto = "regime QUIET - no expansion yet";
      else if(k == AT_REGIME_TRANSITION) m_veto = "regime TRANSITION - unclear";
      else if(k == AT_REGIME_RANGE_MIDDLE) m_veto = "range middle - no edge";
      else                           m_veto = "regime not tradeable";
     }
   else if(!RegimeAllows(lt.regime.Kind(), eval_dir))
      m_veto = "wrong side of this regime for that direction";
   else if(a30.regime.Direction() != 0 && a30.regime.Direction() != eval_dir &&
           m_lane != AT_LANE_M30)
      m_veto = "M5/M15 would fight the M30 bias";
   else if(a30.regime.Kind() == AT_REGIME_VOLATILE)
      m_veto = "M30 VOLATILE - protection mode";
   else if(spread_limit_pts > 0.0 && (double)spread_pts > spread_limit_pts)
      m_veto = StringFormat("spread too expensive (%d pts vs %.0f limit)",
                            (int)spread_pts, spread_limit_pts);
   else if(quote_age_sec > 120)
      m_veto = "no fresh broker quote";

   //=== 3. the eight evidence groups (0..100) ========================
   double e_bias = 0.0, e_struct = 0.0, e_trig = 0.0, e_zone = 0.0;
   double e_mom = 0.0, e_vol = 0.0, e_fit = 0.0, e_quote = 0.0;
   int dir = eval_dir;

   //--- the eight evidence parts are ALWAYS computed (owner report, 14 Oct
   //--- 2026). When no side has been chosen yet they describe the side the
   //--- engine would look at first - a range extreme's fade side (the only
   //--- side RegimeAllows there), otherwise the plain vote's lean - so the
   //--- log and the panel show real scoring instead of eight zeros.
   int pdir = dir;
   if(pdir == 0)
     {
      if(lt.regime.IsRangeExtreme())
         pdir = (lt.regime.Kind() == AT_REGIME_RANGE_BOTTOM) ? 1 : -1;
      else if(vote > 0) pdir = 1;
      else if(vote < 0) pdir = -1;
      else
        {
         //--- the plain vote is tied: read the same witnesses with their
         //--- own graded lean, so the scoring still appears instead of
         //--- eight zeros. Display only - the decision score stays 0.
         int lean = 0;
         if(lt.nw_slope > 0.0)          lean++;
         else if(lt.nw_slope < 0.0)     lean--;
         if(lt.kalman_slope > 0.0)      lean++;
         else if(lt.kalman_slope < 0.0) lean--;
         if(lt.decy_osc > 0.0)          lean++;
         else if(lt.decy_osc < 0.0)     lean--;
         if(lt.close0 > lt.ss)          lean++;
         else if(lt.close0 < lt.ss)     lean--;
         if(lt.lrsi > 0.5)              lean++;
         else if(lt.lrsi < 0.5)         lean--;
         lean += lt.vol.cvd_dir;
         lean += lt.smc.structure_dir;
         lean += (lt.regime.Score() > 0) ? 1 : ((lt.regime.Score() < 0) ? -1 : 0);
         if(lean > 0)      pdir = 1;
         else if(lean < 0) pdir = -1;
        }
     }

   if(pdir != 0)
     {
      //--- (1) M30 bias ------------------------------------------------
      int m30dir = a30.regime.Direction();
      if(m30dir == pdir)
        {
         e_bias = 0.75;
         if(a30.regime.IsTrend() && MathAbs(a30.regime.Score()) >= 4 &&
            a30.regime.Efficiency() >= 0.45)
            e_bias = 1.00;
         else if(a30.regime.IsPullback())
            e_bias = 0.90;
        }
      else if(m30dir == 0)
         e_bias = a30.regime.IsRangeExtreme() ? 0.55 : 0.30;

      //--- (2) M15 structure + lane structure -------------------------
      if(a15.regime.Direction() == pdir)       e_struct += 0.35;
      else if(a15.regime.Direction() == 0)    e_struct += 0.15;
      if(lt.smc.structure_dir == pdir)         e_struct += 0.25;
      else if(lt.smc.structure_dir == 0)      e_struct += 0.10;
      if(lt.smc.bos_dir == pdir)
        {
         if(lt.smc.bars_since_bos <= 10)      e_struct += 0.25;
         else if(lt.smc.bars_since_bos <= 25) e_struct += 0.12;
        }
      if(lt.smc.choch_dir == -pdir && lt.smc.bars_since_choch <= 15)
         e_struct -= 0.30;
      bool stack_up = (lt.ema20 > lt.ema50 && lt.ema50 > lt.ema100);
      bool stack_dn = (lt.ema20 < lt.ema50 && lt.ema50 < lt.ema100);
      if((pdir == 1 && stack_up) || (pdir == -1 && stack_dn))
         e_struct += 0.15;

      //--- (3) M5 trigger (always M5 - it is the timing timeframe) ----
      if(pdir == 1)
        {
         if(tr.lrsi > 0.50 && tr.lrsi < 0.85) e_trig += 0.30;
         else if(tr.lrsi >= 0.85)             e_trig += 0.10;
        }
      else
        {
         if(tr.lrsi < 0.50 && tr.lrsi > 0.15) e_trig += 0.30;
         else if(tr.lrsi <= 0.15)             e_trig += 0.10;
        }
      if((pdir == 1 && tr.close0 > tr.ss) || (pdir == -1 && tr.close0 < tr.ss))
         e_trig += 0.25;
      if((pdir == 1 && tr.decy_osc > 0.0) || (pdir == -1 && tr.decy_osc < 0.0))
         e_trig += 0.20;
      bool conf_bar = (pdir == 1)
                      ? (tr.md.Close(0) > tr.md.Open(0) &&
                         tr.md.Close(0) > tr.md.Close(1))
                      : (tr.md.Close(0) < tr.md.Open(0) &&
                         tr.md.Close(0) < tr.md.Close(1));
      if(conf_bar)
         e_trig += 0.25;

      //--- (4) zone quality (smart money, or the NW envelope) ---------
      double zdist = (pdir == 1) ? lt.smc.zone_buy_dist_atr : lt.smc.zone_sell_dist_atr;
      int    zkind = (pdir == 1) ? lt.smc.zone_buy_kind : lt.smc.zone_sell_kind;
      if(zkind > 0)
        {
         if(zdist <= 0.35)      e_zone = 0.75;
         else if(zdist <= 0.75) e_zone = 0.55;
         else if(zdist <= 1.50) e_zone = 0.30;
         else                   e_zone = 0.10;
        }
      else
        {
         bool near_env = (pdir == 1)
                         ? (lt.close0 <= lt.nw_lo + 0.50 * atr)
                         : (lt.close0 >= lt.nw_up - 0.50 * atr);
         e_zone = near_env ? 0.45 : 0.20;
         if(lt.vol.profile_ready && lt.vol.poc_dist_atr <= 0.60)
            e_zone += 0.15;
        }
      if(lt.smc.sweep_bias == pdir && lt.smc.bars_since_sweep <= 6)
         e_zone += 0.20;
      if(lt.smc.bos_dir == pdir && lt.smc.bars_since_bos <= 10)
         e_zone += 0.10;

      //--- (5) momentum agreement ------------------------------------
      int agree = 0;
      if(ATDE_Sign(lt.nw_slope) == pdir)     agree++;
      if(ATDE_Sign(lt.kalman_slope) == pdir) agree++;
      if((pdir == 1 && lt.decy_osc > 0.0) || (pdir == -1 && lt.decy_osc < 0.0)) agree++;
      if((pdir == 1 && lt.close0 > lt.ss) || (pdir == -1 && lt.close0 < lt.ss)) agree++;
      if((pdir == 1 && lt.lrsi > 0.55) || (pdir == -1 && lt.lrsi < 0.45)) agree++;
      e_mom = (double)agree / 5.0 * 0.70;
      e_mom += 0.30 * MathMin(1.0, MathAbs(lt.nw_slope) / 0.15);

      //--- (6) volume agreement --------------------------------------
      if(lt.vol.cvd_dir == pdir)
         e_vol += 0.10 + 0.45 * lt.vol.cvd_strength;
      else if(lt.vol.cvd_dir == 0)
         e_vol += 0.20;
      if(lt.vol.vol_ratio >= 1.10)      e_vol += 0.25;
      else if(lt.vol.vol_ratio >= 0.90) e_vol += 0.12;
      if((pdir == 1 && lt.vol.price_vs_vwap == 1) ||
         (pdir == -1 && lt.vol.price_vs_vwap == -1))
         e_vol += 0.20;
      if(lt.vol.profile_ready && lt.vol.poc_dist_atr <= 0.50)
         e_vol += 0.05;

      //--- (7) volatility fitness ------------------------------------
      double ratio = lt.atr_ratio;
      if(ratio >= 0.80 && ratio <= 1.40)      e_fit = 0.85;
      else if(ratio > 1.40 && ratio <= 1.60)  e_fit = 0.50;
      else if(ratio >= 0.62 && ratio < 0.80)  e_fit = 0.55;
      else                                    e_fit = 0.15;
      if(lt.eff >= 0.45)      e_fit += 0.15;
      else if(lt.eff >= 0.30) e_fit += 0.08;
      else                    e_fit -= 0.10;
      //--- the wiggle must be worth more than the cost of trading it
      double cost3 = (stops_price + spread_price) * 3.0;
      if(atr >= cost3) e_fit += 0.10;
      else             e_fit -= 0.35;

      //--- (8) quote quality -----------------------------------------
      if(spread_limit_pts > 0.0)
         e_quote = ATMI_Clamp01(1.0 - (double)spread_pts / (spread_limit_pts * 1.30));
      else
         e_quote = 0.70;
      if(quote_age_sec > 30)  e_quote *= 0.50;
      if(quote_age_sec > 90)  e_quote *= 0.30;
     }

   m_p_bias     = (int)MathRound(ATMI_Clamp01(e_bias)   * 100.0);
   m_p_struct   = (int)MathRound(ATMI_Clamp01(e_struct) * 100.0);
   m_p_trigger  = (int)MathRound(ATMI_Clamp01(e_trig)   * 100.0);
   m_p_zone     = (int)MathRound(ATMI_Clamp01(e_zone)   * 100.0);
   m_p_momentum = (int)MathRound(ATMI_Clamp01(e_mom)    * 100.0);
   m_p_volume   = (int)MathRound(ATMI_Clamp01(e_vol)    * 100.0);
   m_p_fitness  = (int)MathRound(ATMI_Clamp01(e_fit)    * 100.0);
   m_p_quote    = (int)MathRound(ATMI_Clamp01(e_quote)  * 100.0);

   //=== 4. regime-weighted blend =====================================
   double w0 = 0.15, w1 = 0.15, w2 = 0.15, w3 = 0.15;
   double w4 = 0.15, w5 = 0.10, w6 = 0.10, w7 = 0.05;
   if(lt.regime.IsTrend())
     { w0 = 0.20; w1 = 0.18; w2 = 0.12; w3 = 0.10; w4 = 0.18; w5 = 0.08; w6 = 0.08; w7 = 0.06; }
   else if(lt.regime.IsPullback())
     { w0 = 0.20; w1 = 0.16; w2 = 0.14; w3 = 0.16; w4 = 0.12; w5 = 0.08; w6 = 0.08; w7 = 0.06; }
   else if(lt.regime.IsRangeExtreme())
     { w0 = 0.12; w1 = 0.12; w2 = 0.14; w3 = 0.24; w4 = 0.10; w5 = 0.14; w6 = 0.08; w7 = 0.06; }

   double blended = w0 * ATMI_Clamp01(e_bias)   + w1 * ATMI_Clamp01(e_struct) +
                    w2 * ATMI_Clamp01(e_trig)   + w3 * ATMI_Clamp01(e_zone)   +
                    w4 * ATMI_Clamp01(e_mom)    + w5 * ATMI_Clamp01(e_vol)    +
                    w6 * ATMI_Clamp01(e_fit)    + w7 * ATMI_Clamp01(e_quote);
   m_score = (dir == 0) ? 0 : (int)MathRound(blended * 100.0);
   m_eval_dir = dir;

   //--- what the printed parts describe (display only - the score above
   //--- stays 0 while no side has been chosen, so nothing can latch on it)
   m_parts_side  = pdir;
   m_parts_score = (pdir == 0) ? 0 : (int)MathRound(blended * 100.0);
   m_prov        = (dir == 0 && pdir != 0);

   //=== 5. the real, reachable price plan ============================
   m_entry = 0.0; m_sl = 0.0; m_tp1 = 0.0; m_tp2 = 0.0; m_tp3 = 0.0;
   m_sl_dist = 0.0; m_tp_dist = 0.0; m_rr = 0.0;
   m_expected_min = 0; m_use_limit = false;

   if(dir != 0 && m_veto == "")
     {
      double ref = (dir == 1) ? bid : ask;

      //--- entry: a real zone edge when one is close and on the right
      //--- side; otherwise enter at the current quote (confirmation).
      double zone  = (dir == 1) ? lt.smc.zone_buy : lt.smc.zone_sell;
      int    zkind2 = (dir == 1) ? lt.smc.zone_buy_kind : lt.smc.zone_sell_kind;
      double entry = ref;
      m_use_limit = false;
      if(zkind2 > 0 && zone > 0.0)
        {
         double gap = MathAbs(ref - zone);
         if(dir == 1 && zone < ref - stops_price && gap <= 0.60 * atr && gap >= 0.05 * atr)
           { entry = zone; m_use_limit = true; }
         else if(dir == -1 && zone > ref + stops_price && gap <= 0.60 * atr && gap >= 0.05 * atr)
           { entry = zone; m_use_limit = true; }
        }

      //--- stop: structural level + a wiggle buffer. In "open space"
      //--- (no usable structure) fall back to a volatility stop.
      double struct_level = (dir == 1) ? lt.smc.swing_lo : lt.smc.swing_hi;
      double struct_dist  = (struct_level > 0.0) ? MathAbs(entry - struct_level) : 0.0;
      double vol_sl       = profile.SlMult() * atr;
      double sl_dist;
      if(struct_dist >= 0.55 * atr && struct_dist <= 3.00 * atr)
         sl_dist = struct_dist + 0.25 * atr;
      else
         sl_dist = vol_sl;

      //--- never closer than the broker allows + the cost of the spread
      double min_sl = MathMax(stops_price, spread_price) + 0.10 * atr;
      if(sl_dist < min_sl)
         sl_dist = min_sl;

      //--- target: the symbol's own dial x its own wiggle (full = TP3)
      double tp_dist = profile.TpMult() * atr;
      double min_tp  = MathMax(stops_price * 2.0, MathMax(spread_price * 2.0, 0.50 * atr));
      if(tp_dist < min_tp)
         tp_dist = min_tp;

      //--- reachability: how long would that target realistically take?
      double drift = MathMax(0.20, MathMin(0.60, lt.eff)) * atr;   // net per bar
      double bars_needed = (drift > 0.0) ? tp_dist / drift : 9999.0;
      int eta = (int)MathRound(bars_needed * (double)lt.minutes);
      if(eta < 15) eta = 15;

      double rr = (sl_dist > 0.0) ? tp_dist / sl_dist : 0.0;

      //--- final quality gates on the numbers themselves
      if(sl_dist > 3.50 * atr)
         m_veto = "a safe stop would be absurdly wide here";
      else if(ref > 0.0 && sl_dist / ref > 0.030)
         m_veto = "stop too wide for an intraday trade on this symbol";
      else if(rr < 1.50)
         m_veto = StringFormat("risk:reward too thin (1:%.1f)", rr);
      else if(eta > LaneMaxMinutes())
         m_veto = "target not reachable inside this lane's window";

      if(m_veto == "")
        {
         m_entry      = entry;
         m_sl_dist    = sl_dist;
         m_tp_dist    = tp_dist;
         m_rr         = rr;
         m_expected_min = eta;
         if(dir == 1)
           {
            m_sl  = entry - sl_dist;
            m_tp1 = entry + 0.60 * tp_dist;
            m_tp2 = entry + 0.80 * tp_dist;
            m_tp3 = entry + tp_dist;
           }
         else
           {
            m_sl  = entry + sl_dist;
            m_tp1 = entry - 0.60 * tp_dist;
            m_tp2 = entry - 0.80 * tp_dist;
            m_tp3 = entry - tp_dist;
           }
         //--- round to the broker's price grid
         m_entry = NormalizeDouble(m_entry, m_digits);
         m_sl    = NormalizeDouble(m_sl, m_digits);
         m_tp1   = NormalizeDouble(m_tp1, m_digits);
         m_tp2   = NormalizeDouble(m_tp2, m_digits);
         m_tp3   = NormalizeDouble(m_tp3, m_digits);
        }
     }

   //=== 6. latch / release (hysteresis - no flickering) ==============
   m_tradable = false;
   bool gates_ok = (m_veto == "");

   //--- a new latch also has to wait for the lane's next closed bar after
   //--- a trade, so the EA cannot re-enter on the very same signal bar
   bool bar_is_free = (lt.md.bar_time != m_traded_bar);

   if(gates_ok && dir != 0 && m_score >= m_threshold && bar_is_free)
     {
      if(m_latch_dir != dir)
        {
         m_latch_dir    = dir;
         m_latch_time   = now;
         m_latch_bar    = lt.md.bar_time;
         m_latch_score  = m_score;
         m_latch_traded = false;
        }
      else
         m_latch_score = m_score;
     }

   if(m_latch_dir != 0)
     {
      bool release = false;
      string why   = "";
      if(!gates_ok)                      { release = true; why = m_veto; }
      else if(m_score < m_threshold - ATDE_RELEASE_BAND)
        { release = true; why = StringFormat("score fell to %d (line %d)", m_score, m_threshold); }
      else if(dir != 0 && cand == -m_latch_dir && MathAbs(vote) >= 3)
        { release = true; why = "direction flipped against the signal"; }
      else if(LatchAgeSec() > LaneMaxMinutes() * 60)
        { release = true; why = "signal grew too old"; }

      if(release)
        {
         ClearLatch();
         if(m_veto == "")
            m_veto = why;
        }
     }

   //=== 7. the published answer ======================================
   if(m_latch_dir == 0)
     {
      m_dir = AT_SIG_HOLD;
      m_reason = (m_veto != "") ? m_veto
                                : StringFormat("score %d below the %d needed", m_score, m_threshold);
     }
   else
     {
      m_dir      = (m_latch_dir == 1) ? AT_SIG_BUY : AT_SIG_SELL;
      m_tradable = gates_ok && (m_entry > 0.0) && (m_sl > 0.0) && (m_tp3 > 0.0);
      m_reason   = StringFormat("latched, score %d vs %d needed", m_latch_score, m_threshold);
     }

   return m_ready;
  }
//+------------------------------------------------------------------+
#endif // AUTOTRADER_DIRECTION_ENGINE_MQH
