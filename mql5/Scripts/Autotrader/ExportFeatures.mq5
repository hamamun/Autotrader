//+------------------------------------------------------------------+
//|                                               ExportFeatures.mq5 |
//|  Writes the exact 24 model inputs for every closed M5 bar into    |
//|  MQL5\Files\autotrader_features_<SYMBOL>.csv                       |
//|                                                                    |
//|  Purpose: prove that the Python pipeline computes the SAME numbers |
//|  as the EA. Run:                                                   |
//|     python -m autotrader.cli parity --mt5-csv features.csv --csv m5.csv
//|                                                                    |
//|  This script mirrors CAtSignalEngine::BuildFeatures() exactly.     |
//|  If you change the formulas, change both files and bump           |
//|  FEATURE_CONTRACT_VERSION in python/autotrader/config.py.          |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version   "1.00"

input int InpBars       = 3000;   // How many closed M5 bars to export
input int InpEmaFast    = 9;
input int InpEmaSlow    = 21;
input int InpEmaBias    = 50;
input int InpAtrPeriod  = 14;
input int InpAdxPeriod  = 14;
input int InpRsiPeriod  = 14;
input int InpMacdFast   = 12;
input int InpMacdSlow   = 26;
input int InpMacdSignal = 9;

//+------------------------------------------------------------------+
int OnInit()
  {
   int h_m5_f = iMA(_Symbol,PERIOD_M5,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   int h_m5_s = iMA(_Symbol,PERIOD_M5,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   int h_m5_b = iMA(_Symbol,PERIOD_M5,InpEmaBias,0,MODE_EMA,PRICE_CLOSE);
   int h_m5_a = iATR(_Symbol,PERIOD_M5,InpAtrPeriod);
   int h_m5_x = iADX(_Symbol,PERIOD_M5,InpAdxPeriod);
   int h_m5_r = iRSI(_Symbol,PERIOD_M5,InpRsiPeriod,PRICE_CLOSE);
   int h_m5_m = iMACD(_Symbol,PERIOD_M5,InpMacdFast,InpMacdSlow,InpMacdSignal,PRICE_CLOSE);

   int h_15_f = iMA(_Symbol,PERIOD_M15,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   int h_15_s = iMA(_Symbol,PERIOD_M15,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   int h_15_b = iMA(_Symbol,PERIOD_M15,InpEmaBias,0,MODE_EMA,PRICE_CLOSE);
   int h_15_a = iATR(_Symbol,PERIOD_M15,InpAtrPeriod);
   int h_15_x = iADX(_Symbol,PERIOD_M15,InpAdxPeriod);
   int h_15_r = iRSI(_Symbol,PERIOD_M15,InpRsiPeriod,PRICE_CLOSE);
   int h_15_m = iMACD(_Symbol,PERIOD_M15,InpMacdFast,InpMacdSlow,InpMacdSignal,PRICE_CLOSE);

   int h_30_f = iMA(_Symbol,PERIOD_M30,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   int h_30_s = iMA(_Symbol,PERIOD_M30,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   int h_30_b = iMA(_Symbol,PERIOD_M30,InpEmaBias,0,MODE_EMA,PRICE_CLOSE);
   int h_30_a = iATR(_Symbol,PERIOD_M30,InpAtrPeriod);
   int h_30_x = iADX(_Symbol,PERIOD_M30,InpAdxPeriod);
   int h_30_r = iRSI(_Symbol,PERIOD_M30,InpRsiPeriod,PRICE_CLOSE);
   int h_30_m = iMACD(_Symbol,PERIOD_M30,InpMacdFast,InpMacdSlow,InpMacdSignal,PRICE_CLOSE);

   int handles[21] = {h_m5_f,h_m5_s,h_m5_b,h_m5_a,h_m5_x,h_m5_r,h_m5_m,
                      h_15_f,h_15_s,h_15_b,h_15_a,h_15_x,h_15_r,h_15_m,
                      h_30_f,h_30_s,h_30_b,h_30_a,h_30_x,h_30_r,h_30_m};
   for(int i=0;i<21;i++)
      if(handles[i]==INVALID_HANDLE)
        {
         PrintFormat("handle %d failed: %d",i,GetLastError());
         return(INIT_FAILED);
        }

   string file = StringFormat("autotrader_features_%s.csv",_Symbol);
   int fh = FileOpen(file,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(fh==INVALID_HANDLE)
     {
      PrintFormat("cannot open %s: %d",file,GetLastError());
      return(INIT_FAILED);
     }

   string head = "time";
   for(int k=0;k<24;k++)
      head += StringFormat(",f%d",k);
   FileWriteString(fh,head+"\r\n");

   int written = 0;
   for(int shift=InpBars;shift>=1;shift--)
     {
      datetime close_time = iTime(_Symbol,PERIOD_M5,shift)+PeriodSeconds(PERIOD_M5);
      int s15 = iBarShift(_Symbol,PERIOD_M15,close_time-1);
      int s30 = iBarShift(_Symbol,PERIOD_M30,close_time-1);
      if(s15<0 || s30<0)
         continue;

      string line = IntegerToString((long)iTime(_Symbol,PERIOD_M5,shift));
      line += "," + TF8(h_m5_f,h_m5_s,h_m5_b,h_m5_a,h_m5_x,h_m5_r,h_m5_m,shift,PERIOD_M5);
      line += "," + TF8(h_15_f,h_15_s,h_15_b,h_15_a,h_15_x,h_15_r,h_15_m,s15,PERIOD_M15);
      line += "," + TF8(h_30_f,h_30_s,h_30_b,h_30_a,h_30_x,h_30_r,h_30_m,s30,PERIOD_M30);
      FileWriteString(fh,line+"\r\n");
      written++;
     }
   FileClose(fh);
   PrintFormat("Autotrader features exported: %s (%d rows)",file,written);

   for(int i=0;i<21;i++)
      IndicatorRelease(handles[i]);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnStart() { /* all work happens in OnInit */ }
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| 8 features of one timeframe at one bar index, as a CSV fragment   |
//+------------------------------------------------------------------+
string TF8(const int hf,const int hs,const int hb,const int ha,const int hx,
           const int hr,const int hm,const int shift,const ENUM_TIMEFRAMES tf)
  {
   double ef = Buf(hf,0,shift),   es = Buf(hs,0,shift),  eb = Buf(hb,0,shift);
   double ef3= Buf(hf,0,shift+3), es3= Buf(hs,0,shift+3);
   double atr= Buf(ha,0,shift);
   double adx= Buf(hx,0,shift), pdi= Buf(hx,1,shift), ndi= Buf(hx,2,shift);
   double rsi= Buf(hr,0,shift);
   double hist = Buf(hm,0,shift)-Buf(hm,1,shift);
   double hist1= Buf(hm,0,shift+1)-Buf(hm,1,shift+1);
   double cl = iClose(_Symbol,tf,shift);
   if(atr<=0.0) atr=1e-9;

   return StringFormat("%.8f,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f",
                       (ef-es)/atr, (ef-ef3)/atr, (es-es3)/atr, (cl-eb)/atr,
                       adx/100.0, (pdi-ndi)/100.0, (rsi-50.0)/50.0,
                       (2.0*hist-hist1)/atr);
  }

//+------------------------------------------------------------------+
double Buf(const int handle,const int buffer,const int shift)
  {
   double tmp[];
   if(CopyBuffer(handle,buffer,shift,1,tmp)!=1)
      return(0.0);
   return(tmp[0]);
  }
//+------------------------------------------------------------------+
