//+------------------------------------------------------------------+
//|                                                  Autotrader.mq5  |
//|   Autotrader - fully automated direction engine for MT5           |
//|   M5  -> scalping trigger                                         |
//|   M15 -> short term setup                                         |
//|   M30 -> intraday bias                                            |
//|                                                                   |
//|   Signals are computed on CLOSED bars only, so they never repaint.|
//|   Default mode is SIGNAL ONLY - switch to AUTO when you are happy.|
//+------------------------------------------------------------------+
#property copyright "Autotrader"
#property link      "https://github.com/hamamun/Autotrader"
#property version   "0.10"
#property description "Multi timeframe BUY/SELL/HOLD direction engine with dashboard."

#include <Autotrader/Types.mqh>
#include <Autotrader/SignalEngine.mqh>
#include <Autotrader/RiskManager.mqh>
#include <Autotrader/Panel.mqh>
#include <Autotrader/OnnxBrain.mqh>
#include <Autotrader/Journal.mqh>

//==================================================================
//  INPUTS
//==================================================================
input group "=== Signal engine ==="
input int      InpEmaFast        = 9;      // EMA fast
input int      InpEmaSlow        = 21;     // EMA slow
input int      InpEmaBias        = 50;     // EMA bias
input int      InpAtrPeriod      = 14;     // ATR period
input int      InpAdxPeriod      = 14;     // ADX period
input int      InpRsiPeriod      = 14;     // RSI period
input int      InpMacdFast       = 12;     // MACD fast
input int      InpMacdSlow       = 26;     // MACD slow
input int      InpMacdSignal     = 9;      // MACD signal
input int      InpSwingLookback  = 20;     // Swing high/low lookback (bars)

input group "=== Votes and thresholds ==="
input double   InpWTrend         = 1.00;   // Weight: trend
input double   InpWMomentum      = 0.80;   // Weight: momentum
input double   InpWStructure     = 0.60;   // Weight: structure
input double   InpScoreThreshold = 25.0;   // Min |score| for BUY/SELL (below = HOLD)
input double   InpAdxMin         = 18.0;   // ADX below this = no edge
input double   InpRsiOverbought  = 78.0;   // RSI overbought (momo damped)
input double   InpRsiOversold    = 22.0;   // RSI oversold  (momo damped)
input double   InpMaxExtAtr      = 3.0;    // Max distance from EMA50 in ATR

input group "=== Market filters ==="
input double   InpMaxSpreadPts   = 0;      // Max spread in points (0 = off)
input double   InpMinAtrPts      = 0;      // Min ATR in points (0 = off)
input double   InpMaxAtrPts      = 0;      // Max ATR in points (0 = off)
input bool     InpUseSession     = true;   // Trade only London / New York
input int      InpLondonStart    = 7;      // London start hour (server)
input int      InpLondonEnd      = 16;     // London end hour (server)
input int      InpNyStart        = 12;     // New York start hour (server)
input int      InpNyEnd          = 21;     // New York end hour (server)
input bool     InpUseNews        = false;  // News blackout window
input int      InpNewsHour       = 14;     // News hour (server)
input int      InpNewsMinute     = 30;     // News minute
input int      InpNewsBlockMin   = 15;     // Block minutes before/after

input group "=== Trade levels ==="
input double   InpSlAtrMult      = 1.5;    // Stop loss = ATR x
input double   InpTp1Rr          = 1.5;    // TP1 as R multiple
input double   InpTp2Rr          = 3.0;    // TP2 as R multiple
input bool     InpUseBreakeven   = true;   // Move to break even
input double   InpBreakevenR     = 1.0;    // After this many R
input bool     InpUseTrailing    = true;   // ATR trailing stop
input double   InpTrailAtrMult   = 1.2;    // Trail distance = ATR x

input group "=== Risk ==="
input ENUM_AT_MODE InpMode       = AT_MODE_SIGNAL_ONLY; // Mode (AUTO = sends orders)
input double   InpRiskPct        = 0.50;   // Risk per trade (% balance)
input double   InpMaxDailyLoss   = 3.0;    // Max daily loss (%, 0 = off)
input int      InpMaxTradesDay   = 10;     // Max trades per day (0 = off)
input int      InpMaxOpen        = 1;      // Max open positions

input group "=== AI model (optional) ==="
input bool     InpUseOnnx        = true;   // Use ONNX model when available
input string   InpOnnxFile       = "autotrader_m5.onnx"; // Model file in Common\Files
input double   InpMinModelProb   = 0.55;   // Min model probability to allow a trade

