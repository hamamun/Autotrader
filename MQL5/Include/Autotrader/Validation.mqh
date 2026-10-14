//+------------------------------------------------------------------+
//| Validation.mqh                                                    |
//| Autotrader Phase 7 - the statistics behind the validation gates.  |
//|                                                                   |
//| Pure MQL5. Used only by the Phase 7 scripts (Phase7_Report and    |
//| Phase7_Permutation). The EA never includes this file, so the EA   |
//| stays as it is.                                                   |
//|                                                                   |
//| Contents                                                          |
//|   VAL_Phi / VAL_PhiInv   normal distribution                      |
//|   VAL_WilsonLower        95% lower bound of a win rate            |
//|   VAL_Moments            per-trade Sharpe, skew, kurtosis         |
//|   VAL_DeflatedSharpe     Deflated Sharpe Ratio (Bailey & L.d.P.)  |
//|   VAL_MaxDrawdown        drawdown of an ordered trade list        |
//|   VAL_ShuffledDrawdown   drawdown range from reshuffled trades    |
//|   VAL_PBO                Probability of Backtest Overfitting      |
//|                          (combinatorially symmetric CV)           |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_VALIDATION_MQH
#define AUTOTRADER_VALIDATION_MQH

#define VAL_EULER_GAMMA 0.5772156649
#define VAL_E           2.718281828459045
#define VAL_WILSON_Z    1.959964

//+------------------------------------------------------------------+
//| standard normal cumulative distribution (error < 1.5e-7)          |
//+------------------------------------------------------------------+
double VAL_Phi(const double x)
  {
   double z    = MathAbs(x) / MathSqrt(2.0);
   double t    = 1.0 / (1.0 + 0.3275911 * z);
   double poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 +
                 t * (-1.453152027 + t * 1.061405429))));
   double erf  = 1.0 - poly * MathExp(-z * z);
   return (x >= 0.0) ? 0.5 * (1.0 + erf) : 0.5 * (1.0 - erf);
  }

//+------------------------------------------------------------------+
//| inverse of the normal distribution (Acklam's approximation)       |
//+------------------------------------------------------------------+
double VAL_PhiInv(const double p)
  {
   if(p <= 0.0) return -8.0;
   if(p >= 1.0) return  8.0;

   double a[6] = {-39.69683028665376, 220.9460984245205, -275.9285104469687,
                  138.3577518672690, -30.66479806614716, 2.506628277459239};
   double b[5] = {-54.47609879822406, 161.5858368580409, -155.6989798598866,
                  66.80131188771972, -13.28068155288572};
   double c[6] = {-0.007784894002430293, -0.3223964580411365, -2.400758277161838,
                  -2.549732539343734, 4.374664141464968, 2.938163982698783};
   double d[4] = {0.007784695709041462, 0.3224671290700398, 2.445134137142996,
                  3.754408661907416};

   double plow  = 0.02425;
   double phigh = 1.0 - plow;
   double q, r;

   if(p < plow)
     {
      q = MathSqrt(-2.0 * MathLog(p));
      return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
             ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0);
     }
   if(p > phigh)
     {
      q = MathSqrt(-2.0 * MathLog(1.0 - p));
      return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
              ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0);
     }
   q = p - 0.5;
   r = q * q;
   return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
          (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1.0);
  }

//+------------------------------------------------------------------+
//| Wilson 95% lower bound of wins / n                                |
//| (with 200 trades, a 98% win rate gives about 95% here)            |
//+------------------------------------------------------------------+
double VAL_WilsonLower(const int wins, const int n)
  {
   if(n <= 0) return 0.0;
   double z2     = VAL_WILSON_Z * VAL_WILSON_Z;
   double p      = (double)wins / (double)n;
   double centre = p + z2 / (2.0 * n);
   double margin = VAL_WILSON_Z * MathSqrt(p * (1.0 - p) / n + z2 / (4.0 * n * n));
   return (centre - margin) / (1.0 + z2 / n);
  }

//+------------------------------------------------------------------+
//| per-trade Sharpe (not annualised), skewness and kurtosis          |
//+------------------------------------------------------------------+
void VAL_Moments(const double &x[], const int n, double &sr, double &skew, double &kurt)
  {
   sr = 0.0;
   skew = 0.0;
   kurt = 3.0;
   if(n < 3)
      return;

   double m = 0.0;
   for(int i = 0; i < n; i++)
      m += x[i];
   m /= n;

   double m2 = 0.0, m3 = 0.0, m4 = 0.0;
   for(int i = 0; i < n; i++)
     {
      double dv = x[i] - m;
      m2 += dv * dv;
      m3 += dv * dv * dv;
      m4 += dv * dv * dv * dv;
     }
   m2 /= n;
   m3 /= n;
   m4 /= n;

   double sd = MathSqrt(m2);
   if(sd <= 0.0)
      return;
   sr   = m / sd;
   skew = m3 / (sd * sd * sd);
   kurt = m4 / (m2 * m2);
  }

