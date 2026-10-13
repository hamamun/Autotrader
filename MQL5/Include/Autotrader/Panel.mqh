//+------------------------------------------------------------------+
//| Panel.mqh                                                         |
//| Autotrader - panel engine (MAIN + LIVE TRADING).                   |
//| Soft eye-friendly dark-grey panel: drag by its title bar,          |
//| auto-size to the widest row, no truncation.                        |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_PANEL_MQH
#define AUTOTRADER_PANEL_MQH

//--- palette: dark GREY body (never black), soft muted tones.
//--- Only SIGNAL and STATUS rows are coloured (in Autotrader.mq5);
//--- every other row uses the single soft CLR_TEXT below.
#define CLR_BG        C'46,47,51'    // dark grey body - eye friendly
#define CLR_HEADER_BG C'63,64,69'    // slightly lighter grey title/drag bar
#define CLR_TEXT      C'192,197,204' // soft light grey (all normal rows)
#define CLR_TITLE     C'208,212,217' // soft neutral title (still grey, not white)
#define CLR_DIM       C'160,164,170' // soft muted grey (SIGNAL: HOLD)
#define CLR_SEP       C'80,81,87'    // subtle separator on dark grey
#define CLR_GREEN     C'106,191,125' // soft green  (SIGNAL: BUY / ok status)
#define CLR_RED       C'218,118,112' // soft red    (SIGNAL: SELL / alert status)
#define CLR_ORANGE    C'222,174,102' // soft amber  (STATUS)

//--- font sizes (owner rule): everything 12, SIGNAL row 14
#define FONT_SIZE_NORMAL 12
#define FONT_SIZE_SIGNAL 14

//--- glyphs (encoding-proof, via unicode code points)
#define GLYPH_UP    ShortToString(0x25B2)  // triangle up
#define GLYPH_DOWN  ShortToString(0x25BC)  // triangle down
#define GLYPH_DASH  ShortToString(0x2014)  // em dash
#define GLYPH_CHECK ShortToString(0x2713)  // check mark

//+------------------------------------------------------------------+
//| One panel: title/drag bar + fixed rows + separators.              |
//| Two instances = MAIN panel + LIVE TRADING panel.                  |
//+------------------------------------------------------------------+
class CInfoPanel
  {
private:
   long              m_chart;
   int               m_subwin;
   string            m_prefix;        // object-name prefix (unique per panel)
   int               m_x, m_y;        // panel origin (pixels)
   int               m_w, m_h;        // computed size (pixels)
   int               m_header_h;
   int               m_row_h;
   int               m_row_h_signal;
   int               m_sep_h;
   int               m_pad;
   int               m_font;          // FONT_SIZE_NORMAL (12)
   int               m_font_signal;   // FONT_SIZE_SIGNAL (14)
   string            m_font_name;
   int               m_signal_row;    // row drawn at 14pt, or -1
   //--- rows
   int               m_row_count;
   string            m_rows[24];
   color             m_row_colors[24];
   bool              m_sep_after[24];
   int               m_row_font[24];  // font size per row (12, signal=14)
   int               m_row_box[24];   // pixel height of each row box
   int               m_row_text_h[24];// measured pixel height of each row text
   //--- drag state
   bool              m_drag;
   int               m_grab_dx, m_grab_dy;

   int               Scale(const int v) const
     { return (int)MathRound(v * m_scale); }

   double            m_scale;

   string            RowName(const int i) const
     { return m_prefix + "R" + IntegerToString(i); }
   string            SepName(const int i) const
     { return m_prefix + "S" + IntegerToString(i); }
   string            BgName(void)     const { return m_prefix + "BG"; }
   string            HeaderName(void) const { return m_prefix + "HD"; }

   void              PlaceObjects(void);
   bool              InHeader(const int mx, const int my) const;

public:
                     CInfoPanel(void);
                    ~CInfoPanel(void);

   //--- build: rows_count fixed; sep_after[i]=true draws a line under row i
   bool              Create(const long chart_id, const int subwin,
                            const string prefix,
                            const int rows_count,
                            const bool &sep_after[],
                            const int x, const int y);
   void              Destroy(void);

   void              SetTitle(const string title);
   void              SetRow(const int idx, const string text, const color clr);
   void              SetSeparator(const int idx, const bool on);
   void              SetRowFontSize(const int idx, const int size);
   void              SetSignalRow(const int idx);   // row shown at 14pt
   void              Layout(void);          // auto-size + place
   void              Move(const int x, const int y);
   void              SetVisible(const bool vis);

   int               X(void)      const { return m_x; }
   int               Y(void)      const { return m_y; }
   int               Width(void)  const { return m_w; }
   int               Height(void) const { return m_h; }

   //--- returns true if the event was consumed (drag)
   bool              HandleEvent(const int id, const long &lparam,
                                 const double &dparam, const string &sparam);
  };

