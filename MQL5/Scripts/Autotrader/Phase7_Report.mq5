//+------------------------------------------------------------------+
//| Phase7_Report.mq5                                                 |
//| Autotrader Phase 7 - runs every validation gate on the test logs. |
//|                                                                   |
//| Pure MQL5. Reads files from MQL5\Files, writes                    |
//| MQL5\Files\Phase7_Report.txt and prints the same lines.           |
//|                                                                   |
//| FILE NAMES (put them in MQL5\Files, one per test run):           |
//|   Phase7_<CLASS>_<TF>.csv         real run, CLASS = FOREX, GOLD,  |
//|                                   CRYPTO or INDEX; TF = M5,M15,M30|
//|   Phase7_PERM_<CLASS>_M15_<k>.csv permutation run, k = 0..20      |
//|                                   (k = 0 is the unshuffled base)  |
//|   Phase7_DEMO.csv                 demo forward log                |
//| Each file is the EA's Autotrader_log.csv from that run, renamed.  |
//+------------------------------------------------------------------+
#include <Autotrader/Validation.mqh>

#define P7_WINDOWS   6
#define P7_BLOCKS    8
#define P7_MC_RUNS   1000
#define P7_MIN_OOS   200
#define P7_MIN_DEMO  60
#define P7_MIN_PERM  20
#define P7_MAX_DD_PCT 0.15

//--- run table: one row per log file
string   run_key[];
int      run_type[];     // 0 = real, 1 = demo, 2 = permutation
string   run_cls[];
string   run_tf[];
int      run_k[];
int      run_n[];
double   run_net[];

//--- trade table: one row per closed trade
int      tr_run[];
datetime tr_t[];
double   tr_net[];
string   tr_res[];

string   g_report[];

//+------------------------------------------------------------------+
void P7Out(const string s)
  {
   int n = ArraySize(g_report);
   ArrayResize(g_report, n + 1);
   g_report[n] = s;
   Print(s);
  }

//+------------------------------------------------------------------+
int P7AddRun(const string key, const int type, const string cls, const string tf, const int k)
  {
   int n = ArraySize(run_key);
   ArrayResize(run_key, n + 1);
   ArrayResize(run_type, n + 1);
   ArrayResize(run_cls, n + 1);
   ArrayResize(run_tf, n + 1);
   ArrayResize(run_k, n + 1);
   ArrayResize(run_n, n + 1);
   ArrayResize(run_net, n + 1);
   run_key[n]  = key;
   run_type[n] = type;
   run_cls[n]  = cls;
   run_tf[n]   = tf;
   run_k[n]    = k;
   run_n[n]    = 0;
   run_net[n]  = 0.0;
   return n;
  }

//+------------------------------------------------------------------+
void P7AddTrade(const int run, const datetime t, const double net, const string res)
  {
   int n = ArraySize(tr_run);
   ArrayResize(tr_run, n + 1);
   ArrayResize(tr_t, n + 1);
   ArrayResize(tr_net, n + 1);
   ArrayResize(tr_res, n + 1);
   tr_run[n] = run;
   tr_t[n]   = t;
   tr_net[n] = net;
   tr_res[n] = res;
   run_n[run]++;
   run_net[run] += net;
  }

//+------------------------------------------------------------------+
//| value of key inside detail "key=value;key=value"                  |
//+------------------------------------------------------------------+
string P7Field(const string detail, const string key)
  {
   string parts[];
   int n = StringSplit(detail, ';', parts);
   for(int i = 0; i < n; i++)
     {
      string kv[];
      if(StringSplit(parts[i], '=', kv) == 2 && kv[0] == key)
         return kv[1];
     }
   return "";
  }