input group "=== Journal ==="
input bool     InpJournal        = true;   // Write every signal + its outcome to CSV
input string   InpJournalFile    = "autotrader_journal.csv"; // File in the common Files folder

input group "=== Dashboard ==="
input bool     InpShowPanel      = true;   // Show dashboard
input int      InpPanelX         = 12;     // Panel X
input int      InpPanelY         = 24;     // Panel Y
input int      InpPanelWidth     = 720;    // Panel width
input int      InpPanelFontSize  = 9;      // Panel font size

//==================================================================
//  GLOBALS
//==================================================================
CAtSignalEngine  g_engine;
CAtRiskManager   g_risk;
CAtPanel         g_panel;
CAtOnnxBrain     g_brain;
CAtJournal       g_journal;

SATSettings      g_cfg;
SATSignal        g_sig[AT_MAX_TF];
SATAccount       g_acc;
ENUM_AT_MODE     g_mode;
ENUM_AT_DIR      g_overall = AT_HOLD;
double           g_overall_conf = 0.0;
int              g_aligned = 0;
int              g_last_day = -1;
bool             g_data_ready = false;
bool             g_first_run  = true;

//==================================================================
int OnInit()
  {
   if(!MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_TRADE_ALLOWED) && InpMode==AT_MODE_AUTO)
      Print("[Autotrader] AutoTrading button is OFF - EA will only show signals.");

   //--- build settings
   g_cfg.ema_fast        = InpEmaFast;
   g_cfg.ema_slow        = InpEmaSlow;
   g_cfg.ema_bias        = InpEmaBias;
   g_cfg.atr_period      = InpAtrPeriod;
   g_cfg.adx_period      = InpAdxPeriod;
   g_cfg.rsi_period      = InpRsiPeriod;
   g_cfg.macd_fast       = InpMacdFast;
   g_cfg.macd_slow       = InpMacdSlow;
   g_cfg.macd_signal     = InpMacdSignal;
   g_cfg.swing_lookback  = InpSwingLookback;

   g_cfg.adx_min         = InpAdxMin;
   g_cfg.rsi_overbought  = InpRsiOverbought;
   g_cfg.rsi_oversold    = InpRsiOversold;
   g_cfg.max_spread_points = InpMaxSpreadPts;
   g_cfg.min_atr_points  = InpMinAtrPts;
   g_cfg.max_atr_points  = InpMaxAtrPts;
   g_cfg.max_ext_atr     = InpMaxExtAtr;

   g_cfg.w_trend         = InpWTrend;
   g_cfg.w_momentum      = InpWMomentum;
   g_cfg.w_structure     = InpWStructure;
   g_cfg.score_threshold = InpScoreThreshold;

   g_cfg.sl_atr_mult     = InpSlAtrMult;
   g_cfg.tp1_rr          = InpTp1Rr;
   g_cfg.tp2_rr          = InpTp2Rr;

   g_cfg.use_session_filter = InpUseSession;
   g_cfg.london_start    = InpLondonStart;
   g_cfg.london_end      = InpLondonEnd;
   g_cfg.ny_start        = InpNyStart;
   g_cfg.ny_end          = InpNyEnd;

   g_cfg.use_news_filter = InpUseNews;
   g_cfg.news_hour       = InpNewsHour;
   g_cfg.news_minute     = InpNewsMinute;
   g_cfg.news_block_minutes = InpNewsBlockMin;

   g_cfg.use_onnx        = InpUseOnnx;
   g_cfg.onnx_file       = InpOnnxFile;
   g_cfg.min_model_prob  = InpMinModelProb;

   g_mode = InpMode;

   //--- engine
   g_engine.Init(_Symbol,g_cfg);
   if(iBars(_Symbol,PERIOD_M30)<200)
      Print("[Autotrader] Not much history on M30 yet - wait a moment.");

   //--- risk manager
   g_risk.Init(_Symbol,InpRiskPct,InpMaxDailyLoss,InpMaxTradesDay,InpMaxOpen,
               InpUseBreakeven,InpBreakevenR,InpUseTrailing,InpTrailAtrMult);

   //--- AI (optional)
   if(InpUseOnnx)
      g_brain.Load(InpOnnxFile);

   //--- journal (measures the real hit rate of every signal shown)
   if(InpJournal)
      g_journal.Init(_Symbol,InpJournalFile);

   //--- dashboard
   if(InpShowPanel)
      g_panel.Init(_Symbol,InpPanelX,InpPanelY,InpPanelWidth,InpPanelFontSize);

   g_acc.balance        = AccountInfoDouble(ACCOUNT_BALANCE);
   g_acc.equity         = AccountInfoDouble(ACCOUNT_EQUITY);
   g_acc.floating       = 0.0;
   g_acc.today_profit   = 0.0;
   g_acc.open_positions = 0;
   g_acc.spread_points  = 0.0;
   g_acc.session_name   = "";
   g_acc.server_time    = "";
   g_acc.stats_line     = "";
   g_acc.day_trades     = 0;

   EventSetTimer(1);                         // 1 second heartbeat
   PrintFormat("[Autotrader] v%s started on %s. Mode=%s, risk=%.2f%%",
               AT_VERSION,_Symbol,(g_mode==AT_MODE_AUTO ? "AUTO":"SIGNAL ONLY"),InpRiskPct);
   return(INIT_SUCCEEDED);
  }

