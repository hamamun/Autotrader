//+------------------------------------------------------------------+
//| SymbolIntelligence.mqh                                            |
//| Autotrader Phase 2 - Symbol Intelligence.                         |
//|                                                                   |
//| In plain words: the EA studies whatever symbol it is attached     |
//| to (how its price is written, how much it normally wiggles, its   |
//| usual spread, how jumpy it is right now) and automatically sets   |
//| its own hidden "dials" to fit that symbol - breathing room for    |
//| stops, reasonable target distance, how much proof a signal will   |
//| need, and so on. No user settings: one EA, any symbol.            |
//|                                                                   |
//| It does NOT decide BUY/SELL (that is Phase 3). It only makes      |
//| sure Phase 3+ will use the correct ruler for this symbol.         |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_SYMBOL_INTELLIGENCE_MQH
#define AUTOTRADER_SYMBOL_INTELLIGENCE_MQH

//--- symbol families the EA can recognise
enum ENUM_AT_SYMBOL_CLASS
  {
   AT_CLASS_FOREX = 0,
   AT_CLASS_METAL,
   AT_CLASS_CRYPTO,
   AT_CLASS_INDEX,
   AT_CLASS_ENERGY,
   AT_CLASS_OTHER
  };

//+------------------------------------------------------------------+
//| The symbol's private "profile card" (rebuilt on every Refresh)    |
//+------------------------------------------------------------------+
struct SATSymbolProfile
  {
   bool                 ready;              // enough history was available
   string               symbol;
   ENUM_AT_SYMBOL_CLASS symbol_class;
   string               class_label;        // "Forex", "Metal", ...
   //--- how the price is written / how the broker quotes it
   int                  digits;
   double               point;
   double               tick_size;
   double               tick_value;
   double               contract_size;
   double               volume_min;
   double               volume_max;
   double               volume_step;
   long                 spread_now_pts;
   double               spread_typical_pts; // average of sampled spreads
   //--- how the symbol normally behaves (price units, chart timeframe)
   double               atr_price;          // current typical wiggle size
   double               atr_baseline;       // longer-run typical wiggle
   double               atr_ratio;          // atr_price / atr_baseline
   double               atr_pct;            // atr_price as % of price
   double               swing_price;        // average bar high-low size
   int                  bars_used;
   datetime             updated;
   //--- the hidden dials, auto-derived from the profile above.
   //--- (Consumed by the Phase 3 direction engine and Phase 4 trades;
   //---  in Phase 2 they also scale the preview Entry/SL/TP numbers.)
   double               sl_mult;            // stop distance  = sl_mult x ATR
   double               tp_mult;            // target distance = tp_mult x ATR
   int                  confidence_threshold; // proof needed before speaking
   double               spread_limit_pts;   // "spread too expensive" line
   double               risk_pct;           // baseline risk dial (Phase 4+)
  };

//+------------------------------------------------------------------+
//| helpers                                                           |
//+------------------------------------------------------------------+
string AT_Upper(const string s)
  {
   string u = s;
   StringToUpper(u);
   return u;
  }

bool AT_Has(const string haystack, const string needle)
  {
   return (StringFind(haystack, needle) >= 0);
  }

bool AT_IsMajorCurrency(const string code)
  {
   return (code == "USD" || code == "EUR" || code == "GBP" ||
           code == "JPY" || code == "AUD" || code == "NZD" ||
           code == "CAD" || code == "CHF");
  }

ENUM_AT_SYMBOL_CLASS AT_DetectClass(const string symbol)
  {
   string s = AT_Upper(symbol);

   //--- precious metals first (XAUUSD also contains "USD")
   if(AT_Has(s, "XAU") || AT_Has(s, "GOLD") || AT_Has(s, "XAG") ||
      AT_Has(s, "SILVER") || AT_Has(s, "XPT") || AT_Has(s, "XPD"))
      return AT_CLASS_METAL;

   //--- crypto (ETHUSD / BTCUSD also contain "USD")
   if(AT_Has(s, "BTC") || AT_Has(s, "ETH") || AT_Has(s, "XRP") ||
      AT_Has(s, "LTC") || AT_Has(s, "DOGE") || AT_Has(s, "SOL") ||
      AT_Has(s, "ADA") || AT_Has(s, "BNB") || AT_Has(s, "DOT") ||
      AT_Has(s, "LINK") || AT_Has(s, "TRX") || AT_Has(s, "MATIC") ||
      AT_Has(s, "AVAX"))
      return AT_CLASS_CRYPTO;

   //--- energy
   if(AT_Has(s, "WTI") || AT_Has(s, "BRENT") || AT_Has(s, "XBR") ||
      AT_Has(s, "XTI") || AT_Has(s, "OIL") || AT_Has(s, "NATGAS") ||
      AT_Has(s, "XNG"))
      return AT_CLASS_ENERGY;

   //--- indices
   if(AT_Has(s, "US30") || AT_Has(s, "NAS") || AT_Has(s, "SPX") ||
      AT_Has(s, "US500") || AT_Has(s, "USTEC") || AT_Has(s, "DJI") ||
      AT_Has(s, "NDX") || AT_Has(s, "GER") || AT_Has(s, "DE40") ||
      AT_Has(s, "UK100") || AT_Has(s, "JP225") || AT_Has(s, "JPN") ||
      AT_Has(s, "FRA") || AT_Has(s, "EU50") || AT_Has(s, "AUS200") ||
      AT_Has(s, "HK50") || AT_Has(s, "CHN"))
      return AT_CLASS_INDEX;

   //--- forex: two known currency codes back to back (e.g. EURUSDm)
   if(StringLen(s) >= 6 &&
      AT_IsMajorCurrency(StringSubstr(s, 0, 3)) &&
      AT_IsMajorCurrency(StringSubstr(s, 3, 3)))
      return AT_CLASS_FOREX;

   //--- broker says it is a forex-style contract
   ENUM_SYMBOL_CALC_MODE mode =
      (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_CALC_MODE);
   if(mode == SYMBOL_CALC_MODE_FOREX || mode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)
      return AT_CLASS_FOREX;

   return AT_CLASS_OTHER;
  }

