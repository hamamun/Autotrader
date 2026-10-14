//+------------------------------------------------------------------+
//| Phase7_Permutation.mq5                                            |
//| Autotrader Phase 7 - builds the shuffled price copies for gate G7 |
//| (the permutation test). Pure MQL5. Does not touch the EA.         |
//|                                                                   |
//| What it does: copies the M5 history of one symbol into custom     |
//| symbols. Copy 0 is the real history (the baseline). Copies 1..K   |
//| have their bar-to-bar moves shuffled into a random order. Each    |
//| bar keeps its own candle shape (wicks), so only the ORDER of the  |
//| moves is destroyed. If the EA only finds an edge in the real      |
//| order, the shuffled copies will show it.                          |
//|                                                                   |
//| How to use it (once per symbol class: FOREX, GOLD, CRYPTO, INDEX):|
//| 1. Attach to any chart. Set SourceSymbol (e.g. EURUSD) and        |
//|    ClassName (e.g. FOREX). Run it. It creates AT_<CLASS>_0 ..     |
//|    AT_<CLASS>_<K>.                                                |
//| 2. Strategy Tester: EA on chart M15 with symbol AT_<CLASS>_k, and |
//|    the SAME model for every copy (use "1 minute OHLC" for all).   |
//|    Use the same model for k = 0 as well, or the test is unfair.   |
//| 3. Rename each log to Phase7_PERM_<CLASS>_M15_<k>.csv.            |
//+------------------------------------------------------------------+
input string SourceSymbol = "";        // "" = the chart's symbol
input string ClassName    = "FOREX";   // FOREX, GOLD, CRYPTO or INDEX
input int    Shuffles     = 20;        // shuffled copies (gate needs >= 20)
input int    Seed         = 1;         // random seed (use a different one per class)
input int    Years        = 2;         // M5 history used

