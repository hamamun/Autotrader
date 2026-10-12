//+------------------------------------------------------------------+
//|                                               RiskManager.mqh    |
//|   Position sizing, trade guards and order execution.             |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_RISK_MANAGER_MQH
#define AUTOTRADER_RISK_MANAGER_MQH

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include "Types.mqh"

class CAtRiskManager
  {
private:
   CTrade        m_trade;
   CPositionInfo m_pos;
   CSymbolInfo   m_sym;
   string        m_symbol;
   double        m_risk_pct;
   double        m_max_daily_loss_pct;
   int           m_max_trades_day;
   int           m_max_open;
   double        m_day_start_balance;
   int           m_day;
   int           m_day_trades;
   double        m_day_realized;
   bool          m_use_breakeven;
   double        m_be_trigger_r;
   bool          m_use_trailing;
   double        m_trail_atr_mult;

public:
   void     Init(const string symbol,const double risk_pct,const double max_daily_loss_pct,
                 const int max_trades_day,const int max_open,
                 const bool use_breakeven,const double be_trigger_r,
                 const bool use_trailing,const double trail_atr_mult);
   void     NewDay(const int day);

   double   CalcLot(const double entry,const double sl);
   double   MinStopDistance() const;
   bool     NormalizeLevels(const ENUM_AT_DIR dir,double &entry,double &sl,double &tp) const;

   bool     DailyLossHit() const;
   bool     CanOpen() const;
   void     RegisterTrade();
   double   TodayProfit() const;
   int      TodayTrades() const { return m_day_trades; }
   double   FloatingPL() const;
   int      OpenCount() const;
   bool     OpenMarket(const ENUM_AT_DIR dir,const double lot,const double sl,const double tp,
                       const string comment);
   void     CloseAll(const string symbol);
   void     ManageOpenPositions(const double atr);
  };

//+------------------------------------------------------------------+
void CAtRiskManager::Init(const string symbol,const double risk_pct,const double max_daily_loss_pct,
                          const int max_trades_day,const int max_open,
                          const bool use_breakeven,const double be_trigger_r,
                          const bool use_trailing,const double trail_atr_mult)
  {
   m_symbol            = symbol;
   m_risk_pct          = risk_pct;
   m_max_daily_loss_pct= max_daily_loss_pct;
   m_max_trades_day    = max_trades_day;
   m_max_open          = max_open;
   m_use_breakeven     = use_breakeven;
   m_be_trigger_r      = be_trigger_r;
   m_use_trailing      = use_trailing;
   m_trail_atr_mult    = trail_atr_mult;

   m_trade.SetExpertMagicNumber(20260101);
   m_trade.SetDeviationInPoints(20);
   m_trade.SetTypeFillingBySymbol(symbol);
   m_trade.LogLevel(LOG_LEVEL_ERRORS);
   m_sym.Name(symbol);
   m_sym.RefreshRates();

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   m_day              = dt.day;
   m_day_trades       = 0;
   m_day_realized     = 0.0;
   m_day_start_balance= AccountInfoDouble(ACCOUNT_BALANCE);
  }

//+------------------------------------------------------------------+
void CAtRiskManager::NewDay(const int day)
  {
   m_day               = day;
   m_day_trades        = 0;
   m_day_realized      = 0.0;
   m_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
  }