string AT_ClassLabel(const ENUM_AT_SYMBOL_CLASS c)
  {
   switch(c)
     {
      case AT_CLASS_FOREX:  return "Forex";
      case AT_CLASS_METAL:  return "Metal";
      case AT_CLASS_CRYPTO: return "Crypto";
      case AT_CLASS_INDEX:  return "Index";
      case AT_CLASS_ENERGY: return "Energy";
      default:              return "Other";
     }
  }

//+------------------------------------------------------------------+
//| Symbol Intelligence engine                                        |
//+------------------------------------------------------------------+
class CSymbolIntelligence
  {
private:
   SATSymbolProfile  m_profile;
   double            m_spread_sum;
   long              m_spread_samples;

   void              DeriveDials(void);

public:
                     CSymbolIntelligence(void);

   //--- study the symbol now (history + live quote facts)
   bool              Refresh(const string symbol, const ENUM_TIMEFRAMES tf);

   bool              Ready(void)              const { return m_profile.ready; }
   string            ClassLabel(void)         const { return m_profile.class_label; }
   ENUM_AT_SYMBOL_CLASS SymbolClass(void)     const { return m_profile.symbol_class; }
   double            AtrPrice(void)           const { return m_profile.atr_price; }
   double            AtrRatio(void)           const { return m_profile.atr_ratio; }
   double            SwingPrice(void)         const { return m_profile.swing_price; }
   double            SpreadTypicalPts(void)   const { return m_profile.spread_typical_pts; }
   double            SlMult(void)             const { return m_profile.sl_mult; }
   double            TpMult(void)             const { return m_profile.tp_mult; }
   int               ConfidenceThreshold(void) const { return m_profile.confidence_threshold; }
   //--- note: no whole-struct getter - callers use the typed getters
   //--- above (keeps this header to plain, portable MQL5 constructs)
  };

//+------------------------------------------------------------------+
CSymbolIntelligence::CSymbolIntelligence(void)
  {
   //--- explicit init (no ZeroMemory on a struct containing strings)
   m_profile.ready = false;
   m_profile.symbol = "";
   m_profile.symbol_class = AT_CLASS_OTHER;
   m_profile.class_label = "Other";
   m_profile.digits = 0;
   m_profile.point = 0.0;
   m_profile.tick_size = 0.0;
   m_profile.tick_value = 0.0;
   m_profile.contract_size = 0.0;
   m_profile.volume_min = 0.0;
   m_profile.volume_max = 0.0;
   m_profile.volume_step = 0.0;
   m_profile.spread_now_pts = 0;
   m_profile.spread_typical_pts = 0.0;
   m_profile.atr_price = 0.0;
   m_profile.atr_baseline = 0.0;
   m_profile.atr_ratio = 0.0;
   m_profile.atr_pct = 0.0;
   m_profile.swing_price = 0.0;
   m_profile.bars_used = 0;
   m_profile.updated = 0;
   m_profile.sl_mult = 0.0;
   m_profile.tp_mult = 0.0;
   m_profile.confidence_threshold = 0;
   m_profile.spread_limit_pts = 0.0;
   m_profile.risk_pct = 0.0;
   m_spread_sum = 0.0;
   m_spread_samples = 0;
  }