//==================================================================
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_engine.Deinit();
   g_brain.Release();
   g_journal.Deinit();
   g_panel.Destroy();
  }

//==================================================================
void OnTick()
  {
   //--- positions are managed by the timer as well, but a fast tick
   //--- path keeps trailing stops tight during volatile moments
   if(g_mode==AT_MODE_AUTO)
      ManagePositions();
  }

//==================================================================
void OnTimer()
  {
   RefreshSnapshot();

   //--- evaluate on the first heartbeat, then once per closed M5 bar
   bool new_bar = g_engine.NewBar(0);
   if(g_first_run || new_bar)
     {
      //--- first resolve what the older signals actually did
      if(!g_first_run && InpJournal)
         g_journal.CheckPending();

      EvaluateAll();

      //--- then write the new signals down
      if(InpJournal)
         for(int i=0;i<AT_MAX_TF;i++)
            g_journal.AddSignal(g_sig[i],i);

      //--- and only now may an order be sent
      if(g_mode==AT_MODE_AUTO)
         TryEnter();

      g_first_run = false;
     }

   if(g_mode==AT_MODE_AUTO)
      ManagePositions();

   if(InpShowPanel)
      g_panel.Update(g_sig,AT_MAX_TF,g_overall,g_overall_conf,g_aligned,
                     g_acc,g_mode,InpRiskPct,g_brain.Ready());
  }

//==================================================================
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK)
      return;
   if(!g_panel.HandleClick(sparam))
      return;

   if(sparam==AT_PFX"btn_auto")
     {
      g_mode = AT_MODE_AUTO;
      Print("[Autotrader] Mode -> AUTO");
     }
   else if(sparam==AT_PFX"btn_signal")
     {
      g_mode = AT_MODE_SIGNAL_ONLY;
      Print("[Autotrader] Mode -> SIGNAL ONLY");
     }
   else if(sparam==AT_PFX"btn_close")
     {
      g_risk.CloseAll(_Symbol);
      Print("[Autotrader] All positions closed by user.");
     }
   else if(sparam==AT_PFX"btn_hide")
     {
      g_panel.Show(false);
     }
   ChartRedraw();
  }

//==================================================================
//  EVALUATE ALL TIMEFRAMES
//==================================================================
void EvaluateAll()
  {
   double momo_sum = 0.0;
   g_aligned = 0;
   int dirs_buy = 0, dirs_sell = 0, dirs_hold = 0;

   //--- highest timeframe first: M5 and M15 must see a fresh M30 bias
   for(int i=AT_MAX_TF-1;i>=0;i--)
     {
      int cp=0,ct=0;
      if(!g_engine.Evaluate(i,g_sig[i],cp,ct))
        {
         g_data_ready = false;
         return;
        }
      g_data_ready = true;

      //--- suggested lot for the panel
      if(g_sig[i].dir!=AT_HOLD)
         g_sig[i].lot = g_risk.CalcLot(g_sig[i].entry,g_sig[i].sl);
      else
         g_sig[i].lot = 0.0;

      if(g_sig[i].dir==AT_BUY)       dirs_buy++;
      else if(g_sig[i].dir==AT_SELL) dirs_sell++;
      else                           dirs_hold++;
      momo_sum += g_sig[i].score;
     }

   if(!g_data_ready)
      return;

   //--- overall verdict: majority of timeframes, weighted by conviction
   double avg = momo_sum/AT_MAX_TF;
   if(dirs_buy>dirs_sell && avg>0.0)
      g_overall = AT_BUY;
   else if(dirs_sell>dirs_buy && avg<0.0)
      g_overall = AT_SELL;
   else
      g_overall = AT_HOLD;

   if(g_overall==AT_BUY)
      g_aligned = dirs_buy;
   else if(g_overall==AT_SELL)
      g_aligned = dirs_sell;
   else
      g_aligned = dirs_hold;

   g_overall_conf = MathMin(100.0,
                    (g_sig[0].confidence+g_sig[1].confidence+g_sig[2].confidence)/3.0);
  }

