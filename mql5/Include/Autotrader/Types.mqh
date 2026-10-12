//+------------------------------------------------------------------+
//|                                                    Types.mqh     |
//|                        Autotrader - shared types & settings      |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_TYPES_MQH
#define AUTOTRADER_TYPES_MQH

#define AT_VERSION "0.1.0"
#define AT_MAX_TF  3                 // M5, M15, M30

//--- turn ONNX inference on/off (needs MT5 build 3620 or newer)
#ifndef AUTOTRADER_USE_ONNX
   #define AUTOTRADER_USE_ONNX 1
#endif

//--- feature vector size (MUST match docs/FEATURE_CONTRACT.md)
#define AT_FEATURE_COUNT 24

//--- direction
enum ENUM_AT_DIR
  {
   AT_HOLD =  0,
   AT_BUY  =  1,
   AT_SELL = -1
  };

//--- what each timeframe is used for
enum ENUM_AT_ROLE
  {
   AT_ROLE_TRIGGER = 0,   // M5  -> scalping entry trigger
   AT_ROLE_SETUP   = 1,   // M15 -> short term trade
   AT_ROLE_BIAS    = 2    // M30 -> intraday direction
  };

enum ENUM_AT_MODE
  {
   AT_MODE_SIGNAL_ONLY = 0,
   AT_MODE_AUTO        = 1
  };

//--- user settings (filled from the EA inputs)
struct SATSettings
  {
   //--- indicator lengths
   int      ema_fast;
   int      ema_slow;
   int      ema_bias;
   int      atr_period;
   int      adx_period;
   int      rsi_period;
   int      macd_fast;
   int      macd_slow;
   int      macd_signal;
   int      swing_lookback;

   //--- gates
   double   adx_min;            // trend strength filter
   double   rsi_overbought;
   double   rsi_oversold;
   double   max_spread_points;  // 0 = no limit
   double   min_atr_points;     // 0 = no limit
   double   max_atr_points;     // 0 = no limit
   double   max_ext_atr;        // max distance price-EMA50 in ATR units

   //--- scoring
   double   w_trend;
   double   w_momentum;
   double   w_structure;
   double   score_threshold;    // |score| needed for BUY/SELL, else HOLD

   //--- trade levels
   double   sl_atr_mult;        // stop distance in ATR
   double   tp1_rr;             // first target as R multiple
   double   tp2_rr;             // second target as R multiple

   //--- sessions (server hours)
   bool     use_session_filter;
   int      london_start;
   int      london_end;
   int      ny_start;
   int      ny_end;

   //--- news blackout window (server hours, 0 = off)
   bool     use_news_filter;
   int      news_hour;
   int      news_minute;
   int      news_block_minutes;

   //--- model gate
   bool     use_onnx;
   string   onnx_file;
   double   min_model_prob;     // 0..1
  };

//--- one timeframe result (one row of the dashboard)
struct SATSignal
  {
   ENUM_TIMEFRAMES  tf;
   ENUM_AT_ROLE     role;
   ENUM_AT_DIR      dir;
   double           score;          // -100 .. +100
   double           confidence;     // 0 .. 100
   double           entry;          // suggested entry
   double           sl;             // stop loss
   double           tp1;            // first target
   double           tp2;            // second target
   double           rr;             // reward / risk to TP1
   double           atr;            // ATR in price units
   double           lot;            // suggested volume
   bool             tradeable;      // score + full checklist passed
   int              checks_total;
   int              checks_passed;
   string           reason;         // why HOLD / why blocked
   datetime         bar_time;       // last closed bar used
  };

//--- account / market snapshot for the panel header
struct SATAccount
  {
   double   balance;
   double   equity;
   double   floating;
   double   today_profit;
   int      open_positions;
   double   spread_points;
   string   session_name;
   string   server_time;
   string   stats_line;      // measured hit rate of past signals
   int      day_trades;
  };

#endif // AUTOTRADER_TYPES_MQH
//+------------------------------------------------------------------+