//+------------------------------------------------------------------+
//| Deflated Sharpe Ratio: probability that the true Sharpe is above  |
//| the best Sharpe expected from N trials by luck alone.             |
//|   sr      per-trade Sharpe of the result being judged             |
//|   T       number of trades                                        |
//|   N       number of trials (runs) that were compared              |
//|   var_sr  variance of the Sharpe values across those trials       |
//+------------------------------------------------------------------+
double VAL_DeflatedSharpe(const double sr, const int T, const double skew,
                          const double kurt, const int N, const double var_sr)
  {
   if(T < 3)
      return 0.0;

   double sr0 = 0.0;
   if(N > 1 && var_sr > 0.0)
      sr0 = MathSqrt(var_sr) * ((1.0 - VAL_EULER_GAMMA) * VAL_PhiInv(1.0 - 1.0 / N) +
            VAL_EULER_GAMMA * VAL_PhiInv(1.0 - 1.0 / (N * VAL_E)));

   double denom = 1.0 - skew * sr + (kurt - 1.0) / 4.0 * sr * sr;
   if(denom <= 0.0)
      return 0.0;

   double z = (sr - sr0) * MathSqrt(T - 1.0) / MathSqrt(denom);
   return VAL_Phi(z);
  }

//+------------------------------------------------------------------+
//| largest peak-to-trough fall of the running total (money)          |
//+------------------------------------------------------------------+
double VAL_MaxDrawdown(const double &pnl[], const int n)
  {
   double cum = 0.0, peak = 0.0, dd = 0.0;
   for(int i = 0; i < n; i++)
     {
      cum += pnl[i];
      if(cum > peak)
         peak = cum;
      if(peak - cum > dd)
         dd = peak - cum;
     }
   return dd;
  }

//+------------------------------------------------------------------+
//| drawdown range: reshuffle the trade order 'runs' times and return |
//| the drawdown at percentile pct (0.95 = the 95th percentile)       |
//+------------------------------------------------------------------+
double VAL_ShuffledDrawdown(const double &pnl[], const int n, const int runs, const double pct)
  {
   if(n < 2 || runs < 1)
      return VAL_MaxDrawdown(pnl, n);

   double work[];
   double dds[];
   ArrayResize(work, n);
   ArrayResize(dds, runs);

   for(int r = 0; r < runs; r++)
     {
      for(int i = 0; i < n; i++)
         work[i] = pnl[i];
      for(int i = n - 1; i > 0; i--)
        {
         int j = (int)(MathRand() % (i + 1));
         double tmp = work[i];
         work[i] = work[j];
         work[j] = tmp;
        }
      dds[r] = VAL_MaxDrawdown(work, n);
     }

   ArraySort(dds);
   int k = (int)MathCeil(pct * runs) - 1;
   if(k < 0)
      k = 0;
   if(k > runs - 1)
      k = runs - 1;
   return dds[k];
  }

//+------------------------------------------------------------------+
//| Probability of Backtest Overfitting (CSCV)                        |
//|   m[b * N + j]  result of trial j inside time block b (S blocks)  |
//| Every way of choosing half of the blocks as "in-sample" is tried. |
//| The trial that is best in-sample is checked out-of-sample. If it  |
//| lands in the lower half there, that split counts as overfitting.  |
//| 'combos' returns how many splits were examined.                   |
//+------------------------------------------------------------------+
double VAL_PBO(const double &m[], const int S, const int N, int &combos)
  {
   combos = 0;
   if(S < 2 || S > 16 || N < 2)
      return 1.0;

   int half = S / 2;
   int overfit = 0;

   for(int mask = 0; mask < (1 << S); mask++)
     {
      int bits = 0;
      for(int b = 0; b < S; b++)
         if(((mask >> b) & 1) == 1)
            bits++;
      if(bits != half)
         continue;
      combos++;

      //--- the in-sample winner
      int    best = 0;
      double best_is = -1.0e300;
      for(int j = 0; j < N; j++)
        {
         double s = 0.0;
         for(int b = 0; b < S; b++)
            if(((mask >> b) & 1) == 1)
               s += m[b * N + j];
         if(s > best_is)
           {
            best_is = s;
            best = j;
           }
        }

      //--- its out-of-sample total, and its rank there (1 = best)
      double oos_best = 0.0;
      for(int b = 0; b < S; b++)
         if(((mask >> b) & 1) == 0)
            oos_best += m[b * N + best];

      int rank = 1;
      for(int j = 0; j < N; j++)
        {
         if(j == best)
            continue;
         double s = 0.0;
         for(int b = 0; b < S; b++)
            if(((mask >> b) & 1) == 0)
               s += m[b * N + j];
         if(s > oos_best)
            rank++;
        }

      //--- lower half out-of-sample = overfit (logit <= 0)
      if((double)rank >= (N + 1) / 2.0)
         overfit++;
     }

   if(combos == 0)
      return 1.0;
   return (double)overfit / (double)combos;
  }

#endif // AUTOTRADER_VALIDATION_MQH
//+------------------------------------------------------------------+