//+------------------------------------------------------------------+
//| Set the hidden dials from the measured profile.                   |
//| Plain idea: jumpier symbols get more breathing room, further      |
//| targets and must show stronger proof before the EA speaks; calm   |
//| symbols get the opposite. Everything is relative to what is       |
//| NORMAL for this symbol, never one fixed ruler for all symbols.    |
//+------------------------------------------------------------------+
void CSymbolIntelligence::DeriveDials(void)
  {
   //--- calm baseline per family
   double sl = 1.6, tp = 3.5;
   int    conf = 85;
   switch(m_profile.symbol_class)
     {
      case AT_CLASS_FOREX:  sl = 1.6; tp = 3.5; conf = 85; break;
      case AT_CLASS_METAL:  sl = 1.8; tp = 3.8; conf = 87; break;
      case AT_CLASS_CRYPTO: sl = 2.0; tp = 4.2; conf = 90; break;
      case AT_CLASS_INDEX:  sl = 1.8; tp = 3.8; conf = 87; break;
      case AT_CLASS_ENERGY: sl = 1.9; tp = 4.0; conf = 88; break;
      default:              sl = 1.8; tp = 3.8; conf = 88; break;
     }

   //--- adjust to how jumpy the symbol is RIGHT NOW vs its own normal
   double r = m_profile.atr_ratio;
   if(r >= 1.5)       { sl += 0.3; conf += 3; }   // wild now: room + proof
   else if(r >= 1.25) { sl += 0.15; conf += 2; }
   else if(r <= 0.7)  { sl -= 0.2; conf += 2; }   // sleepy: moves must prove themselves
   if(m_profile.atr_pct >= 1.0)                   // very large daily wiggle
      conf += 2;

   m_profile.sl_mult = MathMax(1.2, MathMin(2.6, sl));
   m_profile.tp_mult = MathMax(m_profile.sl_mult * 1.8, MathMin(5.0, tp));
   m_profile.confidence_threshold = (int)MathMax(80, MathMin(95, conf));
   m_profile.spread_limit_pts = (m_profile.spread_typical_pts > 0.0)
                                ? m_profile.spread_typical_pts * 2.5
                                : (double)m_profile.spread_now_pts * 2.5;
   m_profile.risk_pct = 1.0;   // baseline dial; real sizing arrives Phase 4
  }

//+------------------------------------------------------------------+
//| Study the symbol: broker facts + recent behaviour on this TF.     |
//+------------------------------------------------------------------+
bool CSymbolIntelligence::Refresh(const string symbol, const ENUM_TIMEFRAMES tf)
  {
   m_profile.symbol       = symbol;
   m_profile.symbol_class = AT_DetectClass(symbol);
   m_profile.class_label  = AT_ClassLabel(m_profile.symbol_class);
   m_profile.digits       = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   m_profile.point        = SymbolInfoDouble(symbol, SYMBOL_POINT);
   m_profile.tick_size    = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   m_profile.tick_value   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   m_profile.contract_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   m_profile.volume_min   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   m_profile.volume_max   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   m_profile.volume_step  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   //--- typical spread: keep a running average of live samples
   m_profile.spread_now_pts = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(m_profile.spread_now_pts > 0)
     {
      m_spread_sum += (double)m_profile.spread_now_pts;
      m_spread_samples++;
      if(m_spread_samples > 720)   // keep the average recent, not ancient
        {
         m_spread_sum = (double)m_profile.spread_now_pts;
         m_spread_samples = 1;
        }
      m_profile.spread_typical_pts = m_spread_sum / (double)m_spread_samples;
     }

   //--- behaviour: closed bars on the chart timeframe
   MqlRates rates[];
   int n = CopyRates(symbol, tf, 1, 140, rates);
   m_profile.bars_used = MathMax(n, 0);
   if(n < 80)   // not enough history yet - panel will say "calibrating"
     {
      m_profile.ready = false;
      DeriveDials();
      return false;
     }
   ArraySetAsSeries(rates, true);   // rates[0] = newest closed bar

   //--- true ranges: current (last 14) vs its own longer-run normal
   double tr_now = 0.0, tr_base = 0.0, swing = 0.0;
   int tr_base_n = 0;
   for(int i = 0; i < n; i++)
     {
      double pc = (i + 1 < n) ? rates[i + 1].close : rates[i].close;
      double tr = MathMax(rates[i].high - rates[i].low,
                          MathMax(MathAbs(rates[i].high - pc),
                                  MathAbs(rates[i].low - pc)));
      if(i < 14)
         tr_now += tr;
      else if(i < 114)
        {
         tr_base += tr;
         tr_base_n++;
        }
      if(i < 50)
         swing += (rates[i].high - rates[i].low);
     }
   m_profile.atr_price    = tr_now / 14.0;
   m_profile.atr_baseline = (tr_base_n > 0) ? tr_base / tr_base_n : m_profile.atr_price;
   m_profile.swing_price  = swing / 50.0;
   m_profile.atr_ratio    = (m_profile.atr_baseline > 0.0)
                            ? m_profile.atr_price / m_profile.atr_baseline : 1.0;
   double price = rates[0].close;
   m_profile.atr_pct = (price > 0.0) ? m_profile.atr_price / price * 100.0 : 0.0;

   m_profile.updated = TimeCurrent();
   m_profile.ready = (m_profile.atr_price > 0.0);
   DeriveDials();
   return m_profile.ready;
  }

#endif // AUTOTRADER_SYMBOL_INTELLIGENCE_MQH