//+------------------------------------------------------------------+
//| read the TRADE lines of one log file                              |
//+------------------------------------------------------------------+
void P7ParseFile(const string fname, const int run)
  {
   int h = FileOpen(fname, FILE_READ | FILE_CSV, ',');
   if(h == INVALID_HANDLE)
     {
      P7Out("cannot open " + fname);
      return;
     }
   string c[16];
   while(!FileIsEnding(h))
     {
      for(int i = 0; i < 16; i++)
         c[i] = FileReadString(h);
      if(c[3] != "TRADE")
         continue;
      string res = P7Field(c[15], "result");
      double net = StringToDouble(P7Field(c[15], "net"));
      datetime t = StringToTime(c[0]);
      P7AddTrade(run, t, net, res);
     }
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| find every Phase 7 file and sort it into the run table            |
//+------------------------------------------------------------------+
void P7Discover(void)
  {
   string fname;
   long hf = FileFindFirst("Phase7_*.csv", fname);
   if(hf == INVALID_HANDLE)
      return;
   do
     {
      string stem = StringSubstr(fname, 0, StringLen(fname) - 4);
      string tok[];
      int nt = StringSplit(stem, '_', tok);
      if(stem == "Phase7_DEMO")
        {
         int r = P7AddRun(fname, 1, "", "", 0);
         P7ParseFile(fname, r);
        }
      else if(nt == 5 && tok[0] == "Phase7" && tok[1] == "PERM" && tok[3] == "M15")
        {
         int r = P7AddRun(fname, 2, tok[2], tok[3], (int)StringToInteger(tok[4]));
         P7ParseFile(fname, r);
        }
      else if(nt == 3 && tok[0] == "Phase7")
        {
         int r = P7AddRun(fname, 0, tok[1], tok[2], 0);
         P7ParseFile(fname, r);
        }
      else
         P7Out("skipped file (name not recognised): " + fname);
     }
   while(FileFindNext(hf, fname));
   FileFindClose(hf);
  }

//+------------------------------------------------------------------+
//| which of n equal slices of [t0, t0+span) holds time t             |
//+------------------------------------------------------------------+
int P7Slot(const datetime t, const datetime t0, const double span, const int n)
  {
   int s = (int)(((double)(t - t0)) / span * n);
   if(s < 0)
      s = 0;
   if(s > n - 1)
      s = n - 1;
   return s;
  }

//+------------------------------------------------------------------+
double P7Pct(const int w, const int l)
  {
   if(w + l <= 0)
      return 0.0;
   return 100.0 * w / (double)(w + l);
  }

//+------------------------------------------------------------------+
void P7Save(void)
  {
   int h = FileOpen("Phase7_Report.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   for(int i = 0; i < ArraySize(g_report); i++)
      FileWriteString(h, g_report[i] + "\r\n");
   FileClose(h);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   MathSrand(20261014);
   ArrayResize(g_report, 0);
   P7Out("=== Autotrader Phase 7 validation report ===");
   P7Discover();

   int nRuns = ArraySize(run_key);
   int nReal = 0, nDemo = -1;
   for(int r = 0; r < nRuns; r++)
     {
      if(run_type[r] == 0) nReal++;
      if(run_type[r] == 1) nDemo = r;
     }
   if(nReal == 0)
     {
      P7Out("No real runs found (Phase7_<CLASS>_<TF>.csv). Nothing to judge.");
      P7Save();
      return;
     }

   //--- the period is the span of the real runs' trades
   datetime t0 = 0, t1 = 0;
   bool first = true;
   int nTr = ArraySize(tr_run);
   for(int i = 0; i < nTr; i++)
     {
      if(run_type[tr_run[i]] != 0)
         continue;
      if(first || tr_t[i] < t0) t0 = tr_t[i];
      if(first || tr_t[i] > t1) t1 = tr_t[i];
      first = false;
     }
   if(first || t1 <= t0)
     {
      P7Out("Real runs contain no closed trades. Nothing to judge.");
      P7Save();
      return;
     }
   double span = (double)(t1 - t0 + 1);
   datetime cut = t0 + (datetime)(0.7 * (double)(t1 - t0));   // last 30% = out-of-sample

   P7Out(StringFormat("Period %s .. %s (in-sample first 70%%, out-of-sample last 30%%)",
                      TimeToString(t0, TIME_DATE), TimeToString(t1, TIME_DATE)));
   P7Out(StringFormat("Real runs: %d   Permutation files: %d   Demo log: %s",
                      nReal, nRuns - nReal - (nDemo >= 0 ? 1 : 0),
                      (nDemo >= 0) ? "found" : "not yet logged"));

   //--- counts
   int W = 0, L = 0, B = 0;
   int wI = 0, lI = 0;
   int wO = 0, lO = 0, bO = 0;
   int ww[P7_WINDOWS], lw[P7_WINDOWS];
   for(int w = 0; w < P7_WINDOWS; w++)
     {
      ww[w] = 0;
      lw[w] = 0;
     }
   double oos[];
   int nO = 0;

   for(int i = 0; i < nTr; i++)
     {
      if(run_type[tr_run[i]] != 0)
         continue;
      bool win  = (tr_res[i] == "WIN");
      bool loss = (tr_res[i] == "LOSS");
      if(win) W++;
      else if(loss) L++;
      else B++;

      if(tr_t[i] >= cut)
        {
         if(win) wO++;
         else if(loss) lO++;
         else bO++;
         ArrayResize(oos, nO + 1);
         oos[nO] = tr_net[i];
         nO++;
        }
      else
        {
         if(win) wI++;
         else if(loss) lI++;
        }

      int s = P7Slot(tr_t[i], t0, span, P7_WINDOWS);
      if(win) ww[s]++;
      else if(loss) lw[s]++;
     }

   double wrO = P7Pct(wO, lO);
   double wrI = P7Pct(wI, lI);
   double wilO = VAL_WilsonLower(wO, wO + lO);
   string fails = "";

   P7Out("");
   P7Out(StringFormat("ALL real trades: Win %d  Loss %d  BE %d  (%.1f%%)", W, L, B, P7Pct(W, L)));
   P7Out(StringFormat("In-sample  : Win %d  Loss %d  win rate %.1f%%", wI, lI, wrI));
   P7Out(StringFormat("Out-sample : Win %d  Loss %d  BE %d  win rate %.1f%%  (95%% lower bound %.1f%%)",
                      wO, lO, bO, wrO, wilO * 100.0));

   //--- G1 sample size
   bool g1 = (nO >= P7_MIN_OOS);
   P7Out(StringFormat("[%s] G1 sample: %d out-of-sample trades (need %d)",
                      g1 ? "PASS" : "FAIL", nO, P7_MIN_OOS));
   if(!g1) fails += "G1 ";

   //--- G2 win rate: point >= 98% AND lower bound >= 95%
   bool g2 = (wrO >= 98.0 && wilO >= 0.95);
   P7Out(StringFormat("[%s] G2 win rate: %.1f%% (need >= 98%%), lower bound %.1f%% (need >= 95%%)",
                      g2 ? "PASS" : "FAIL", wrO, wilO * 100.0));
   if(!g2) fails += "G2 ";

   //--- G3 no degradation from in-sample to out-of-sample
   bool g3 = (wrI - wrO <= 3.0);
   P7Out(StringFormat("[%s] G3 no degradation: in-sample %.1f%% vs out-of-sample %.1f%% (max drop 3 points)",
                      g3 ? "PASS" : "FAIL", wrI, wrO));
   if(!g3) fails += "G3 ";

   //--- walk-forward windows (shown for review)
   P7Out("Walk-forward windows (6 equal periods):");
   for(int w = 0; w < P7_WINDOWS; w++)
      P7Out(StringFormat("   window %d: Win %d  Loss %d  win rate %.1f%%",
                         w + 1, ww[w], lw[w], P7Pct(ww[w], lw[w])));

   //--- G4 combinations: test on any two windows; the worst pair must hold
   double worst = 1.0;
   int worstI = -1, worstJ = -1;
   for(int i = 0; i < P7_WINDOWS; i++)
      for(int j = i + 1; j < P7_WINDOWS; j++)
        {
         double lb = VAL_WilsonLower(ww[i] + ww[j], ww[i] + ww[j] + lw[i] + lw[j]);
         if(lb < worst)
           {
            worst = lb;
            worstI = i;
            worstJ = j;
           }
        }
   bool g4 = (worst >= 0.90);
   P7Out(StringFormat("[%s] G4 window pairs (15 combinations): worst lower bound %.1f%% (need >= 90%%)  worst pair %d+%d",
                      g4 ? "PASS" : "FAIL", worst * 100.0, worstI + 1, worstJ + 1));
   if(!g4) fails += "G4 ";

   //--- G5 Deflated Sharpe Ratio on the out-of-sample trades
   double sr = 0.0, skew = 0.0, kurt = 3.0;
   VAL_Moments(oos, nO, sr, skew, kurt);

   double srs[];
   int nsr = 0;
   double tmp[];
   for(int r = 0; r < nRuns; r++)
     {
      if(run_type[r] != 0)
         continue;
      int m = 0;
      for(int i = 0; i < nTr; i++)
         if(tr_run[i] == r && tr_t[i] >= cut)
           {
            ArrayResize(tmp, m + 1);
            tmp[m] = tr_net[i];
            m++;
           }
      if(m >= 10)
        {
         double s1, s2, s3;
         VAL_Moments(tmp, m, s1, s2, s3);
         ArrayResize(srs, nsr + 1);
         srs[nsr] = s1;
         nsr++;
        }
     }
   double var_sr = 0.0;
   if(nsr >= 2)
     {
      double mu = 0.0;
      for(int i = 0; i < nsr; i++) mu += srs[i];
      mu /= nsr;
      for(int i = 0; i < nsr; i++) var_sr += (srs[i] - mu) * (srs[i] - mu);
      var_sr /= (nsr - 1);
     }
   double dsr = VAL_DeflatedSharpe(sr, nO, skew, kurt, nReal, var_sr);
   bool g5 = (dsr >= 0.95);
   P7Out(StringFormat("[%s] G5 Deflated Sharpe: per-trade Sharpe %.3f, probability it is real %.1f%% (need >= 95%%), %d trials",
                      g5 ? "PASS" : "FAIL", sr, dsr * 100.0, nReal));
   if(!g5) fails += "G5 ";

   //--- G6 PBO over the real runs as trials, 8 time blocks
   bool g6 = false;
   if(nReal >= 2)
     {
      int col[];
      ArrayResize(col, nRuns);
      int c = 0;
      for(int r = 0; r < nRuns; r++)
        {
         col[r] = -1;
         if(run_type[r] == 0)
           {
            col[r] = c;
            c++;
           }
        }
      double mtx[];
      ArrayResize(mtx, P7_BLOCKS * nReal);
      ArrayInitialize(mtx, 0.0);
      for(int i = 0; i < nTr; i++)
        {
         if(run_type[tr_run[i]] != 0)
            continue;
         int b = P7Slot(tr_t[i], t0, span, P7_BLOCKS);
         mtx[b * nReal + col[tr_run[i]]] += tr_net[i];
        }
      int combos = 0;
      double pbo = VAL_PBO(mtx, P7_BLOCKS, nReal, combos);
      g6 = (pbo < 0.25);
      P7Out(StringFormat("[%s] G6 overfitting (PBO): %.1f%% over %d splits (need < 25%%)",
                         g6 ? "PASS" : "FAIL", pbo * 100.0, combos));
     }
   else
      P7Out("[FAIL] G6 overfitting (PBO): needs at least 2 real runs");
   if(!g6) fails += "G6 ";

   //--- G7 permutation test per symbol class (M15, baseline k = 0)
   string classes[4];
   classes[0] = "FOREX";
   classes[1] = "GOLD";
   classes[2] = "CRYPTO";
   classes[3] = "INDEX";
   bool g7 = true;
   for(int ci = 0; ci < 4; ci++)
     {
      int kmax = -1;
      for(int r = 0; r < nRuns; r++)
         if(run_type[r] == 2 && run_cls[r] == classes[ci] && run_k[r] > kmax)
            kmax = run_k[r];
      if(kmax < 0)
        {
         P7Out("[FAIL] G7 permutation " + classes[ci] + ": no permutation files");
         g7 = false;
         continue;
        }
      double sums[];
      bool   has[];
      ArrayResize(sums, kmax + 1);
      ArrayResize(has, kmax + 1);
      for(int k = 0; k <= kmax; k++)
        {
         sums[k] = 0.0;
         has[k] = false;
        }
      for(int r = 0; r < nRuns; r++)
         if(run_type[r] == 2 && run_cls[r] == classes[ci])
           {
            sums[run_k[r]] = run_net[r];
            has[run_k[r]] = true;
           }
      if(!has[0])
        {
         P7Out("[FAIL] G7 permutation " + classes[ci] + ": baseline (k = 0) missing");
         g7 = false;
         continue;
        }
      int valid = 0, beat = 0;
      for(int k = 1; k <= kmax; k++)
         if(has[k])
           {
            valid++;
            if(sums[k] >= sums[0])
               beat++;
           }
      double p = (beat + 1.0) / (valid + 1.0);
      bool ok = (valid >= P7_MIN_PERM && p < 0.05);
      P7Out(StringFormat("[%s] G7 permutation %s: p = %.3f from %d shuffles (need p < 0.05, >= %d shuffles)",
                         ok ? "PASS" : "FAIL", classes[ci], p, valid, P7_MIN_PERM));
      if(!ok)
         g7 = false;
     }
   if(!g7) fails += "G7 ";

   //--- G8 drawdown range from reshuffled out-of-sample trades
   double dd95 = VAL_ShuffledDrawdown(oos, nO, P7_MC_RUNS, 0.95);
   double limit = P7_MAX_DD_PCT * AccountInfoDouble(ACCOUNT_BALANCE);
   bool g8 = (nO > 0 && dd95 <= limit);
   P7Out(StringFormat("[%s] G8 drawdown: 95th percentile %.2f after reshuffling (limit %.2f = 15%% of balance)",
                      g8 ? "PASS" : "FAIL", dd95, limit));
   if(!g8) fails += "G8 ";

   //--- G9 demo forward
   bool g9 = false;
   if(nDemo < 0)
      P7Out("[PENDING] G9 demo forward: Phase7_DEMO.csv not logged yet (4-8 weeks)");
   else
     {
      int dW = 0, dL = 0;
      for(int i = 0; i < nTr; i++)
        {
         if(tr_run[i] != nDemo)
            continue;
         if(tr_res[i] == "WIN") dW++;
         else if(tr_res[i] == "LOSS") dL++;
        }
      double dwr = P7Pct(dW, dL);
      double dlb = VAL_WilsonLower(dW, dW + dL);
      g9 = (dW + dL >= P7_MIN_DEMO && dwr >= 98.0 && dlb >= 0.95);
      P7Out(StringFormat("[%s] G9 demo forward: %d Win, %d Loss, win rate %.1f%%, lower bound %.1f%% (need >= %d trades, 98%%, 95%%)",
                         g9 ? "PASS" : "FAIL", dW, dL, dwr, dlb * 100.0, P7_MIN_DEMO));
      if(!g9) fails += "G9 ";
     }

   //--- verdict
   P7Out("");
   if(fails == "" && g9)
      P7Out("OVERALL: PASS - every gate passed. The EA may move to the next step (small live).");
   else
     {
      if(fails != "")
         P7Out("OVERALL: NOT PASSED - failed gates: " + fails);
      if(!g9)
         P7Out("OVERALL: demo forward (G9) is still pending. Keep the EA on demo.");
      P7Out("Keep the EA on demo. A failed gate means fine-tuning (Phase 9), then Phase 7 again.");
     }

   P7Save();
   P7Out("Report saved to MQL5\\Files\\Phase7_Report.txt");
  }
//+------------------------------------------------------------------+
