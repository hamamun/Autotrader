//+------------------------------------------------------------------+
//| ModernIndicators.mqh                                              |
//| Autotrader Phase 3 - the 2026 indicator stack, hand written.      |
//|                                                                   |
//| Everything here is plain MQL5 maths over CLOSED bars (r[0] = the  |
//| newest closed bar). No external library, no DLL, no Python, no    |
//| indicator handles to leak - just functions.                       |
//|                                                                   |
//| What is in the box:                                               |
//|   * Nadaraya-Watson Gaussian kernel regression (non-repainting)   |
//|     + its own error band, used as trend baseline and realistic    |
//|     target reference.                                             |
//|   * Ehlers DSP family: Super Smoother, Decycler + Decycler        |
//|     Oscillator, Laguerre RSI (adaptive gamma) - near-zero-lag     |
//|     triggers instead of slow MACD-style logic.                    |
//|   * Kalman local-level trend line with ATR-adaptive noise.        |
//|   * The honest classics: Wilder ATR, EMA/SMA, efficiency ratio,   |
//|     VWAP, slope in ATR units, standard deviation.                 |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_MODERN_INDICATORS_MQH
#define AUTOTRADER_MODERN_INDICATORS_MQH

//+------------------------------------------------------------------+
//| simple averages                                                   |
//+------------------------------------------------------------------+
double ATMI_Sma(const MqlRates &r[], const int period, const int shift)
  {
   int n = ArraySize(r);
   if(period <= 0 || shift < 0 || shift + period >= n)
      return 0.0;
   double s = 0.0;
   for(int i = 0; i < period; i++)
      s += r[shift + i].close;
   return s / (double)period;
  }

double ATMI_Ema(const MqlRates &r[], const int period, const int shift)
  {
   int n = ArraySize(r);
   if(period <= 1 || shift < 0 || shift >= n || n < period + 2)
      return 0.0;
   double k = 2.0 / ((double)period + 1.0);
   double ema = r[n - 1].close;                 // oldest bar seeds it
   for(int idx = n - 2; idx >= shift; idx--)
      ema = r[idx].close * k + ema * (1.0 - k);
   return ema;
  }

//+------------------------------------------------------------------+
//| Wilder ATR (price units), closed bars only                        |
//+------------------------------------------------------------------+
double ATMI_Atr(const MqlRates &r[], const int period, const int shift)
  {
   int n = ArraySize(r);
   if(period <= 1 || shift < 0 || shift + period + 1 >= n)
      return 0.0;
   double atr = 0.0;
   int first = shift + period;                  // seed bar
   for(int i = 0; i < period; i++)              // simple average seed
     {
      int k = first - i;
      double pc = r[k + 1].close;
      atr += MathMax(r[k].high - r[k].low,
                     MathMax(MathAbs(r[k].high - pc), MathAbs(r[k].low - pc)));
     }
   atr /= (double)period;
   for(int k = first - period; k >= shift; k--) // Wilder smoothing
     {
      double pc = r[k + 1].close;
      double tr = MathMax(r[k].high - r[k].low,
                          MathMax(MathAbs(r[k].high - pc), MathAbs(r[k].low - pc)));
      atr = (atr * ((double)period - 1.0) + tr) / (double)period;
     }
   return atr;
  }

//+------------------------------------------------------------------+
//| longest / shortest of the last n bars (from shift)                |
//+------------------------------------------------------------------+
double ATMI_Highest(const MqlRates &r[], const int n, const int shift)
  {
   int cnt = ArraySize(r);
   double v = 0.0;
   for(int i = 0; i < n; i++)
     {
      int k = shift + i;
      if(k >= cnt) break;
      if(i == 0 || r[k].high > v) v = r[k].high;
     }
   return v;
  }

double ATMI_Lowest(const MqlRates &r[], const int n, const int shift)
  {
   int cnt = ArraySize(r);
   double v = 0.0;
   for(int i = 0; i < n; i++)
     {
      int k = shift + i;
      if(k >= cnt) break;
      if(i == 0 || r[k].low < v) v = r[k].low;
     }
   return v;
  }

