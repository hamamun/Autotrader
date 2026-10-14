//+------------------------------------------------------------------+
//| VolumeFlow.mqh                                                    |
//| Autotrader Phase 3 - volume-flow tools.                           |
//|                                                                   |
//| MT5 gives tick volume, which is enough for confluence:            |
//|   * CVD-style delta - was the trading pressure buying or selling? |
//|   * session volume profile - where the real business was done     |
//|     (POC / VAH / VAL): price respects those levels.               |
//|   * session VWAP + rolling VWAP - who is in profit right now.     |
//|   * volume ratio - is the move backed by participation or not.    |
//|                                                                   |
//| Closed bars only.                                                 |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_VOLUME_FLOW_MQH
#define AUTOTRADER_VOLUME_FLOW_MQH

#define ATVF_BINS 24

struct SATVolumeInfo
  {
   bool   ready;
   double cvd;               // cumulative delta over the session
   double cvd_slope;         // last 5 bars, -1..+1 (buying vs selling pressure)
   int    cvd_dir;           // +1 buyers, -1 sellers, 0 balanced
   double cvd_strength;      // 0..1
   double vol_ratio;         // recent participation vs its own average
   double poc, vah, val;     // session volume profile
   bool   profile_ready;
   double vwap_session;
   double vwap_roll;         // rolling 100-bar VWAP (anchor proxy)
   int    price_vs_vwap;     // +1 above session VWAP, -1 below
   double poc_dist_atr;      // how far price is from POC, in ATRs
   int    session_bars;
  };

class CVolumeFlow
  {
public:
   bool              Analyse(const MqlRates &r[], const int window,
                             const double atr, SATVolumeInfo &out);
   void              Reset(SATVolumeInfo &out);
  };

//+------------------------------------------------------------------+
void CVolumeFlow::Reset(SATVolumeInfo &out)
  {
   out.ready = false;
   out.cvd = 0.0;
   out.cvd_slope = 0.0;
   out.cvd_dir = 0;
   out.cvd_strength = 0.0;
   out.vol_ratio = 1.0;
   out.poc = 0.0; out.vah = 0.0; out.val = 0.0;
   out.profile_ready = false;
   out.vwap_session = 0.0;
   out.vwap_roll = 0.0;
   out.price_vs_vwap = 0;
   out.poc_dist_atr = 0.0;
   out.session_bars = 0;
  }

//+------------------------------------------------------------------+
//| signed volume of one bar (tick volume split by where it closed)   |
//+------------------------------------------------------------------+
double ATVF_Delta(const MqlRates &r[], const int k)
  {
   double v = (double)r[k].tick_volume;
   if(v <= 0.0)
      return 0.0;
   double rng = r[k].high - r[k].low;
   if(rng <= 0.0)
      return (r[k].close >= r[k].open) ? v : -v;
   double d = v * (r[k].close - r[k].open) / rng;
   if(d >  v) d =  v;
   if(d < -v) d = -v;
   return d;
  }

