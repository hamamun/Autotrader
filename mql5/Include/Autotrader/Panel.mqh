//+------------------------------------------------------------------+
//|                                                    Panel.mqh     |
//|   On-chart dashboard. Shows the same information as the old      |
//|   interface: per timeframe direction, confidence, entry, SL,     |
//|   TP, lot and the checklist result, plus one overall verdict.    |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_PANEL_MQH
#define AUTOTRADER_PANEL_MQH

#include "Types.mqh"

#define AT_PFX "at_"
#define AT_COLS 9

//--- palette (one place to change the whole look)
#define AT_C_BG        C'16,20,27'
#define AT_C_HEADER    C'24,30,40'
#define AT_C_CARD      C'28,34,45'
#define AT_C_BORDER    C'48,58,74'
#define AT_C_TEXT      C'228,234,244'
#define AT_C_MUTED     C'132,143,160'
#define AT_C_BUY       C'0,200,120'
#define AT_C_SELL      C'255,74,68'
#define AT_C_HOLD      C'150,162,180'
#define AT_C_ACCENT    C'255,196,0'
#define AT_C_BTN       C'38,46,60'
#define AT_C_BTN_ON    C'0,150,90'

class CAtPanel
  {
private:
   int      m_x;
   int      m_y;
   int      m_w;
   int      m_h;
   int      m_fontsize;
   bool     m_visible;
   string   m_symbol;
   int      m_digits;
   int      m_colx[AT_COLS];
   int      m_colw[AT_COLS];
   int      m_rowy[AT_MAX_TF];
   string   m_last_reason;

   //--- drawing helpers
   void     Rect(const string name,const int x,const int y,const int w,const int h,
                 const color bg,const color border);
   void     Text(const string name,const int x,const int y,const string txt,const color clr,
                 const int size,const int anchor,const string font="Segoe UI");
   void     Btn(const string name,const int x,const int y,const int w,const int h,
                const string txt,const color bg,const color fg);
   string   DirText(const ENUM_AT_DIR d) const;
   color    DirColor(const ENUM_AT_DIR d) const;

public:
   void     Init(const string symbol,const int x,const int y,const int width,const int fontsize);
   void     Destroy();
   void     Show(const bool visible);
   bool     Visible() const { return(m_visible); }
   bool     HandleClick(const string obj_name);
   void     Update(const SATSignal &sig[],const int count,
                   const ENUM_AT_DIR overall,const double overall_conf,const int aligned,
                   const SATAccount &acc,const ENUM_AT_MODE mode,const double risk_pct,
                   const bool ai_ready);
   int      Width()  const { return(m_w); }
   int      Height() const { return(m_h); }
  };