//+------------------------------------------------------------------+
//| Ehlers Super Smoother - 2 pole, near zero lag, no aliasing        |
//+------------------------------------------------------------------+
double ATMI_SuperSmoother(const MqlRates &r[], const int period, const int shift)
  {
   int n = ArraySize(r);
   if(period < 4 || shift < 0 || shift >= n || n < period + 4)
      return 0.0;
   double a1 = MathExp(-1.414 * M_PI * 2.0 / (double)period);
   double b1 = 2.0 * a1 * MathCos(1.414 * M_PI / (double)period);
   double c2 = b1;
   double c3 = -a1 * a1;
   double c1 = 1.0 - c2 - c3;

   double seed = r[n - 1].close;
   double prev2 = seed, prev1 = seed, val = seed;
   for(int k = n - 2; k >= shift; k--)
     {
      val   = c1 * (r[k].close + r[k + 1].close) / 2.0 + c2 * prev1 + c3 * prev2;
      prev2 = prev1;
      prev1 = val;
     }
   return val;
  }

//+------------------------------------------------------------------+
//| Ehlers Decycler - the same recursion used as a high-pass cutter;  |
//| the returned value is the "decycled" (cycle-free) price.          |
//+------------------------------------------------------------------+
double ATMI_Decycler(const MqlRates &r[], const int period, const int shift)
  {
   return ATMI_SuperSmoother(r, period, shift);
  }

//--- Decycler Oscillator, in % of the decycled price: >0 = price is
//--- above its own cycle-free line (short-term push up), <0 = below.
double ATMI_DecyclerOscPct(const MqlRates &r[], const int period, const int shift)
  {
   int n = ArraySize(r);
   if(shift < 0 || shift >= n)
      return 0.0;
   double d = ATMI_Decycler(r, period, shift);
   if(d <= 0.0)
      return 0.0;
   return (r[shift].close - d) / d * 100.0;
  }

//+------------------------------------------------------------------+
//| Ehlers Laguerre RSI, 0..1. gamma (alpha) sets the responsiveness; |
//| the caller adapts it to how clean the current move is.            |
//+------------------------------------------------------------------+
double ATMI_LaguerreRSI(const MqlRates &r[], const double gamma, const int shift)
  {
   int n = ArraySize(r);
   if(shift < 0 || shift >= n || n < 24)
      return 0.5;
   double a = gamma;
   if(a < 0.05) a = 0.05;
   if(a > 0.95) a = 0.95;

   double seed = r[n - 1].close;
   double L0 = seed, L1 = seed, L2 = seed, L3 = seed;
   double fir = 0.5;
   for(int k = n - 1; k >= shift; k--)
     {
      double price = r[k].close;
      double l0p = L0, l1p = L1, l2p = L2, l3p = L3;
      L0 = (1.0 - a) * price + a * l0p;
      L1 = -l0p + L0 + a * l1p;
      L2 = -l1p + L1 + a * l2p;
      L3 = -l2p + L2 + a * l3p;

      double cu = MathMax(L0 - L1, 0.0) + MathMax(L1 - L2, 0.0) +
                  MathMax(L2 - L3, 0.0);
      double cd = MathMax(L1 - L0, 0.0) + MathMax(L2 - L1, 0.0) +
                  MathMax(L3 - L2, 0.0);
      if(cu + cd > 0.0)
         fir = cu / (cu + cd);
     }
   return fir;
  }

//+------------------------------------------------------------------+
//| Nadaraya-Watson Gaussian kernel regression - NON REPAINTING.      |
//|                                                                   |
//| The fit at a bar uses only that bar and the `lookback` bars       |
//| BEFORE it, with Gaussian weights exp(-d^2 / 2h^2). No future bar  |
//| is ever touched, so the line cannot redraw itself later.          |
//| mae returns the weighted mean absolute error of the fit - that is |
//| the adaptive envelope width (a calm market gets a tight envelope, |
//| a wild one gets a wide one, automatically).                       |
//+------------------------------------------------------------------+
double ATMI_NW(const MqlRates &r[], const int lookback, const double h_bars,
               const int shift, double &mae)
  {
   mae = 0.0;
   int n = ArraySize(r);
   if(lookback < 6 || shift < 0 || shift + lookback >= n)
      return 0.0;

   double h = h_bars;
   if(h < 1.0)  h = 1.0;
   if(h > 60.0) h = 60.0;
   double denom = 2.0 * h * h;

   double sw = 0.0, swy = 0.0;
   for(int i = 0; i < lookback; i++)
     {
      double d  = (double)i;
      double w  = MathExp(-(d * d) / denom);
      sw  += w;
      swy += w * r[shift + i].close;
     }
   if(sw <= 0.0)
      return 0.0;
   double y = swy / sw;

   double ae = 0.0;
   for(int i = 0; i < lookback; i++)
     {
      double d = (double)i;
      double w = MathExp(-(d * d) / denom);
      ae += w * MathAbs(r[shift + i].close - y);
     }
   mae = ae / sw;
   return y;
  }