//==================================================================
//  ENTRY LOGIC (AUTO mode only)
//==================================================================
void TryEnter()
  {
   if(!g_data_ready)
      return;
   if(g_overall==AT_HOLD)
      return;
   if(!g_risk.CanOpen())
      return;

   //--- all three timeframes must agree and pass their checklist
   for(int i=0;i<AT_MAX_TF;i++)
     {
      if(g_sig[i].dir!=g_overall || !g_sig[i].tradeable)
         return;
     }

   //--- optional AI confirmation
   if(g_brain.Ready())
     {
      double f[];
      if(g_engine.BuildFeatures(f))
        {
         double pb=0.0,ph=0.0,ps=0.0;
         if(g_brain.Predict(f,pb,ph,ps))
           {
            double p = (g_overall==AT_BUY) ? pb : ps;
            if(p < InpMinModelProb)
              {
               PrintFormat("[Autotrader] trade skipped - model probability %.2f < %.2f",p,InpMinModelProb);
               return;
              }
           }
        }
     }

   //--- levels come from the M5 trigger row (tightest, most current)
   double entry = g_sig[0].entry;
   double sl    = g_sig[0].sl;
   double tp    = g_sig[0].tp1;
   g_risk.NormalizeLevels(g_overall,entry,sl,tp);

   double lot = g_risk.CalcLot(entry,sl);
   if(lot<=0.0)
     {
      Print("[Autotrader] lot size is zero - check symbol tick value / contract size.");
      return;
     }

   string comment = StringFormat("AT %s",(g_overall==AT_BUY ? "BUY":"SELL"));
   if(g_risk.OpenMarket(g_overall,lot,sl,tp,comment))
     {
      g_risk.RegisterTrade();
      PrintFormat("[Autotrader] %s %.2f lots @ %.5f SL %.5f TP %.5f | conf %.0f%%",
                  (g_overall==AT_BUY ? "BUY":"SELL"),lot,entry,sl,tp,g_overall_conf);
     }
  }

//==================================================================
void ManagePositions()
  {
   double atr = 0.0;
   if(g_sig[0].atr>0.0)
      atr = g_sig[0].atr;
   g_risk.ManageOpenPositions(atr);
  }

//==================================================================
//  ACCOUNT / MARKET SNAPSHOT FOR THE PANEL
//==================================================================
void RefreshSnapshot()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);

   if(dt.day!=g_last_day)
     {
      g_last_day = dt.day;
      g_risk.NewDay(dt.day);
     }

   g_acc.balance        = AccountInfoDouble(ACCOUNT_BALANCE);
   g_acc.equity         = AccountInfoDouble(ACCOUNT_EQUITY);
   g_acc.floating       = AccountInfoDouble(ACCOUNT_PROFIT);
   g_acc.today_profit   = g_risk.TodayProfit();
   g_acc.open_positions = g_risk.OpenCount();
   g_acc.day_trades     = g_risk.TodayTrades();
   g_acc.spread_points  = (double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   g_acc.stats_line     = InpJournal ? g_journal.StatsLine() : "Journal disabled";
   g_acc.server_time    = TimeToString(TimeCurrent(),TIME_MINUTES|TIME_SECONDS);

   if(dt.hour>=InpLondonStart && dt.hour<InpLondonEnd &&
      dt.hour>=InpNyStart     && dt.hour<InpNyEnd)
      g_acc.session_name = "LONDON+NY";
   else if(dt.hour>=InpLondonStart && dt.hour<InpLondonEnd)
      g_acc.session_name = "LONDON";
   else if(dt.hour>=InpNyStart && dt.hour<InpNyEnd)
      g_acc.session_name = "NEW YORK";
   else
      g_acc.session_name = "ASIA / OFF";
  }
//+------------------------------------------------------------------+
