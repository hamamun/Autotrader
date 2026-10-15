//+------------------------------------------------------------------+
//| RegimeEngine.mqh                                                  |
//| Autotrader Phase 2 - Regime Engine.                               |
//|                                                                   |
//| In plain words: it reads the market's current "mood" and says it  |
//| SPECIFICALLY - not just TRENDING, but which direction, how        |
//| strong, and (when sideways) where price is inside the range.      |
//|                                                                   |
//| Owner-agreed display list (Panel.mqh colour rule still applies:   |
//| the Regime row is plain soft text; only SIGNAL/STATUS colour):    |
//|   ▲ TRENDING UP - Strong / Weak-Early                             |
//|   ▼ TRENDING DOWN - Strong / Weak-Early                           |
//|   ↩ PULLBACK in UPTREND   /   ↪ PULLBACK in DOWNTREND             |
//|   ↔ RANGING - price at range TOP / BOTTOM / in MIDDLE             |
//|   ⚠ VOLATILE - fast swings both ways                              |
//|   ● QUIET - flat, compressed                                      |
//|   ? TRANSITION - direction unclear                                |
//|                                                                   |
//| Method (no black box): direction agreement (close vs averages,    |
//| average slope, higher-high/higher-low structure), trend           |
//| efficiency (how straight the move is vs how much it wiggles),     |
//| current wiggle size vs its own normal, and position inside the    |
//| recent range. It does NOT decide BUY/SELL (that is Phase 3); it   |
//| tells Phase 3 HOW to behave: follow pullbacks in trends, fade     |
//| range extremes, and mostly stay out when volatile/quiet.          |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_REGIME_ENGINE_MQH
#define AUTOTRADER_REGIME_ENGINE_MQH

//--- extra glyphs for the regime row (code points, encoding-proof;
//--- ▲▼-✓ are already defined in Panel.mqh, which is included first)
#define GLYPH_SIDE   ShortToString(0x2194)  // left-right arrow (sideways)
#define GLYPH_PB_UP  ShortToString(0x21A9)  // pullback hook (in uptrend)
#define GLYPH_PB_DN  ShortToString(0x21AA)  // pullback hook (in downtrend)
#define GLYPH_WARN   ShortToString(0x26A0)  // warning sign (volatile)
#define GLYPH_DOT    ShortToString(0x25CF)  // filled circle (quiet)

enum ENUM_AT_REGIME
  {
   AT_REGIME_CALIBRATING = 0,
   AT_REGIME_TREND_UP,
   AT_REGIME_TREND_DOWN,
   AT_REGIME_PULLBACK_UP,     // pullback inside an uptrend
   AT_REGIME_PULLBACK_DOWN,   // pullback (bounce) inside a downtrend
   AT_REGIME_RANGE_TOP,
   AT_REGIME_RANGE_MIDDLE,
   AT_REGIME_RANGE_BOTTOM,
   AT_REGIME_VOLATILE,
   AT_REGIME_QUIET,
   AT_REGIME_TRANSITION
  };

struct SATRegimeInfo
  {
   bool           ready;
   ENUM_AT_REGIME kind;
   int            direction;      // +1 up, -1 down, 0 none/unclear
   string         display;        // exact text shown after "Regime: "
   double         efficiency;     // 0..1, how straight the move is
   double         atr_ratio;      // current wiggle vs its own normal
   double         range_pos;      // 0 = range bottom, 1 = range top
   int            bars_used;
   //--- Phase 3 reads these too (the direction engine's evidence)
   double         atr;            // current wiggle size, price units
   double         slope50;        // EMA50 slope in ATRs over 10 bars
   int            score;          // direction agreement, -5..+5
   double         range_hi;       // recent 60-bar range top
   double         range_lo;       // recent 60-bar range bottom
   int            sign_changes;   // how two-way the last 12 candles were
  };

//+------------------------------------------------------------------+
//| EMA value over chronological closes (oldest first), ending        |
//| shift_back bars before the newest close.                          |
//+------------------------------------------------------------------+
double AT_EmaAt(const double &close_chron[], const int period, const int shift_back)
  {
   int n = ArraySize(close_chron);
   if(n <= period || shift_back < 0 || shift_back >= n)
      return 0.0;
   double k = 2.0 / (period + 1.0);
   double ema = close_chron[0];
   int upto = n - 1 - shift_back;
   for(int i = 1; i <= upto; i++)
      ema = close_chron[i] * k + ema * (1.0 - k);
   return ema;
  }