//+------------------------------------------------------------------+
void CAtPanel::Init(const string symbol,const int x,const int y,const int width,const int fontsize)
  {
   m_symbol   = symbol;
   m_x        = x;
   m_y        = y;
   m_w        = width;
   m_fontsize = fontsize;
   m_visible  = true;
   m_digits   = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   m_last_reason = "";

   //--- section heights
   int h_header = 56;
   int h_banner = 42;
   int h_collab = 24;
   int h_row    = 26;
   int h_status = 22;
   int h_stats  = 20;
   int h_footer = 46;
   m_h = h_header+h_banner+h_collab+h_row*AT_MAX_TF+h_status+h_stats+h_footer;

   //--- column widths (fractions of the panel width)
   double frac[AT_COLS] = {0.06,0.11,0.09,0.14,0.14,0.14,0.10,0.09,0.13};
   int xcur = 0;
   for(int c=0;c<AT_COLS;c++)
     {
      m_colw[c] = (int)MathRound(m_w*frac[c]);
      m_colx[c] = xcur;
      xcur += m_colw[c];
     }
   m_colw[AT_COLS-1] = m_w-(m_colx[AT_COLS-1]);

   int ycur = m_y;
   //--- background + header
   Rect(AT_PFX"bg",m_x,ycur,m_w,m_h,AT_C_BG,AT_C_BORDER);
   Rect(AT_PFX"header",m_x,ycur,m_w,h_header,AT_C_HEADER,AT_C_HEADER);
   Text(AT_PFX"t_title",m_x+12,ycur+8,"AUTOTRADER  v"+AT_VERSION,AT_C_ACCENT,fontsize+2,ANCHOR_LEFT_UPPER);
   Text(AT_PFX"t_symbol",m_x+m_w-12,ycur+8,symbol+"   M5 / M15 / M30",AT_C_TEXT,fontsize+1,ANCHOR_RIGHT_UPPER);
   Text(AT_PFX"t_acct",m_x+12,ycur+30,"",AT_C_MUTED,fontsize,ANCHOR_LEFT_UPPER);
   Text(AT_PFX"t_clock",m_x+m_w-12,ycur+30,"",AT_C_MUTED,fontsize,ANCHOR_RIGHT_UPPER);
   ycur += h_header+4;

   //--- overall verdict banner
   Rect(AT_PFX"banner",m_x+8,ycur,m_w-16,h_banner-6,AT_C_CARD,AT_C_BORDER);
   Text(AT_PFX"t_overall_lbl",m_x+22,ycur+11,"OVERALL",AT_C_MUTED,fontsize,ANCHOR_LEFT_UPPER);
   Text(AT_PFX"t_overall",m_x+95,ycur+4,"",AT_C_HOLD,fontsize+8,ANCHOR_LEFT_UPPER);
   Text(AT_PFX"t_conf",m_x+m_w-22,ycur+11,"",AT_C_TEXT,fontsize+1,ANCHOR_RIGHT_UPPER);
   ycur += h_banner;

   //--- table header
   Rect(AT_PFX"collab",m_x+8,ycur,m_w-16,h_collab,AT_C_HEADER,AT_C_HEADER);
   string hdr[AT_COLS] = {"TF","SIGNAL","CONF","ENTRY","SL","TP1","R:R","LOT","CHECKLIST"};
   for(int c=0;c<AT_COLS;c++)
     {
      int tx = (c<=1) ? m_x+8+m_colx[c]+8 : m_x+8+m_colx[c]+m_colw[c]-8;
      int an = (c<=1) ? ANCHOR_LEFT_UPPER : ANCHOR_RIGHT_UPPER;
      Text(AT_PFX"h"+IntegerToString(c),tx,ycur+5,hdr[c],AT_C_MUTED,fontsize,an);
     }
   ycur += h_collab;

   //--- one row per timeframe
   for(int i=0;i<AT_MAX_TF;i++)
     {
      m_rowy[i] = ycur;
      color bg = ((i%2)==0) ? AT_C_CARD : AT_C_BG;
      Rect(AT_PFX"row"+IntegerToString(i),m_x+8,ycur,m_w-16,h_row,bg,bg);
      Text(AT_PFX"r"+IntegerToString(i)+"0",m_x+8+m_colx[0]+8,ycur+6,"",AT_C_TEXT,fontsize,ANCHOR_LEFT_UPPER);
      Text(AT_PFX"r"+IntegerToString(i)+"1",m_x+8+m_colx[1]+8,ycur+6,"",AT_C_HOLD,fontsize,ANCHOR_LEFT_UPPER);
      for(int c=2;c<AT_COLS;c++)
         Text(AT_PFX"r"+IntegerToString(i)+IntegerToString(c),
              m_x+8+m_colx[c]+m_colw[c]-8,ycur+6,"",AT_C_TEXT,fontsize,ANCHOR_RIGHT_UPPER);
      ycur += h_row;
     }

   //--- status line
   Text(AT_PFX"t_status",m_x+22,ycur+4,"",AT_C_MUTED,fontsize,ANCHOR_LEFT_UPPER);
   ycur += h_status;

   //--- measured statistics line (real outcomes of past signals)
   Text(AT_PFX"t_stats",m_x+22,ycur+4,"",AT_C_MUTED,fontsize,ANCHOR_LEFT_UPPER);
   ycur += h_stats;

   //--- footer buttons
   Rect(AT_PFX"footer",m_x+8,ycur,m_w-16,h_footer-6,AT_C_HEADER,AT_C_BORDER);
   int by = ycur+11;
   Btn(AT_PFX"btn_auto",m_x+20,by,74,22,"AUTO",AT_C_BTN,AT_C_TEXT);
   Btn(AT_PFX"btn_signal",m_x+100,by,110,22,"SIGNAL ONLY",AT_C_BTN_ON,AT_C_TEXT);
   Btn(AT_PFX"btn_close",m_x+216,by,96,22,"CLOSE ALL",AT_C_BTN,AT_C_TEXT);
   Btn(AT_PFX"btn_hide",m_x+m_w-96,by,76,22,"HIDE",AT_C_BTN,AT_C_TEXT);
   Text(AT_PFX"t_foot",m_x+330,by+3,"",AT_C_MUTED,fontsize,ANCHOR_LEFT_UPPER);

   ChartRedraw();
  }