//+------------------------------------------------------------------+
bool CVolumeFlow::Analyse(const MqlRates &r[], const int window,
                          const double atr, SATVolumeInfo &out)
  {
   Reset(out);
   int n = ArraySize(r);
   if(n < 60 || atr <= 0.0)
      return false;
   int w = window;
   if(w > n) w = n;
   if(w < 40)
      return false;

   //=== 1. how many bars belong to the current trading day ===========
   MqlDateTime dt0;
   TimeToStruct(r[0].time, dt0);
   int session = 1;
   for(int k = 1; k < w; k++)
     {
      MqlDateTime dtk;
      TimeToStruct(r[k].time, dtk);
      if(dtk.day != dt0.day || dtk.mon != dt0.mon || dtk.year != dt0.year)
         break;
      session++;
     }
   out.session_bars = session;

   //=== 2. CVD-style delta ===========================================
   double cvd = 0.0;
   for(int k = 0; k < session; k++)
      cvd += ATVF_Delta(r, k);
   out.cvd = cvd;

   double d5 = 0.0, v5 = 0.0;
   for(int k = 0; k < 5 && k < n; k++)
     {
      d5 += ATVF_Delta(r, k);
      v5 += (double)r[k].tick_volume;
     }
   out.cvd_slope = (v5 > 0.0) ? d5 / v5 : 0.0;
   if(out.cvd_slope >  0.10) out.cvd_dir = 1;
   else if(out.cvd_slope < -0.10) out.cvd_dir = -1;
   else out.cvd_dir = 0;
   out.cvd_strength = MathMin(1.0, MathAbs(out.cvd_slope) / 0.50);

   //=== 3. participation vs its own average ==========================
   double v_recent = 0.0, v_base = 0.0;
   int    n_recent = 0, n_base = 0;
   for(int k = 0; k < w; k++)
     {
      double v = (double)r[k].tick_volume;
      if(k < 10)  { v_recent += v; n_recent++; }
      else if(k < 110) { v_base += v; n_base++; }
     }
   if(n_recent > 0 && n_base > 0 && v_base > 0.0)
      out.vol_ratio = (v_recent / (double)n_recent) / (v_base / (double)n_base);
   else
      out.vol_ratio = 1.0;

   //=== 4. session VWAP + rolling VWAP ===============================
   double pv = 0.0, vv = 0.0;
   for(int k = 0; k < session; k++)
     {
      double tp = (r[k].high + r[k].low + r[k].close) / 3.0;
      double vol = (double)r[k].tick_volume;
      pv += tp * vol;
      vv += vol;
     }
   if(vv > 0.0)
      out.vwap_session = pv / vv;

   int roll = MathMin(100, n);
   double pv2 = 0.0, vv2 = 0.0;
   for(int k = 0; k < roll; k++)
     {
      double tp2 = (r[k].high + r[k].low + r[k].close) / 3.0;
      double vol2 = (double)r[k].tick_volume;
      pv2 += tp2 * vol2;
      vv2 += vol2;
     }
   if(vv2 > 0.0)
      out.vwap_roll = pv2 / vv2;

   double close0 = r[0].close;
   if(out.vwap_session > 0.0)
      out.price_vs_vwap = (close0 >= out.vwap_session) ? 1 : -1;

   //=== 5. session volume profile (POC / value area) =================
   double hi = r[0].high, lo = r[0].low;
   for(int k = 1; k < session; k++)
     {
      if(r[k].high > hi) hi = r[k].high;
      if(r[k].low  < lo) lo = r[k].low;
     }
   if(hi > lo && session >= 6)
     {
      double bin[ATVF_BINS];
      double step = (hi - lo) / (double)ATVF_BINS;
      for(int b = 0; b < ATVF_BINS; b++) bin[b] = 0.0;
      double total = 0.0;
      for(int k = 0; k < session; k++)
        {
         double tp3 = (r[k].high + r[k].low + r[k].close) / 3.0;
         int b = (int)((tp3 - lo) / step);
         if(b < 0) b = 0;
         if(b >= ATVF_BINS) b = ATVF_BINS - 1;
         double vol3 = (double)r[k].tick_volume;
         bin[b] += vol3;
         total  += vol3;
        }
      int poc_bin = 0;
      for(int b = 1; b < ATVF_BINS; b++)
         if(bin[b] > bin[poc_bin]) poc_bin = b;
      out.poc = lo + ((double)poc_bin + 0.5) * step;

      //--- value area: grow out of the POC until 70% of the volume
      double acc = bin[poc_bin];
      int up = poc_bin + 1, dn = poc_bin - 1;
      while((up < ATVF_BINS || dn >= 0) && total > 0.0 && acc < total * 0.70)
        {
         double bu = (up < ATVF_BINS) ? bin[up] : -1.0;
         double bd = (dn >= 0) ? bin[dn] : -1.0;
         if(bu >= bd && up < ATVF_BINS) { acc += bu; up++; }
         else if(dn >= 0)               { acc += bd; dn++; }
         else                            break;
        }
      out.vah = lo + (double)up * step;
      out.val = lo + (double)(dn + 1) * step;
      if(out.vah > hi) out.vah = hi;
      if(out.val < lo) out.val = lo;
      out.profile_ready = (total > 0.0);
      out.poc_dist_atr  = MathAbs(close0 - out.poc) / atr;
     }

   out.ready = true;
   return true;
  }
//+------------------------------------------------------------------+
#endif // AUTOTRADER_VOLUME_FLOW_MQH