//+------------------------------------------------------------------+
//| Kalman local-level filter. q = process noise, rr = measurement    |
//| noise, both in price^2 - the caller derives them from ATR and the |
//| live spread, so the filter trusts price more in calm markets and  |
//| smooths harder when the quotes are noisy.                         |
//+------------------------------------------------------------------+
double ATMI_Kalman(const MqlRates &r[], const double q, const double rr,
                   const int shift)
  {
   int n = ArraySize(r);
   if(shift < 0 || shift >= n || n < 6)
      return 0.0;
   double qq = (q > 0.0) ? q : 1e-8;
   double rn = (rr > 0.0) ? rr : 1e-8;
   double est = r[n - 1].close;
   double err = rn;
   for(int k = n - 2; k >= shift; k--)
     {
      err += qq;
      double kg = err / (err + rn);
      est += kg * (r[k].close - est);
      err *= (1.0 - kg);
     }
   return est;
  }

//--- Kalman slope over `back` bars, in ATR units per bar
double ATMI_KalmanSlope(const MqlRates &r[], const double q, const double rr,
                        const int back, const double atr)
  {
   if(atr <= 0.0 || back < 1)
      return 0.0;
   double now  = ATMI_Kalman(r, q, rr, 0);
   double then = ATMI_Kalman(r, q, rr, back);
   if(now <= 0.0 || then <= 0.0)
      return 0.0;
   return (now - then) / atr / (double)back;
  }

//+------------------------------------------------------------------+
//| efficiency ratio (Kaufman): straight-line move / total wiggle     |
//+------------------------------------------------------------------+
double ATMI_Efficiency(const MqlRates &r[], const int n, const int shift)
  {
   int cnt = ArraySize(r);
   if(n < 2 || shift < 0 || shift + n >= cnt)
      return 0.0;
   double path = 0.0;
   for(int i = 0; i < n; i++)
      path += MathAbs(r[shift + i].close - r[shift + i + 1].close);
   if(path <= 0.0)
      return 0.0;
   return MathAbs(r[shift].close - r[shift + n].close) / path;
  }

//--- slope of the close over n bars, in ATR units per bar
double ATMI_SlopeAtr(const MqlRates &r[], const int n, const double atr,
                     const int shift)
  {
   int cnt = ArraySize(r);
   if(atr <= 0.0 || n < 1 || shift < 0 || shift + n >= cnt)
      return 0.0;
   return (r[shift].close - r[shift + n].close) / atr / (double)n;
  }

//+------------------------------------------------------------------+
//| VWAP over the last n bars from shift                              |
//+------------------------------------------------------------------+
double ATMI_Vwap(const MqlRates &r[], const int n, const int shift)
  {
   int cnt = ArraySize(r);
   double pv = 0.0, vv = 0.0;
   for(int i = 0; i < n; i++)
     {
      int k = shift + i;
      if(k >= cnt) break;
      double tp = (r[k].high + r[k].low + r[k].close) / 3.0;
      double v  = (double)r[k].tick_volume;
      pv += tp * v;
      vv += v;
     }
   return (vv > 0.0) ? pv / vv : 0.0;
  }

//+------------------------------------------------------------------+
//| standard deviation of the close over n bars                       |
//+------------------------------------------------------------------+
double ATMI_Stdev(const MqlRates &r[], const int n, const int shift)
  {
   int cnt = ArraySize(r);
   if(n < 3 || shift < 0 || shift + n >= cnt)
      return 0.0;
   double mean = 0.0;
   for(int i = 0; i < n; i++) mean += r[shift + i].close;
   mean /= (double)n;
   double s = 0.0;
   for(int i = 0; i < n; i++)
     {
      double d = r[shift + i].close - mean;
      s += d * d;
     }
   return MathSqrt(s / (double)n);
  }

//+------------------------------------------------------------------+
//| clamp helper used all over the evidence maths                     |
//+------------------------------------------------------------------+
double ATMI_Clamp01(const double v)
  {
   if(v < 0.0) return 0.0;
   if(v > 1.0) return 1.0;
   return v;
  }

#endif // AUTOTRADER_MODERN_INDICATORS_MQH