//+------------------------------------------------------------------+
//| Regime engine                                                     |
//+------------------------------------------------------------------+
class CRegimeEngine
  {
private:
   SATRegimeInfo     m_info;

   void              SetInfo(const ENUM_AT_REGIME kind, const int dir,
                             const string display);

public:
                     CRegimeEngine(void);

   //--- classify the market now, on the given timeframe
   bool              Refresh(const string symbol, const ENUM_TIMEFRAMES tf);

   bool              Ready(void)      const { return m_info.ready; }
   ENUM_AT_REGIME    Kind(void)       const { return m_info.kind; }
   int               Direction(void)  const { return m_info.direction; }
   string            Display(void)    const { return m_info.display; }
   //--- Phase 3+ getters: the direction engine reads the raw evidence
   //--- behind the label, not just the label itself.
   double            Efficiency(void) const { return m_info.efficiency; }
   double            AtrRatio(void)   const { return m_info.atr_ratio; }
   double            RangePos(void)   const { return m_info.range_pos; }
   int               BarsUsed(void)   const { return m_info.bars_used; }
   double            Atr(void)        const { return m_info.atr; }
   double            Slope50(void)    const { return m_info.slope50; }
   int               Score(void)      const { return m_info.score; }
   double            RangeHi(void)    const { return m_info.range_hi; }
   double            RangeLo(void)    const { return m_info.range_lo; }
   int               SignChanges(void) const { return m_info.sign_changes; }
   bool              IsTrend(void)    const
     { return (m_info.kind == AT_REGIME_TREND_UP || m_info.kind == AT_REGIME_TREND_DOWN); }
   bool              IsPullback(void) const
     { return (m_info.kind == AT_REGIME_PULLBACK_UP || m_info.kind == AT_REGIME_PULLBACK_DOWN); }
   bool              IsRangeExtreme(void) const
     { return (m_info.kind == AT_REGIME_RANGE_TOP || m_info.kind == AT_REGIME_RANGE_BOTTOM); }
   //--- Regime-only execution gate; directional evidence is scored separately.
   //--- VOLATILE / QUIET / TRANSITION / CALIBRATING / range-middle block new
   //--- entries, but the direction engine may still display a supported bias.
   bool              Tradable(void)   const
     { return (IsTrend() || IsPullback() || IsRangeExtreme()); }
   //--- note: no whole-struct getter - callers use the typed getters
   //--- above (keeps this header to plain, portable MQL5 constructs)
  };

//+------------------------------------------------------------------+
CRegimeEngine::CRegimeEngine(void)
  {
   //--- explicit init (no ZeroMemory on a struct containing a string)
   m_info.ready = false;
   m_info.kind = AT_REGIME_CALIBRATING;
   m_info.direction = 0;
   m_info.display = GLYPH_DOT + " CALIBRATING " + GLYPH_DASH +
                    " collecting price history";
   m_info.efficiency = 0.0;
   m_info.atr_ratio = 0.0;
   m_info.range_pos = 0.5;
   m_info.bars_used = 0;
   m_info.atr = 0.0;
   m_info.slope50 = 0.0;
   m_info.score = 0;
   m_info.range_hi = 0.0;
   m_info.range_lo = 0.0;
   m_info.sign_changes = 0;
  }

void CRegimeEngine::SetInfo(const ENUM_AT_REGIME kind, const int dir,
                            const string display)
  {
   m_info.kind = kind;
   m_info.direction = dir;
   m_info.display = display;
   m_info.ready = (kind != AT_REGIME_CALIBRATING);
  }