//+------------------------------------------------------------------+
//| constructor                                                       |
//+------------------------------------------------------------------+
CInfoPanel::CInfoPanel(void)
  {
   m_chart      = 0;
   m_subwin     = 0;
   m_prefix     = "";
   m_x = m_y    = 0;
   m_w = m_h    = 0;
   m_row_count  = 0;
   m_drag       = false;
   m_grab_dx = m_grab_dy = 0;
   m_signal_row = -1;
   //--- soft, rounded, eye-friendly UI font (ships with Windows/MT5).
   //--- (Consolas was monospace and sharp/hard on the eyes.)
   m_font_name  = "Segoe UI";
   m_scale      = 1.0;
   int dpi = (int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   if(dpi > 0)
      m_scale = dpi / 96.0;
   //--- font SIZES are exactly 12 / 14pt as requested; only the pixel
   //--- row heights/padding below are DPI-scaled, never the pt sizes.
   m_font         = FONT_SIZE_NORMAL;
   m_font_signal  = FONT_SIZE_SIGNAL;
   m_header_h     = Scale(34);   // title row lives INSIDE this bar
   m_row_h        = Scale(25);   // room for 12pt text + breathing space
   m_row_h_signal = Scale(31);   // room for 14pt SIGNAL text
   m_sep_h        = Scale(4);
   m_pad          = Scale(12);
   for(int i = 0; i < 24; i++)
     {
      m_rows[i]       = "";
      m_row_colors[i] = CLR_TEXT;
      m_sep_after[i]  = false;
      m_row_font[i]   = m_font;
      m_row_box[i]    = m_row_h;
      m_row_text_h[i] = Scale(16);
     }
  }

//+------------------------------------------------------------------+
//| destructor                                                        |
//+------------------------------------------------------------------+
CInfoPanel::~CInfoPanel(void)
  {
   Destroy();
  }

//+------------------------------------------------------------------+
//| create all panel objects                                          |
//+------------------------------------------------------------------+
bool CInfoPanel::Create(const long chart_id, const int subwin,
                        const string prefix,
                        const int rows_count,
                        const bool &sep_after[],
                        const int x, const int y)
  {
   m_chart     = chart_id;
   m_subwin    = subwin;
   m_prefix    = prefix;
   m_x         = x;
   m_y         = y;
   m_row_count = (int)MathMin(rows_count, 24);
   ObjectsDeleteAll(m_chart, m_prefix);   // clean leftovers on re-init
   for(int i = 0; i < m_row_count; i++)
      m_sep_after[i] = sep_after[i];

   //--- background
   if(!ObjectCreate(m_chart, BgName(), OBJ_RECTANGLE_LABEL, m_subwin, 0, 0))
      return false;
   ObjectSetInteger(m_chart, BgName(), OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_BGCOLOR, CLR_BG);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_COLOR, CLR_SEP);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_WIDTH, 1);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_BACK, false);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_HIDDEN, true);

   //--- header / title bar (the drag handle - title text sits in it)
   if(!ObjectCreate(m_chart, HeaderName(), OBJ_RECTANGLE_LABEL, m_subwin, 0, 0))
      return false;
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_BGCOLOR, CLR_HEADER_BG);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_COLOR, CLR_HEADER_BG);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_BACK, false);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_HIDDEN, true);

   //--- rows
   for(int i = 0; i < m_row_count; i++)
     {
      string name = RowName(i);
      if(!ObjectCreate(m_chart, name, OBJ_LABEL, m_subwin, 0, 0))
         return false;
      ObjectSetInteger(m_chart, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chart, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetString(m_chart, name, OBJPROP_FONT, m_font_name);
      ObjectSetInteger(m_chart, name, OBJPROP_FONTSIZE, m_row_font[i]);
      ObjectSetInteger(m_chart, name, OBJPROP_COLOR, CLR_TEXT);
      ObjectSetInteger(m_chart, name, OBJPROP_BACK, false);
      ObjectSetInteger(m_chart, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chart, name, OBJPROP_HIDDEN, true);
      //--- separator under this row?
      if(m_sep_after[i])
        {
         string sname = SepName(i);
         if(!ObjectCreate(m_chart, sname, OBJ_RECTANGLE_LABEL, m_subwin, 0, 0))
            return false;
         ObjectSetInteger(m_chart, sname, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chart, sname, OBJPROP_BGCOLOR, CLR_SEP);
         ObjectSetInteger(m_chart, sname, OBJPROP_COLOR, CLR_SEP);
         ObjectSetInteger(m_chart, sname, OBJPROP_BORDER_TYPE, BORDER_FLAT);
         ObjectSetInteger(m_chart, sname, OBJPROP_BACK, false);
         ObjectSetInteger(m_chart, sname, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(m_chart, sname, OBJPROP_HIDDEN, true);
        }
     }

   Layout();
   return true;
  }

//+------------------------------------------------------------------+
//| destroy panel objects                                             |
//+------------------------------------------------------------------+
void CInfoPanel::Destroy(void)
  {
   if(m_drag)   // never leave the chart's mouse-scroll locked off
     {
      ChartSetInteger(m_chart, CHART_MOUSE_SCROLL, true);
      m_drag = false;
     }
   if(m_prefix != "")   // chart id 0 = current chart, still delete
      ObjectsDeleteAll(m_chart, m_prefix);
   m_row_count = 0;
  }

//+------------------------------------------------------------------+
//| set header title (drawn inside the title/drag bar, row 0)         |
//+------------------------------------------------------------------+
void CInfoPanel::SetTitle(const string title)
  {
   m_rows[0] = title;
   m_row_colors[0] = CLR_TITLE;
  }

//+------------------------------------------------------------------+
//| set row text + color                                              |
//+------------------------------------------------------------------+
void CInfoPanel::SetRow(const int idx, const string text, const color clr)
  {
   if(idx < 0 || idx >= m_row_count)
      return;
   m_rows[idx]       = text;
   m_row_colors[idx] = clr;
  }

//+------------------------------------------------------------------+
void CInfoPanel::SetSeparator(const int idx, const bool on)
  {
   if(idx < 0 || idx >= m_row_count)
      return;
   m_sep_after[idx] = on;
  }

//+------------------------------------------------------------------+
//| set one row's font size (points)                                  |
//+------------------------------------------------------------------+
void CInfoPanel::SetRowFontSize(const int idx, const int size)
  {
   if(idx < 0 || idx >= 24 || size <= 0)
      return;
   m_row_font[idx] = size;
   if(m_row_count > 0 && ObjectFind(m_chart, RowName(idx)) >= 0)
      ObjectSetInteger(m_chart, RowName(idx), OBJPROP_FONTSIZE, size);
  }

//+------------------------------------------------------------------+
//| mark a row as the SIGNAL row: it alone is drawn at 14pt           |
//+------------------------------------------------------------------+
void CInfoPanel::SetSignalRow(const int idx)
  {
   if(idx < 0 || idx >= 24)
      return;
   if(m_signal_row >= 0 && m_signal_row != idx)
      SetRowFontSize(m_signal_row, m_font);
   m_signal_row = idx;
   SetRowFontSize(idx, m_font_signal);
   if(m_row_count > 0)
      Layout();
  }

//+------------------------------------------------------------------+
//| auto-size to content + place everything                           |
//+------------------------------------------------------------------+
void CInfoPanel::Layout(void)
  {
   if(m_row_count <= 0)
      return;

   //--- Measure EVERY row with the exact font/size it is drawn with.
   //--- TextSetFont must be given -10 x the OBJ_LABEL point size
   //--- (MQL5 docs), otherwise the measured width is far too small
   //--- and the panel ends up narrower than its own text - that was
   //--- the "width does not cover the text" bug. Measuring per row
   //--- also makes the 14pt SIGNAL row widen the panel correctly.
   int  max_w = 0;
   uint tw = 0, th = 0;
   for(int i = 0; i < m_row_count; i++)
     {
      TextSetFont(m_font_name, -m_row_font[i] * 10);
      TextGetSize(m_rows[i], tw, th);
      m_row_text_h[i] = (int)th;
      m_row_box[i]    = (i == 0) ? m_header_h
                                 : ((m_row_font[i] > m_font) ? m_row_h_signal
                                                             : m_row_h);
      if((int)tw > max_w)
         max_w = (int)tw;
     }

   int seps = 0;
   for(int i = 0; i < m_row_count; i++)
      if(m_sep_after[i])
         seps++;

   //--- dynamic width: widest measured row + padding + safety slack,
   //--- so the last glyph can never touch or cross the panel edge.
   m_w = max_w + 2 * m_pad + Scale(14);

   //--- height: title bar (row 0 lives in it) + body rows + separators
   m_h = m_header_h;
   for(int i = 1; i < m_row_count; i++)
      m_h += m_row_box[i];
   m_h += seps * m_sep_h;

   PlaceObjects();
  }

//+------------------------------------------------------------------+
//| place all objects at current origin/size                          |
//+------------------------------------------------------------------+
void CInfoPanel::PlaceObjects(void)
  {
   //--- background + header/title bar
   ObjectSetInteger(m_chart, BgName(), OBJPROP_XDISTANCE, m_x);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_YDISTANCE, m_y);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_XSIZE, m_w);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_YSIZE, m_h);

   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_XDISTANCE, m_x);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_YDISTANCE, m_y);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_XSIZE, m_w);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_YSIZE, m_header_h);

   int y = m_y + m_header_h;   // first body row starts under the bar

   for(int i = 0; i < m_row_count; i++)
     {
      string name = RowName(i);
      ObjectSetString(m_chart, name, OBJPROP_TEXT, m_rows[i]);
      ObjectSetInteger(m_chart, name, OBJPROP_COLOR, m_row_colors[i]);
      ObjectSetInteger(m_chart, name, OBJPROP_FONTSIZE, m_row_font[i]);
      ObjectSetInteger(m_chart, name, OBJPROP_XDISTANCE, m_x + m_pad);
      if(i == 0)
        {
         //--- title centred vertically INSIDE the title/drag bar, so
         //--- the text the user sees (and grabs) IS the drag handle.
         int ty = m_y + (m_header_h - m_row_text_h[0]) / 2;
         ObjectSetInteger(m_chart, name, OBJPROP_YDISTANCE,
                          (ty > m_y) ? ty : m_y);
        }
      else
        {
         ObjectSetInteger(m_chart, name, OBJPROP_YDISTANCE,
                          y + (m_row_box[i] - m_row_text_h[i]) / 2);
         y += m_row_box[i];
        }

      if(m_sep_after[i])
        {
         string sname = SepName(i);
         ObjectSetInteger(m_chart, sname, OBJPROP_XDISTANCE, m_x);
         ObjectSetInteger(m_chart, sname, OBJPROP_YDISTANCE, y);
         ObjectSetInteger(m_chart, sname, OBJPROP_XSIZE, m_w);
         ObjectSetInteger(m_chart, sname, OBJPROP_YSIZE, 1);
         y += m_sep_h;
        }
     }
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
//| move panel                                                        |
//+------------------------------------------------------------------+
void CInfoPanel::Move(const int x, const int y)
  {
   m_x = x;
   m_y = y;
   PlaceObjects();
  }