//+------------------------------------------------------------------+
void CAtPanel::Destroy()
  {
   ObjectsDeleteAll(0,AT_PFX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void CAtPanel::Show(const bool visible)
  {
   m_visible = visible;
   int total = ObjectsTotal(0,0,-1);
   for(int i=0;i<total;i++)
     {
      string nm = ObjectName(0,i,0,-1);
      if(StringFind(nm,AT_PFX)!=0)
         continue;
      ObjectSetInteger(0,nm,OBJPROP_TIMEFRAMES,visible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
bool CAtPanel::HandleClick(const string obj_name)
  {
   if(StringFind(obj_name,AT_PFX)!=0)
      return(false);
   ObjectSetInteger(0,obj_name,OBJPROP_STATE,false);
   return(true);
  }

//+------------------------------------------------------------------+
string CAtPanel::DirText(const ENUM_AT_DIR d) const
  {
   if(d==AT_BUY)  return("BUY");
   if(d==AT_SELL) return("SELL");
   return("HOLD");
  }

//+------------------------------------------------------------------+
color CAtPanel::DirColor(const ENUM_AT_DIR d) const
  {
   if(d==AT_BUY)  return(AT_C_BUY);
   if(d==AT_SELL) return(AT_C_SELL);
   return(AT_C_HOLD);
  }

//+------------------------------------------------------------------+
void CAtPanel::Rect(const string name,const int x,const int y,const int w,const int h,
                    const color bg,const color border)
  {
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,(w>0 ? w : 1));
   ObjectSetInteger(0,name,OBJPROP_YSIZE,(h>0 ? h : 1));
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,0);
  }

//+------------------------------------------------------------------+
void CAtPanel::Text(const string name,const int x,const int y,const string txt,const color clr,
                    const int size,const int anchor,const string font)
  {
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetString(0,name,OBJPROP_FONT,font);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,10);
  }

//+------------------------------------------------------------------+
void CAtPanel::Btn(const string name,const int x,const int y,const int w,const int h,
                   const string txt,const color bg,const color fg)
  {
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetString(0,name,OBJPROP_FONT,"Segoe UI");
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,fg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,AT_C_BORDER);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,20);
  }

