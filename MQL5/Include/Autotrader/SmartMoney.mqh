//+------------------------------------------------------------------+
//| SmartMoney.mqh                                                    |
//| Autotrader Phase 3 - Smart-Money Concepts engine.                 |
//|                                                                   |
//| In plain words: it finds the places where the big money leaves    |
//| footprints, and tells the direction engine HOW GOOD the ground    |
//| under the current price is:                                       |
//|   * market structure - higher highs/higher lows or the opposite   |
//|   * BOS  - break of structure (the trend continuing)              |
//|   * CHoCH - change of character (the trend possibly turning)      |
//|   * order blocks - the last opposite candle before a strong push  |
//|   * fair value gaps - 3-candle imbalances price likes to revisit   |
//|   * liquidity sweeps - a wick through an old high/low that closed |
//|     back inside (stops taken, move often runs the other way)      |
//|                                                                   |
//| Closed bars only, so nothing repaints.                            |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_SMART_MONEY_MQH
#define AUTOTRADER_SMART_MONEY_MQH

#define ATSM_MAX_SWINGS 40

struct SATSmcInfo
  {
   bool   ready;
   int    structure_dir;      // +1 higher highs AND higher lows, -1 opposite
   int    bos_dir;            // most recent break of structure
   int    bars_since_bos;
   int    choch_dir;          // most recent break AGAINST the structure
   int    bars_since_choch;
   bool   sweep_above;        // liquidity above an old high was taken out
   bool   sweep_below;        // liquidity below an old low was taken out
   int    bars_since_sweep;
   int    sweep_bias;         // +1 = swept BELOW (bullish fuel), -1 = above
   //--- demand / supply zones (0 = none found)
   double bull_ob_hi, bull_ob_lo;   int bull_ob_age;   bool bull_ob_valid;
   double bear_ob_hi, bear_ob_lo;   int bear_ob_age;   bool bear_ob_valid;
   double bull_fvg_hi, bull_fvg_lo; int bull_fvg_age;  bool bull_fvg_valid;
   double bear_fvg_hi, bear_fvg_lo; int bear_fvg_age;  bool bear_fvg_valid;
   //--- confirmed swings
   double swing_hi, swing_lo;
   double prev_swing_hi, prev_swing_lo;
   int    swing_hi_bar, swing_lo_bar;
   //--- the zone each side would actually trade from, and how far away
   double zone_buy, zone_buy_dist_atr;    // dist > 0 = zone is below price
   double zone_sell, zone_sell_dist_atr;  // dist > 0 = zone is above price
   int    zone_buy_kind, zone_sell_kind;  // 0 none, 1 OB, 2 FVG, 3 sweep level
  };

class CSmartMoney
  {
public:
   //--- analyse the closed bars (r[0] = newest closed bar)
   bool              Analyse(const MqlRates &r[], const int window,
                             const double atr, SATSmcInfo &out);
   void              Reset(SATSmcInfo &out);
  };

//+------------------------------------------------------------------+
void CSmartMoney::Reset(SATSmcInfo &out)
  {
   out.ready = false;
   out.structure_dir = 0;
   out.bos_dir = 0;
   out.bars_since_bos = 999;
   out.choch_dir = 0;
   out.bars_since_choch = 999;
   out.sweep_above = false;
   out.sweep_below = false;
   out.bars_since_sweep = 999;
   out.sweep_bias = 0;
   out.bull_ob_hi = 0.0; out.bull_ob_lo = 0.0; out.bull_ob_age = 999; out.bull_ob_valid = false;
   out.bear_ob_hi = 0.0; out.bear_ob_lo = 0.0; out.bear_ob_age = 999; out.bear_ob_valid = false;
   out.bull_fvg_hi = 0.0; out.bull_fvg_lo = 0.0; out.bull_fvg_age = 999; out.bull_fvg_valid = false;
   out.bear_fvg_hi = 0.0; out.bear_fvg_lo = 0.0; out.bear_fvg_age = 999; out.bear_fvg_valid = false;
   out.swing_hi = 0.0; out.swing_lo = 0.0;
   out.prev_swing_hi = 0.0; out.prev_swing_lo = 0.0;
   out.swing_hi_bar = 0; out.swing_lo_bar = 0;
   out.zone_buy = 0.0; out.zone_buy_dist_atr = 0.0;
   out.zone_sell = 0.0; out.zone_sell_dist_atr = 0.0;
   out.zone_buy_kind = 0; out.zone_sell_kind = 0;
  }