//+------------------------------------------------------------------+
void CInfoPanel::SetVisible(const bool vis)
  {
   long tf_vis = OBJ_NO_PERIODS;   // hidden on all timeframes
   if(vis)
      tf_vis = OBJ_ALL_PERIODS;    // visible on all timeframes
   ObjectSetInteger(m_chart, BgName(), OBJPROP_TIMEFRAMES, tf_vis);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_TIMEFRAMES, tf_vis);
   for(int i = 0; i < m_row_count; i++)
     {
      ObjectSetInteger(m_chart, RowName(i), OBJPROP_TIMEFRAMES, tf_vis);
      if(m_sep_after[i])
         ObjectSetInteger(m_chart, SepName(i), OBJPROP_TIMEFRAMES, tf_vis);
     }
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
//| header hit test - the title/drag bar across the full panel width  |
//+------------------------------------------------------------------+
bool CInfoPanel::InHeader(const int mx, const int my) const
  {
   return (mx >= m_x && mx <= m_x + m_w && my >= m_y && my <= m_y + m_header_h);
  }

//+------------------------------------------------------------------+
//| Drag handling: press on the title bar + move = drag the panel.    |
//| While dragging, chart mouse-scroll is locked so the chart does    |
//| not slide away under the panel (that made drags feel broken);     |
//| it is restored the moment the button is released.                 |
//+------------------------------------------------------------------+
bool CInfoPanel::HandleEvent(const int id, const long &lparam,
                             const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_MOUSE_MOVE)
      return false;

   int  mx   = (int)lparam;
   int  my   = (int)dparam;
   uint st   = (uint)StringToInteger(sparam);
   bool lmb  = (st & 1) != 0;

   if(!lmb)
     {
      if(m_drag)
        {
         m_drag = false;
         ChartSetInteger(m_chart, CHART_MOUSE_SCROLL, true);
        }
      return false;
     }

   if(!m_drag)
     {
      if(!InHeader(mx, my))
         return false;
      m_drag    = true;
      m_grab_dx = mx - m_x;
      m_grab_dy = my - m_y;
      ChartSetInteger(m_chart, CHART_MOUSE_SCROLL, false);
     }

   Move(mx - m_grab_dx, my - m_grab_dy);
   return true;
  }

#endif // AUTOTRADER_PANEL_MQH