//+------------------------------------------------------------------+
//| Classify. Uses closed bars only (no repainting on the live bar).  |
//+------------------------------------------------------------------+
bool CRegimeEngine::Refresh(const string symbol, const ENUM_TIMEFRAMES tf)
  {
   MqlRates rates[];
   int n = CopyRates(symbol, tf, 1, 160, rates);
   m_info.bars_used = MathMax(n, 0);
   if(n < 120)
     {
      SetInfo(AT_REGIME_CALIBRATING, 0,
              GLYPH_DOT + " CALIBRATING " + GLYPH_DASH +
              " collecting price history");
      return false;
     }
   ArraySetAsSeries(rates, true);   // rates[0] = newest closed bar

   //--- chronological closes (oldest first) for the averages
   double closes[];
   ArrayResize(closes, n);
   for(int i = 0; i < n; i++)
      closes[i] = rates[n - 1 - i].close;

   double close0 = rates[0].close;
   double ema20  = AT_EmaAt(closes, 20, 0);
   double ema50  = AT_EmaAt(closes, 50, 0);
   double ema50b = AT_EmaAt(closes, 50, 10);
   double ema100 = AT_EmaAt(closes, 100, 0);

   //--- current wiggle (ATR-style) vs its own normal
   double tr_now = 0.0, tr_base = 0.0;
   for(int i = 0; i < n; i++)
     {
      double pc = (i + 1 < n) ? rates[i + 1].close : rates[i].close;
      double tr = MathMax(rates[i].high - rates[i].low,
                          MathMax(MathAbs(rates[i].high - pc),
                                  MathAbs(rates[i].low - pc)));
      if(i < 14) tr_now += tr;
      else if(i < 114) tr_base += tr;
     }
   double atr = tr_now / 14.0;
   double atr_base = (tr_base > 0.0) ? tr_base / 100.0 : atr;
   m_info.atr = atr;
   if(atr <= 0.0)
     {
      SetInfo(AT_REGIME_CALIBRATING, 0,
              GLYPH_DOT + " CALIBRATING " + GLYPH_DASH +
              " collecting price history");
      return false;
     }
   m_info.atr_ratio = atr / MathMax(atr_base, atr * 0.0001);

   //--- trend efficiency: straight-line distance vs total wiggle path
   double path = 0.0;
   for(int i = 0; i < 20; i++)
      path += MathAbs(rates[i].close - rates[i + 1].close);
   m_info.efficiency = (path > 0.0)
                       ? MathAbs(close0 - rates[20].close) / path : 0.0;

   //--- structure: are highs AND lows rising (up) or falling (down)?
   double hi_recent = rates[1].high, hi_prev = rates[16].high;
   double lo_recent = rates[1].low,  lo_prev = rates[16].low;
   for(int i = 1; i <= 12; i++)
     {
      hi_recent = MathMax(hi_recent, rates[i].high);
      lo_recent = MathMin(lo_recent, rates[i].low);
     }
   for(int i = 16; i <= 30; i++)
     {
      hi_prev = MathMax(hi_prev, rates[i].high);
      lo_prev = MathMin(lo_prev, rates[i].low);
     }
   int structure = 0;
   if(hi_recent > hi_prev && lo_recent > lo_prev) structure = 1;
   else if(hi_recent < hi_prev && lo_recent < lo_prev) structure = -1;

   //--- direction agreement score (-5..+5): five independent witnesses
   double slope50 = (ema50 - ema50b) / atr;   // in ATRs over 10 bars
   int score = 0;
   score += (close0 > ema50) ? 1 : -1;
   score += (ema20 > ema50) ? 1 : -1;
   score += (slope50 > 0.02) ? 1 : ((slope50 < -0.02) ? -1 : 0);
   score += structure;
   score += (close0 > ema100) ? 1 : -1;

   //--- position inside the recent 60-bar range (0 bottom, 1 top)
   double r_hi = rates[0].high, r_lo = rates[0].low;
   for(int i = 0; i < 60; i++)
     {
      r_hi = MathMax(r_hi, rates[i].high);
      r_lo = MathMin(r_lo, rates[i].low);
     }
   m_info.range_pos = (r_hi > r_lo) ? (close0 - r_lo) / (r_hi - r_lo) : 0.5;
   //--- keep the raw evidence for the Phase 3 direction engine
   m_info.slope50 = slope50;
   m_info.score   = score;
   m_info.range_hi = r_hi;
   m_info.range_lo = r_lo;

   //--- how two-way are the recent candles? (for VOLATILE)
   int sign_changes = 0, prev_sign = 0;
   for(int i = 11; i >= 0; i--)
     {
      int s = (rates[i].close >= rates[i].open) ? 1 : -1;
      if(prev_sign != 0 && s != prev_sign)
         sign_changes++;
      prev_sign = s;
     }
   m_info.sign_changes = sign_changes;

   double ret8 = (close0 - rates[8].close) / atr;   // last 8 bars, in ATRs

   //=== classification (order matters: safety states first) ===

   //--- VOLATILE: wiggle exploded AND movement is two-way/chaotic.
   //--- (A fast but one-directional move is a strong trend, below.)
   if(m_info.atr_ratio >= 1.60 && (m_info.efficiency < 0.50 || sign_changes >= 4))
     {
      SetInfo(AT_REGIME_VOLATILE, 0,
              GLYPH_WARN + " VOLATILE " + GLYPH_DASH +
              " fast swings both ways");
      return true;
     }

   //--- QUIET: wiggle far below normal and price barely going anywhere
   double h20 = rates[0].high, l20 = rates[0].low;
   for(int i = 0; i < 20; i++)
     {
      h20 = MathMax(h20, rates[i].high);
      l20 = MathMin(l20, rates[i].low);
     }
   double range20 = h20 - l20;
   if(m_info.atr_ratio <= 0.62 && m_info.efficiency < 0.30 && range20 <= 5.0 * atr)
     {
      SetInfo(AT_REGIME_QUIET, 0,
              GLYPH_DOT + " QUIET " + GLYPH_DASH + " flat, compressed");
      return true;
     }

   //--- PULLBACK: main trend intact, short move against it, still on
   //--- the trend's side of the slow average (temporary, not reversal)
   bool primary_up   = (ema50 > ema100 && slope50 > 0.03);
   bool primary_down = (ema50 < ema100 && slope50 < -0.03);
   if(primary_up && ret8 < -0.40 && close0 < ema20 && close0 > ema100)
     {
      SetInfo(AT_REGIME_PULLBACK_UP, 1,
              GLYPH_PB_UP + " PULLBACK in UPTREND");
      return true;
     }
   if(primary_down && ret8 > 0.40 && close0 > ema20 && close0 < ema100)
     {
      SetInfo(AT_REGIME_PULLBACK_DOWN, -1,
              GLYPH_PB_DN + " PULLBACK in DOWNTREND");
      return true;
     }

   //--- TRENDING: straight enough move + witnesses agree on direction
   if(m_info.efficiency >= 0.33 && MathAbs(score) >= 3)
     {
      bool strong = (m_info.efficiency >= 0.52 && MathAbs(score) >= 4);
      string strength = strong ? "Strong" : "Weak/Early";
      if(score > 0)
         SetInfo(AT_REGIME_TREND_UP, 1,
                 GLYPH_UP + " TRENDING UP " + GLYPH_DASH + " " + strength);
      else
         SetInfo(AT_REGIME_TREND_DOWN, -1,
                 GLYPH_DOWN + " TRENDING DOWN " + GLYPH_DASH + " " + strength);
      return true;
     }

   //--- TRANSITION: price HAS moved (not flat/range-like) but the
   //--- direction witnesses disagree - genuinely unclear. (Checked
   //--- before RANGING so this state is actually reachable.)
   if(m_info.efficiency >= 0.30 && MathAbs(score) <= 2)
     {
      SetInfo(AT_REGIME_TRANSITION, 0,
              "? TRANSITION " + GLYPH_DASH + " direction unclear");
      return true;
     }

   //--- RANGING: not trending - say WHERE price is inside the range
   if(m_info.range_pos >= 0.80)
      SetInfo(AT_REGIME_RANGE_TOP, 0,
              GLYPH_SIDE + " RANGING " + GLYPH_DASH + " price at range TOP");
   else if(m_info.range_pos <= 0.20)
      SetInfo(AT_REGIME_RANGE_BOTTOM, 0,
              GLYPH_SIDE + " RANGING " + GLYPH_DASH + " price at range BOTTOM");
   else
      SetInfo(AT_REGIME_RANGE_MIDDLE, 0,
              GLYPH_SIDE + " RANGING " + GLYPH_DASH + " price in MIDDLE");
   return true;
  }

#endif // AUTOTRADER_REGIME_ENGINE_MQH