//+------------------------------------------------------------------+
//| shuffle the bar-to-bar moves; keep each bar's wicks              |
//| returns false if a shuffled price would fall to zero or below    |
//+------------------------------------------------------------------+
bool P7Shuffle(MqlRates &r[], const int n, const int digits)
  {
   double d[];
   ArrayResize(d, n - 1);
   for(int i = 1; i < n; i++)
      d[i - 1] = r[i].close - r[i - 1].close;

   //--- Fisher-Yates shuffle of the moves
   for(int i = n - 2; i > 0; i--)
     {
      int j = (int)(MathRand() % (i + 1));
      double tmp = d[i];
      d[i] = d[j];
      d[j] = tmp;
     }

   //--- wick sizes of the original candles
   double uw[];
   double lw[];
   ArrayResize(uw, n);
   ArrayResize(lw, n);
   for(int i = 0; i < n; i++)
     {
      double top = MathMax(r[i].open, r[i].close);
      double bot = MathMin(r[i].open, r[i].close);
      uw[i] = r[i].high - top;
      lw[i] = bot - r[i].low;
     }

   //--- rebuild: each bar opens where the previous one closed
   double prev = r[0].close;
   for(int i = 1; i < n; i++)
     {
      double c   = prev + d[i - 1];
      double o   = prev;
      if(c <= 0.0)
         return false;
      double top = MathMax(o, c);
      double bot = MathMin(o, c);
      r[i].open  = NormalizeDouble(o, digits);
      r[i].close = NormalizeDouble(c, digits);
      r[i].high  = NormalizeDouble(top + uw[i], digits);
      r[i].low   = NormalizeDouble(bot - lw[i], digits);
      if(r[i].low <= 0.0)
         return false;
      prev = c;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| create (or reuse) the custom symbol and copy the trading rules    |
//+------------------------------------------------------------------+
bool P7MakeSymbol(const string name, const string src)
  {
   CustomSymbolCreate(name, "Autotrader\\Phase7");   // fails quietly if it exists
   if(!SymbolSelect(name, true))
      return false;

   CustomSymbolSetInteger(name, SYMBOL_DIGITS, SymbolInfoInteger(src, SYMBOL_DIGITS));
   CustomSymbolSetDouble(name, SYMBOL_POINT, SymbolInfoDouble(src, SYMBOL_POINT));
   CustomSymbolSetDouble(name, SYMBOL_TRADE_TICK_SIZE, SymbolInfoDouble(src, SYMBOL_TRADE_TICK_SIZE));
   CustomSymbolSetDouble(name, SYMBOL_TRADE_TICK_VALUE, SymbolInfoDouble(src, SYMBOL_TRADE_TICK_VALUE));
   CustomSymbolSetDouble(name, SYMBOL_TRADE_CONTRACT_SIZE, SymbolInfoDouble(src, SYMBOL_TRADE_CONTRACT_SIZE));
   CustomSymbolSetDouble(name, SYMBOL_VOLUME_MIN, SymbolInfoDouble(src, SYMBOL_VOLUME_MIN));
   CustomSymbolSetDouble(name, SYMBOL_VOLUME_MAX, SymbolInfoDouble(src, SYMBOL_VOLUME_MAX));
   CustomSymbolSetDouble(name, SYMBOL_VOLUME_STEP, SymbolInfoDouble(src, SYMBOL_VOLUME_STEP));
   CustomSymbolSetInteger(name, SYMBOL_TRADE_STOPS_LEVEL, SymbolInfoInteger(src, SYMBOL_TRADE_STOPS_LEVEL));
   CustomSymbolSetInteger(name, SYMBOL_TRADE_MODE, SymbolInfoInteger(src, SYMBOL_TRADE_MODE));
   CustomSymbolSetString(name, SYMBOL_CURRENCY_BASE, SymbolInfoString(src, SYMBOL_CURRENCY_BASE));
   CustomSymbolSetString(name, SYMBOL_CURRENCY_PROFIT, SymbolInfoString(src, SYMBOL_CURRENCY_PROFIT));
   CustomSymbolSetString(name, SYMBOL_CURRENCY_MARGIN, SymbolInfoString(src, SYMBOL_CURRENCY_MARGIN));
   return true;
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   string src = (SourceSymbol == "") ? _Symbol : SourceSymbol;
   if(!SymbolSelect(src, true))
     {
      Print("Phase7_Permutation: symbol not found: ", src);
      return;
     }

   MqlRates base[];
   int want = Years * 365 * 24 * 12;          // M5 bars
   int n = CopyRates(src, PERIOD_M5, 0, want, base);
   if(n < 2000)
     {
      Print("Phase7_Permutation: not enough M5 history for ", src, " (", n, " bars)");
      return;
     }
   ArraySetAsSeries(base, false);             // oldest first

   int digits = (int)SymbolInfoInteger(src, SYMBOL_DIGITS);
   MathSrand(Seed);

   int made = 0;
   for(int k = 0; k <= Shuffles; k++)
     {
      string name = "AT_" + ClassName + "_" + IntegerToString(k);

      MqlRates r[];
      ArrayResize(r, n);
      for(int i = 0; i < n; i++)
         r[i] = base[i];

      if(k > 0 && !P7Shuffle(r, n, digits))
        {
         Print("Phase7_Permutation: skipped ", name, " (a shuffled price would go to zero)");
         continue;
        }
      if(!P7MakeSymbol(name, src))
        {
         Print("Phase7_Permutation: could not create ", name);
         continue;
        }

      CustomRatesDelete(name, 0, D'2099.12.31');
      int got = CustomRatesReplace(name, r[0].time, r[n - 1].time, r);
      if(got <= 0)
         Print("Phase7_Permutation: could not write prices to ", name, " error ", GetLastError());
      else
         made++;
     }

   Print("Phase7_Permutation: ", made, " custom symbols ready (AT_", ClassName,
         "_0 = real order, AT_", ClassName, "_1..", Shuffles, " = shuffled). Bars used: ", n);
  }
//+------------------------------------------------------------------+