//+------------------------------------------------------------------+
//| Refresh all dynamic texts. Called once per second.               |
//+------------------------------------------------------------------+
void CAtPanel::Update(const SATSignal &sig[],const int count,
                      const ENUM_AT_DIR overall,const double overall_conf,const int aligned,
                      const SATAccount &acc,const ENUM_AT_MODE mode,const double risk_pct,
                      const bool ai_ready)
  {
   //--- header
   ObjectSetString(0,AT_PFX"t_acct",OBJPROP_TEXT,
                   StringFormat("Balance %s   Equity %s   Floating %s",
                                DoubleToString(acc.balance,2),
                                DoubleToString(acc.equity,2),
                                DoubleToString(acc.floating,2)));
   ObjectSetString(0,AT_PFX"t_clock",OBJPROP_TEXT,
                   StringFormat("%s   spread %.1f   %s",acc.server_time,acc.spread_points,acc.session_name));

   //--- banner
   string otxt = DirText(overall);
   if(overall==AT_BUY)  otxt += "  ^";
   if(overall==AT_SELL) otxt += "  v";
   ObjectSetString(0,AT_PFX"t_overall",OBJPROP_TEXT,otxt);
   ObjectSetInteger(0,AT_PFX"t_overall",OBJPROP_COLOR,DirColor(overall));
   ObjectSetString(0,AT_PFX"t_conf",OBJPROP_TEXT,
                   StringFormat("CONFIDENCE %.0f%%     TF AGREEMENT %d/%d",overall_conf,aligned,count));

   //--- rows
   for(int i=0;i<AT_MAX_TF;i++)
     {
      string base = AT_PFX"r"+IntegerToString(i);
      if(i>=count)
        {
         for(int c=0;c<AT_COLS;c++)
            ObjectSetString(0,base+IntegerToString(c),OBJPROP_TEXT,"");
         continue;
        }
      string role = "";
      if(sig[i].role==AT_ROLE_BIAS)    role = "M30";
      if(sig[i].role==AT_ROLE_SETUP)   role = "M15";
      if(sig[i].role==AT_ROLE_TRIGGER) role = "M5";

      ObjectSetString(0,base+"0",OBJPROP_TEXT,role);
      ObjectSetString(0,base+"1",OBJPROP_TEXT,DirText(sig[i].dir));
      ObjectSetInteger(0,base+"1",OBJPROP_COLOR,DirColor(sig[i].dir));
      ObjectSetString(0,base+"2",OBJPROP_TEXT,StringFormat("%.0f",sig[i].confidence));
      ObjectSetInteger(0,base+"2",OBJPROP_COLOR,(sig[i].confidence>=70.0 ? AT_C_TEXT : AT_C_MUTED));

      bool has = (sig[i].dir!=AT_HOLD);
      ObjectSetString(0,base+"3",OBJPROP_TEXT,has ? DoubleToString(sig[i].entry,m_digits) : "--");
      ObjectSetString(0,base+"4",OBJPROP_TEXT,has ? DoubleToString(sig[i].sl,m_digits)    : "--");
      ObjectSetString(0,base+"5",OBJPROP_TEXT,has ? DoubleToString(sig[i].tp1,m_digits)   : "--");
      ObjectSetString(0,base+"6",OBJPROP_TEXT,has ? StringFormat("1:%.1f",sig[i].rr)      : "--");
      ObjectSetString(0,base+"7",OBJPROP_TEXT,(has && sig[i].lot>0.0) ? DoubleToString(sig[i].lot,2) : "--");
      ObjectSetString(0,base+"8",OBJPROP_TEXT,StringFormat("%d/%d",sig[i].checks_passed,sig[i].checks_total));
      ObjectSetInteger(0,base+"8",OBJPROP_COLOR,
                       (sig[i].checks_passed==sig[i].checks_total) ? AT_C_BUY :
                       (sig[i].checks_passed>=sig[i].checks_total-2 ? AT_C_ACCENT : AT_C_SELL));
      for(int c=3;c<=7;c++)
         ObjectSetInteger(0,base+IntegerToString(c),OBJPROP_COLOR,AT_C_TEXT);
     }

   //--- status line
   string status = "";
   for(int i=count-1;i>=0;i--)
      if(i<count && sig[i].reason!="")
        {
         status = "Note: "+sig[i].reason;
         break;
        }
   if(status=="")
      status = ai_ready ? "AI model loaded - rule engine + model agree gate active"
                        : "Rule engine active (no AI model loaded)";
   ObjectSetString(0,AT_PFX"t_status",OBJPROP_TEXT,status);
   ObjectSetString(0,AT_PFX"t_stats",OBJPROP_TEXT,acc.stats_line);

   //--- footer
   ObjectSetInteger(0,AT_PFX"btn_auto",OBJPROP_BGCOLOR,(mode==AT_MODE_AUTO) ? AT_C_BTN_ON : AT_C_BTN);
   ObjectSetInteger(0,AT_PFX"btn_signal",OBJPROP_BGCOLOR,(mode==AT_MODE_SIGNAL_ONLY) ? AT_C_BTN_ON : AT_C_BTN);
   ObjectSetString(0,AT_PFX"t_foot",OBJPROP_TEXT,
                   StringFormat("Risk %.2f%%   Day P/L %s   Trades %d   Positions %d   Updated %s",
                                risk_pct,
                                DoubleToString(acc.today_profit,2),
                                acc.day_trades,
                                acc.open_positions,
                                acc.server_time));
   ChartRedraw();
  }

#endif // AUTOTRADER_PANEL_MQH
//+------------------------------------------------------------------+
