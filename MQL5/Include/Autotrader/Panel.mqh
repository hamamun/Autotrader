//+------------------------------------------------------------------+
//| Panel.mqh                                                         |
//| Autotrader - panel engine (MAIN + LIVE TRADING).                   |
//| Pixel-faithful dark panel: drag by header, auto-size, no truncate. |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_PANEL_MQH
#define AUTOTRADER_PANEL_MQH

//--- palette (matches owner's reference screenshot)
#define CLR_BG        C'18,18,18'
#define CLR_HEADER_BG C'42,42,42'
#define CLR_TEXT      C'214,214,214'
#define CLR_TITLE     C'236,236,236'
#define CLR_DIM       C'150,150,150'
#define CLR_SEP       C'72,72,72'
#define CLR_GREEN     C'52,190,100'
#define CLR_RED       C'226,76,76'
#define CLR_ORANGE    C'230,160,50'

//--- glyphs (encoding-proof, via unicode code points)
#define GLYPH_UP    ShortToString(0x25B2)  // triangle up
#define GLYPH_DOWN  ShortToString(0x25BC)  // triangle down
#define GLYPH_DASH  ShortToString(0x2014)  // em dash
#define GLYPH_CHECK ShortToString(0x2713)  // check mark

//+------------------------------------------------------------------+
//| One panel: header + fixed rows + separators.                      |
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
   int               m_sep_h;
   int               m_pad;
   int               m_font;
   string            m_font_name;
   //--- rows
   int               m_row_count;
   string            m_rows[24];
   color             m_row_colors[24];
   bool              m_sep_after[24];
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
   m_font_name  = "Consolas";
   m_scale      = 1.0;
   int dpi = (int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   if(dpi > 0)
      m_scale = dpi / 96.0;
   m_font      = (int)MathRound(9 * m_scale);
   m_header_h  = (int)MathRound(22 * m_scale);
   m_row_h     = (int)MathRound(18 * m_scale);
   m_sep_h     = (int)MathRound(3 * m_scale);
   m_pad       = (int)MathRound(10 * m_scale);
   for(int i = 0; i < 24; i++)
     {
      m_rows[i]       = "";
      m_row_colors[i] = CLR_TEXT;
      m_sep_after[i]  = false;
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

   //--- header (drag bar)
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
      ObjectSetInteger(m_chart, name, OBJPROP_FONTSIZE, m_font);
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
   if(m_chart != 0 && m_prefix != "")
      ObjectsDeleteAll(m_chart, m_prefix);
   m_row_count = 0;
  }

//+------------------------------------------------------------------+
//| set header title                                                  |
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
//| auto-size to content + place everything                           |
//+------------------------------------------------------------------+
void CInfoPanel::Layout(void)
  {
   //--- measure widest text (title + rows) -> panel never truncates
   TextSetFont(m_font_name, m_font, 0);   // measure with the same font we draw with
   int  max_w = 0;
   uint tw = 0, th = 0;
   for(int i = 0; i < m_row_count; i++)
     {
      TextGetSize(m_rows[i], tw, th);
      if((int)tw > max_w)
         max_w = (int)tw;
     }

   int seps = 0;
   for(int i = 0; i < m_row_count; i++)
      if(m_sep_after[i])
         seps++;

   m_w = max_w + 2 * m_pad;
   m_h = m_header_h + m_row_count * m_row_h + seps * m_sep_h;

   PlaceObjects();
  }

//+------------------------------------------------------------------+
//| place all objects at current origin/size                          |
//+------------------------------------------------------------------+
void CInfoPanel::PlaceObjects(void)
  {
   //--- background + header
   ObjectSetInteger(m_chart, BgName(), OBJPROP_XDISTANCE, m_x);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_YDISTANCE, m_y);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_XSIZE, m_w);
   ObjectSetInteger(m_chart, BgName(), OBJPROP_YSIZE, m_h);

   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_XDISTANCE, m_x);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_YDISTANCE, m_y);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_XSIZE, m_w);
   ObjectSetInteger(m_chart, HeaderName(), OBJPROP_YSIZE, m_header_h);

   //--- rows
   int y = m_y + m_header_h;
   for(int i = 0; i < m_row_count; i++)
     {
      string name = RowName(i);
      ObjectSetString(m_chart, name, OBJPROP_TEXT, m_rows[i]);
      ObjectSetInteger(m_chart, name, OBJPROP_COLOR, m_row_colors[i]);
      ObjectSetInteger(m_chart, name, OBJPROP_XDISTANCE, m_x + m_pad);
      ObjectSetInteger(m_chart, name, OBJPROP_YDISTANCE,
                       y + (m_row_h - (int)MathRound(13 * m_scale)) / 2);
      y += m_row_h;

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
//| header hit test                                                   |
//+------------------------------------------------------------------+
bool CInfoPanel::InHeader(const int mx, const int my) const
  {
   return (mx >= m_x && mx <= m_x + m_w && my >= m_y && my <= m_y + m_header_h);
  }

//+------------------------------------------------------------------+
//| drag handling: press on header + move = drag panel                 |
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
      m_drag = false;
      return false;
     }

   if(!m_drag)
     {
      if(!InHeader(mx, my))
         return false;
      m_drag    = true;
      m_grab_dx = mx - m_x;
      m_grab_dy = my - m_y;
     }

   Move(mx - m_grab_dx, my - m_grab_dy);
   return true;
  }

#endif // AUTOTRADER_PANEL_MQH