//+------------------------------------------------------------------+
//| Smallest stop the broker allows (stops level + spread buffer)    |
//+------------------------------------------------------------------+
double CAtRiskManager::MinStopDistance() const
  {
   double point  = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
   long   stops  = SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze = SymbolInfoInteger(m_symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   long   need   = MathMax(stops,freeze);
   return(need*point);
  }

//+------------------------------------------------------------------+
//| Push SL/TP out if they are inside the broker stop distance       |
//+------------------------------------------------------------------+
bool CAtRiskManager::NormalizeLevels(const ENUM_AT_DIR dir,double &entry,double &sl,double &tp) const
  {
   double min_dist = MinStopDistance();
   if(min_dist<=0.0)
      return(true);
   if(dir==AT_BUY)
     {
      if(entry-sl<min_dist)
         sl = entry-min_dist;
      if(tp-entry<min_dist)
         tp = entry+min_dist;
     }
   else
      if(dir==AT_SELL)
        {
         if(sl-entry<min_dist)
            sl = entry+min_dist;
         if(entry-tp<min_dist)
            tp = entry-min_dist;
        }
   int digits = (int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
   sl = NormalizeDouble(sl,digits);
   tp = NormalizeDouble(tp,digits);
   return(true);
  }

//+------------------------------------------------------------------+
//| Risk based lot size                                              |
//+------------------------------------------------------------------+
double CAtRiskManager::CalcLot(const double entry,const double sl)
  {
   double point    = SymbolInfoDouble(m_symbol,SYMBOL_POINT);
   double tick_val = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
   double min_lot  = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);

   if(point<=0.0)
      return(0.0);
   if(tick_sz<=0.0)
      tick_sz = point;
   if(lot_step<=0.0)
      lot_step = 0.01;

   double dist = MathAbs(entry-sl);
   if(dist<=0.0)
      return(0.0);

   double risk_money = AccountInfoDouble(ACCOUNT_BALANCE) * m_risk_pct/100.0;
   double value_per_point_per_lot = tick_val * (point/tick_sz);   // account currency
   double loss_per_lot = (dist/point) * value_per_point_per_lot;
   if(loss_per_lot<=0.0)
      return(0.0);

   double lot = risk_money/loss_per_lot;
   lot = MathFloor(lot/lot_step)*lot_step;
   lot = MathMax(min_lot,MathMin(max_lot,lot));

   int digits = 2;
   if(lot_step>=1.0)      digits = 0;
   else if(lot_step>=0.1) digits = 1;
   return(NormalizeDouble(lot,digits));
  }

//+------------------------------------------------------------------+
bool CAtRiskManager::DailyLossHit() const
  {
   if(m_max_daily_loss_pct<=0.0)
      return(false);
   double limit = m_day_start_balance*m_max_daily_loss_pct/100.0;
   return((m_day_realized + FloatingPL()) <= -MathAbs(limit));
  }

//+------------------------------------------------------------------+
bool CAtRiskManager::CanOpen() const
  {
   if(DailyLossHit())
      return(false);
   if(m_max_trades_day>0 && m_day_trades>=m_max_trades_day)
      return(false);
   if(m_max_open>0 && OpenCount()>=m_max_open)
      return(false);
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return(false);
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
void CAtRiskManager::RegisterTrade()
  {
   m_day_trades++;
  }

//+------------------------------------------------------------------+
double CAtRiskManager::FloatingPL() const
  {
   double pl = 0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(!m_pos.SelectByIndex(i))
         continue;
      if(m_pos.Symbol()!=m_symbol)
         continue;
      pl += m_pos.Profit()+m_pos.Swap();
     }
   return(pl);
  }

//+------------------------------------------------------------------+
double CAtRiskManager::TodayProfit() const
  {
   return(m_day_realized+FloatingPL());
  }

//+------------------------------------------------------------------+
int CAtRiskManager::OpenCount() const
  {
   int n = 0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(!m_pos.SelectByIndex(i))
         continue;
      if(m_pos.Symbol()==m_symbol)
         n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
bool CAtRiskManager::OpenMarket(const ENUM_AT_DIR dir,const double lot,const double sl,
                                const double tp,const string comment)
  {
   if(lot<=0.0)
      return(false);
   m_sym.RefreshRates();
   bool ok = false;
   if(dir==AT_BUY)
      ok = m_trade.Buy(lot,m_symbol,m_sym.Ask(),sl,tp,comment);
   else
      if(dir==AT_SELL)
         ok = m_trade.Sell(lot,m_symbol,m_sym.Bid(),sl,tp,comment);
   if(!ok)
      PrintFormat("[Autotrader] order failed: %d %s",m_trade.ResultRetcode(),m_trade.ResultRetcodeDescription());
   return(ok);
  }

//+------------------------------------------------------------------+
void CAtRiskManager::CloseAll(const string symbol)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(!m_pos.SelectByIndex(i))
         continue;
      if(m_pos.Symbol()!=symbol)
         continue;
      m_trade.PositionClose(m_pos.Ticket());
     }
  }

//+------------------------------------------------------------------+
//| Break even + ATR trailing stop on open positions                 |
//+------------------------------------------------------------------+
void CAtRiskManager::ManageOpenPositions(const double atr)
  {
   if(atr<=0.0)
      return;
   int digits = (int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(!m_pos.SelectByIndex(i))
         continue;
      if(m_pos.Symbol()!=m_symbol)
         continue;

      double open   = m_pos.PriceOpen();
      double sl     = m_pos.StopLoss();
      double tp     = m_pos.TakeProfit();
      double price  = (m_pos.PositionType()==POSITION_TYPE_BUY) ? m_sym.Bid() : m_sym.Ask();
      double risk   = MathAbs(open-sl);
      if(risk<=0.0)
         continue;
      double r_mult = (m_pos.PositionType()==POSITION_TYPE_BUY) ? (price-open)/risk : (open-price)/risk;

      double new_sl = sl;

      //--- move to break even after X R
      if(m_use_breakeven && r_mult>=m_be_trigger_r)
        {
         if(m_pos.PositionType()==POSITION_TYPE_BUY && (sl<open || sl==0.0))
            new_sl = open;
         if(m_pos.PositionType()==POSITION_TYPE_SELL && (sl>open || sl==0.0))
            new_sl = open;
        }

      //--- ATR trail
      if(m_use_trailing)
        {
         double trail = atr*m_trail_atr_mult;
         if(m_pos.PositionType()==POSITION_TYPE_BUY)
           {
            double cand = price-trail;
            if(cand>new_sl)
               new_sl = cand;
           }
         else
           {
            double cand = price+trail;
            if(cand<new_sl || new_sl==0.0)
               new_sl = cand;
           }
        }

      new_sl = NormalizeDouble(new_sl,digits);
      if(MathAbs(new_sl-sl)>SymbolInfoDouble(m_symbol,SYMBOL_POINT) &&
         ((m_pos.PositionType()==POSITION_TYPE_BUY  && new_sl>sl) ||
          (m_pos.PositionType()==POSITION_TYPE_SELL && (new_sl<sl || sl==0.0))))
         m_trade.PositionModify(m_pos.Ticket(),new_sl,tp);
     }
  }

#endif // AUTOTRADER_RISK_MANAGER_MQH
//+------------------------------------------------------------------+