//+------------------------------------------------------------------+
bool CSmartMoney::Analyse(const MqlRates &r[], const int window,
                          const double atr, SATSmcInfo &out)
  {
   Reset(out);
   int n = ArraySize(r);
   if(n < 60 || atr <= 0.0)
      return false;
   int w = window;
   if(w > n - 6) w = n - 6;
   if(w < 40)
      return false;

   //=== 1. confirmed swing points (2 bars clear on each side) ========
   int    sh_bar[ATSM_MAX_SWINGS];
   double sh_px[ATSM_MAX_SWINGS];
   int    sl_bar[ATSM_MAX_SWINGS];
   double sl_px[ATSM_MAX_SWINGS];
   int nsh = 0, nsl = 0;

   for(int k = 2; k <= w - 2; k++)
     {
      if(k + 2 >= n) break;
      bool is_hi = (r[k].high > r[k - 1].high && r[k].high > r[k - 2].high &&
                    r[k].high > r[k + 1].high && r[k].high > r[k + 2].high);
      bool is_lo = (r[k].low  < r[k - 1].low  && r[k].low  < r[k - 2].low  &&
                    r[k].low  < r[k + 1].low  && r[k].low  < r[k + 2].low);
      if(is_hi && nsh < ATSM_MAX_SWINGS)
        { sh_bar[nsh] = k; sh_px[nsh] = r[k].high; nsh++; }
      if(is_lo && nsl < ATSM_MAX_SWINGS)
        { sl_bar[nsl] = k; sl_px[nsl] = r[k].low;  nsl++; }
     }
   if(nsh < 2 || nsl < 2)
      return false;

   //--- lists are newest-first, so [0] is the most recent confirmed swing
   out.swing_hi = sh_px[0]; out.swing_hi_bar = sh_bar[0];
   out.swing_lo = sl_px[0]; out.swing_lo_bar = sl_bar[0];
   out.prev_swing_hi = sh_px[1];
   out.prev_swing_lo = sl_px[1];

   //=== 2. market structure ==========================================
   if(sh_px[0] > sh_px[1] && sl_px[0] > sl_px[1])      out.structure_dir = 1;
   else if(sh_px[0] < sh_px[1] && sl_px[0] < sl_px[1]) out.structure_dir = -1;
   else                                                out.structure_dir = 0;

   //=== 3. BOS / CHoCH - who broke what, and how recently =============
   int up_break_age = 999, dn_break_age = 999;
   for(int k = 0; k < w && k < n - 1; k++)
     {
      //--- a break must use a swing that was ALREADY confirmed before it
      if(up_break_age > 900 && sh_bar[0] > k)
        { if(r[k].close > sh_px[0]) up_break_age = k; }
      if(dn_break_age > 900 && sl_bar[0] > k)
        { if(r[k].close < sl_px[0]) dn_break_age = k; }
      //--- fall back to the previous swing once the newest is too old
      if(up_break_age > 900 && nsh > 1 && sh_bar[1] > k)
        { if(r[k].close > sh_px[1]) up_break_age = k; }
      if(dn_break_age > 900 && nsl > 1 && sl_bar[1] > k)
        { if(r[k].close < sl_px[1]) dn_break_age = k; }
     }

   if(up_break_age <= dn_break_age && up_break_age < 900)
     { out.bos_dir = 1; out.bars_since_bos = up_break_age; }
   else if(dn_break_age < 900)
     { out.bos_dir = -1; out.bars_since_bos = dn_break_age; }

   //--- CHoCH = the older break, when it runs against the structure
   if(out.bos_dir == 1 && dn_break_age < 900 && dn_break_age <= 40)
     { out.choch_dir = -1; out.bars_since_choch = dn_break_age; }
   else if(out.bos_dir == -1 && up_break_age < 900 && up_break_age <= 40)
     { out.choch_dir = 1; out.bars_since_choch = up_break_age; }

   //=== 4. liquidity sweeps in the last 12 bars ======================
   for(int k = 0; k < 12 && k < w && k < n - 3; k++)
     {
      double ref_hi = (sh_bar[0] > k) ? sh_px[0] : ((nsh > 1) ? sh_px[1] : 0.0);
      double ref_lo = (sl_bar[0] > k) ? sl_px[0] : ((nsl > 1) ? sl_px[1] : 0.0);
      if(ref_hi > 0.0 && r[k].high > ref_hi && r[k].close < ref_hi)
        {
         out.sweep_above = true;
         out.bars_since_sweep = k;
         out.sweep_bias = -1;            // stops above taken -> bearish fuel
        }
      if(ref_lo > 0.0 && r[k].low < ref_lo && r[k].close > ref_lo)
        {
         out.sweep_below = true;
         if(!out.sweep_above || k < out.bars_since_sweep)
           {
            out.bars_since_sweep = k;
            out.sweep_bias = 1;          // stops below taken -> bullish fuel
           }
        }
     }

   //=== 5. order blocks: last opposite candle before the displacement =
   int ob_look = (out.bars_since_bos < 900) ? out.bars_since_bos : 0;
   if(ob_look > 0 && ob_look < w)
     {
      int dir = out.bos_dir;
      for(int k = ob_look + 1; k <= ob_look + 14 && k < n - 1; k++)
        {
         bool bearish = (r[k].close < r[k].open);
         bool bullish = (r[k].close > r[k].open);
         if(dir == 1 && bearish)
           {
            out.bull_ob_hi = r[k].high;
            out.bull_ob_lo = r[k].low;
            out.bull_ob_age = k;
            //--- still valid while price has not traded fully through it
            bool broken = false;
            for(int m = 0; m < k; m++)
               if(r[m].low < out.bull_ob_lo) { broken = true; break; }
            out.bull_ob_valid = !broken;
            break;
           }
         if(dir == -1 && bullish)
           {
            out.bear_ob_hi = r[k].high;
            out.bear_ob_lo = r[k].low;
            out.bear_ob_age = k;
            bool broken2 = false;
            for(int m = 0; m < k; m++)
               if(r[m].high > out.bear_ob_hi) { broken2 = true; break; }
            out.bear_ob_valid = !broken2;
            break;
           }
        }
     }

   //=== 6. fair value gaps (3-candle imbalance), freshest first =======
   for(int k = 1; k < w - 2 && k < n - 3; k++)
     {
      if(!out.bull_fvg_valid && r[k].low > r[k + 2].high)
        {
         out.bull_fvg_lo  = r[k + 2].high;
         out.bull_fvg_hi  = r[k].low;
         out.bull_fvg_age = k;
         bool filled = false;
         for(int m = 0; m < k; m++)
            if(r[m].low <= out.bull_fvg_lo) { filled = true; break; }
         out.bull_fvg_valid = !filled;
        }
      if(!out.bear_fvg_valid && r[k].high < r[k + 2].low)
        {
         out.bear_fvg_hi  = r[k + 2].low;
         out.bear_fvg_lo  = r[k].high;
         out.bear_fvg_age = k;
         bool filled2 = false;
         for(int m = 0; m < k; m++)
            if(r[m].high >= out.bear_fvg_hi) { filled2 = true; break; }
         out.bear_fvg_valid = !filled2;
        }
      if(out.bull_fvg_valid && out.bear_fvg_valid)
         break;
     }

   //=== 7. the zone each side would trade from =======================
   double close0 = r[0].close;

   //--- BUY side: demand BELOW the price (OB preferred, then FVG)
   double best_buy = 0.0; int best_buy_kind = 0; double best_buy_score = -1.0;
   if(out.bull_ob_valid && out.bull_ob_hi > 0.0 && out.bull_ob_hi <= close0 + atr)
     {
      double s = 2.0 - (double)out.bull_ob_age / 40.0;
      if(s > best_buy_score) { best_buy_score = s; best_buy = out.bull_ob_hi; best_buy_kind = 1; }
     }
   if(out.bull_fvg_valid && out.bull_fvg_hi > 0.0 && out.bull_fvg_hi <= close0 + atr)
     {
      double s = 1.6 - (double)out.bull_fvg_age / 40.0;
      if(s > best_buy_score) { best_buy_score = s; best_buy = out.bull_fvg_hi; best_buy_kind = 2; }
     }
   if(out.sweep_below && out.swing_lo > 0.0 && best_buy <= 0.0)
     { best_buy = out.swing_lo; best_buy_kind = 3; best_buy_score = 1.0; }

   if(best_buy > 0.0)
     {
      out.zone_buy = best_buy;
      out.zone_buy_kind = best_buy_kind;
      out.zone_buy_dist_atr = (close0 - best_buy) / atr;
      if(close0 < best_buy)   // price already inside the zone
         out.zone_buy_dist_atr = 0.0;
     }

   //--- SELL side: supply ABOVE the price
   double best_sell = 0.0; int best_sell_kind = 0; double best_sell_score = -1.0;
   if(out.bear_ob_valid && out.bear_ob_lo > 0.0 && out.bear_ob_lo >= close0 - atr)
     {
      double s2 = 2.0 - (double)out.bear_ob_age / 40.0;
      if(s2 > best_sell_score) { best_sell_score = s2; best_sell = out.bear_ob_lo; best_sell_kind = 1; }
     }
   if(out.bear_fvg_valid && out.bear_fvg_lo > 0.0 && out.bear_fvg_lo >= close0 - atr)
     {
      double s3 = 1.6 - (double)out.bear_fvg_age / 40.0;
      if(s3 > best_sell_score) { best_sell_score = s3; best_sell = out.bear_fvg_lo; best_sell_kind = 2; }
     }
   if(out.sweep_above && out.swing_hi > 0.0 && best_sell <= 0.0)
     { best_sell = out.swing_hi; best_sell_kind = 3; best_sell_score = 1.0; }

   if(best_sell > 0.0)
     {
      out.zone_sell = best_sell;
      out.zone_sell_kind = best_sell_kind;
      out.zone_sell_dist_atr = (best_sell - close0) / atr;
      if(close0 > best_sell)   // price already inside the zone
         out.zone_sell_dist_atr = 0.0;
     }

   out.ready = true;
   return true;
  }
//+------------------------------------------------------------------+
#endif // AUTOTRADER_SMART_MONEY_MQH
