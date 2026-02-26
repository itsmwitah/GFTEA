//+------------------------------------------------------------------+
//| PDH_PDL_Breakout_SingleSymbol_MonthlyFilter.mq5                  |
//|                                                                  |
//| - Trades ONE symbol only (chart symbol by default)               |
//| - BuyStop @ PDH, SellStop @ PDL (yesterday levels)               |
//| - Places orders once per day AFTER PlaceHour:PlaceMinute          |
//| - Close & delete pendings at CloseHour:CloseMinute                |
//| - MONTHLY filter (server time)                                   |
//| - ATR FILTER: FIVE SELECTABLE BANDS (each has its own ON/OFF)    |
//| - ATR TF + Period are INPUTS                                     |
//| - Simple CSV logs: time_server,symbol,event,atr_points,profit     |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//=================== SYMBOL ===================
input string __SYMBOL__ = "===== SYMBOL =====";
input string TradeSymbolOverride = ""; // empty = chart symbol (_Symbol)

//=================== RISK ===================
input string __RISK__ = "===== RISK SETTINGS =====";
input double LotSize      = 0.5;
input double BufferPoints = 800;  // points for SL distance from entry
input double RiskReward   = 2.3;   // TP = RR * risk

//=================== ATR FILTER ===================
input string __ATR__ = "===== ATR FILTER =====";
input bool   UseATRFilter      = true;

input string __ATR_CALC__ = "----- ATR Calculation -----";
input ENUM_TIMEFRAMES ATR_TF   = PERIOD_M4;
input int    ATR_Period        = 21;

//=================== INDIVIDUAL ATR VALUES ===================
input string __ATR_VALUES__    = "===== INDIVIDUAL ATR VALUES =====";

input string __ATR_V1__    = "--- ATR Value 1 ---";
input bool   ATR_Value1_Enable = true;
input double ATR_Value1        = 52;

input string __ATR_V2__    = "--- ATR Value 2 ---";
input bool   ATR_Value2_Enable = true;
input double ATR_Value2        = 45;

input string __ATR_V3__    = "--- ATR Value 3 ---";
input bool   ATR_Value3_Enable = true;
input double ATR_Value3        = 67;

input string __ATR_V4__    = "--- ATR Value 4 ---";
input bool   ATR_Value4_Enable = false;
input double ATR_Value4        = 50;

input string __ATR_V5__    = "--- ATR Value 5 ---";
input bool   ATR_Value5_Enable = true;
input double ATR_Value5        = 55;

//=================== ATR RANGE BANDS ===================
input string __ATR_BANDS__ = "===== ATR RANGE BANDS =====";

input string __ATR_BAND1__     = "----- ATR BAND 1 -----";
input bool   ATR_Band1_Enable  = true;
input double ATR_Band1_Low     = 0;
input double ATR_Band1_High    = 42;

input string __ATR_BAND2__     = "----- ATR BAND 2 -----";
input bool   ATR_Band2_Enable  = true;
input double ATR_Band2_Low     = 80;
input double ATR_Band2_High    = 125;

input string __ATR_BAND3__     = "----- ATR BAND 3 -----";
input bool   ATR_Band3_Enable  = true;
input double ATR_Band3_Low     = 180;
input double ATR_Band3_High    = 270;

input string __ATR_BAND4__     = "----- ATR BAND 4 -----";
input bool   ATR_Band4_Enable  = true;
input double ATR_Band4_Low     = 194;
input double ATR_Band4_High    = 198;

//=================== CSV LOG ===================
input string __CSV__ = "===== CSV LOG =====";
input bool   EnableCSVLog = false;
input string CSVFileName  = "Top2_ATR_TradeLog.csv";
input bool   LogSkips     = true;

//=================== SCHEDULE ===================
input string __SCHEDULE__ = "===== SCHEDULE =====";
input int PlaceHour   = 1;
input int PlaceMinute = 6;
input int CloseHour   = 17;
input int CloseMinute = 50;

//=================== MONTHLY FILTER ===================
input string __MONTHS__ = "===== MONTHLY FILTER (SERVER) =====";
// months: 1=January..12=December
input bool Trade_January   = true;
input bool Trade_February  = true;
input bool Trade_March     = true;
input bool Trade_April     = true;
input bool Trade_May       = true;
input bool Trade_June      = true;
input bool Trade_July      = true;
input bool Trade_August    = true;
input bool Trade_September = true;
input bool Trade_October   = true;
input bool Trade_November  = true;
input bool Trade_December  = true;

//=================== MAGIC ===================
input string __MAGIC__ = "===== MAGIC =====";
input int MagicNumber  = 20260214;

//=================== STATE ===================
datetime lastPlacedDay = 0;
bool placedToday = false;

// store ATR used when we placed orders (so we can log it when trade closes)
double   lastPlacedATRPoints = 0.0;
datetime lastPlacedATRDay     = 0;

//=================== HELPERS ===================
string GetTradeSymbol()
{
   string s = TradeSymbolOverride;
   StringReplace(s, " ", "");
   if(s == "") return _Symbol;
   return s;
}

double GetPDH(const string sym){ return iHigh(sym, PERIOD_D1, 1); }
double GetPDL(const string sym){ return iLow(sym,  PERIOD_D1, 1); }

bool IsMonthAllowed(const int month) // 1=Jan..12=Dec
{
   switch(month)
   {
      case 1:  return Trade_January;
      case 2:  return Trade_February;
      case 3:  return Trade_March;
      case 4:  return Trade_April;
      case 5:  return Trade_May;
      case 6:  return Trade_June;
      case 7:  return Trade_July;
      case 8:  return Trade_August;
      case 9:  return Trade_September;
      case 10: return Trade_October;
      case 11: return Trade_November;
      case 12: return Trade_December;
   }
   return true;
}

bool MarketIsOpen(const string sym)
{
   long mode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED) return false;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick)) return false;
   return (tick.bid > 0 && tick.ask > 0);
}

//=================== SIMPLE CSV ===================
bool FileExistsCommon(const string fname)
{
   int h = FileOpen(fname, FILE_READ|FILE_CSV|FILE_COMMON);
   if(h == INVALID_HANDLE) return false;
   FileClose(h);
   return true;
}

void EnsureCSVHeader()
{
   if(!EnableCSVLog) return;

   bool exists = FileExistsCommon(CSVFileName);
   int h = FileOpen(CSVFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   if(!exists || FileSize(h) == 0)
      FileWrite(h, "time_server", "symbol", "event", "atr_points", "profit");

   FileClose(h);
}

void LogCSV(const string sym, const string event, const double atrPts, const double profit)
{
   if(!EnableCSVLog) return;

   int h = FileOpen(CSVFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   FileSeek(h, 0, SEEK_END);

   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   FileWrite(h, ts, sym, event, DoubleToString(atrPts, 2), DoubleToString(profit, 2));

   FileClose(h);
}

//=================== ATR (INPUT TF / PERIOD) ===================
double ATR_Points(const string sym)
{
   if(ATR_Period <= 0) return -1;

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0) return -1;

   int h = iATR(sym, ATR_TF, ATR_Period);
   if(h == INVALID_HANDLE) return -1;

   double buf[];
   double atr = -1;
   if(CopyBuffer(h, 0, 1, 1, buf) > 0)
      atr = buf[0];

   IndicatorRelease(h);

   if(atr <= 0) return -1;
   return atr / point; // ATR in points
}

bool InBand(const double x, double low, double high)
{
   double mn = MathMin(low, high);
   double mx = MathMax(low, high);
   return (x >= mn && x <= mx);
}

bool MatchesValue(const double x, double value)
{
   // Match if within 0.5 points of the target value
   return (MathAbs(x - value) < 0.5);
}

bool ATR_Pass(const double atrPts)
{
   if(atrPts < 0) return false;

   // Check if all filters are OFF
   if(!ATR_Band1_Enable && !ATR_Band2_Enable && !ATR_Band3_Enable && !ATR_Band4_Enable &&
      !ATR_Value1_Enable && !ATR_Value2_Enable && !ATR_Value3_Enable && !ATR_Value4_Enable && !ATR_Value5_Enable)
      return true;

   bool ok1 = false, ok2 = false, ok3 = false, ok4 = false;
   bool okV1 = false, okV2 = false, okV3 = false, okV4 = false, okV5 = false;

   // Check bands
   if(ATR_Band1_Enable) ok1 = InBand(atrPts, ATR_Band1_Low, ATR_Band1_High);
   if(ATR_Band2_Enable) ok2 = InBand(atrPts, ATR_Band2_Low, ATR_Band2_High);
   if(ATR_Band3_Enable) ok3 = InBand(atrPts, ATR_Band3_Low, ATR_Band3_High);
   if(ATR_Band4_Enable) ok4 = InBand(atrPts, ATR_Band4_Low, ATR_Band4_High);

   // Check individual values
   if(ATR_Value1_Enable) okV1 = MatchesValue(atrPts, ATR_Value1);
   if(ATR_Value2_Enable) okV2 = MatchesValue(atrPts, ATR_Value2);
   if(ATR_Value3_Enable) okV3 = MatchesValue(atrPts, ATR_Value3);
   if(ATR_Value4_Enable) okV4 = MatchesValue(atrPts, ATR_Value4);
   if(ATR_Value5_Enable) okV5 = MatchesValue(atrPts, ATR_Value5);

   return (ok1 || ok2 || ok3 || ok4 || okV1 || okV2 || okV3 || okV4 || okV5);
}

//=================== ORDER MANAGEMENT ===================
void CloseAllPositions(const string sym)
{
   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if((int)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == sym)
      {
         trade.PositionClose(ticket);
      }
   }
}

void DeleteAllPendings(const string sym)
{
   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;

      if((int)OrderGetInteger(ORDER_MAGIC) == MagicNumber &&
         OrderGetString(ORDER_SYMBOL) == sym)
      {
         trade.OrderDelete(ticket);
      }
   }
}

bool HaveOurPendings(const string sym)
{
   for(int i = OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;

      if((int)OrderGetInteger(ORDER_MAGIC) == MagicNumber &&
         OrderGetString(ORDER_SYMBOL) == sym)
         return true;
   }
   return false;
}

//=================== STRATEGY: PDH/PDL BREAKOUT ===================
void PlaceOrders(const string sym, const double atrPtsForLog)
{
   if(!MarketIsOpen(sym))
   {
      Print("Market closed/no ticks: ", sym);
      return;
   }

   if(LotSize <= 0 || BufferPoints <= 0 || RiskReward <= 0) return;

   double pdh = GetPDH(sym);
   double pdl = GetPDL(sym);
   if(pdh <= 0 || pdl <= 0)
   {
      Print("PDH/PDL invalid: ", sym, " PDH=", pdh, " PDL=", pdl);
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick)) return;

   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(point <= 0) return;

   double buffer = BufferPoints * point;

   long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist  = (stopsLevel + 5) * point;

   // BUY STOP at/above PDH
   double buyEntry = NormalizeDouble(pdh, digits);
   if(buyEntry <= tick.ask + minDist)
      buyEntry = NormalizeDouble(tick.ask + minDist, digits);

   double buySL   = NormalizeDouble(buyEntry - buffer, digits);
   double buyRisk = buyEntry - buySL;
   double buyTP   = NormalizeDouble(buyEntry + buyRisk * RiskReward, digits);

   // SELL STOP at/below PDL
   double sellEntry = NormalizeDouble(pdl, digits);
   if(sellEntry >= tick.bid - minDist)
      sellEntry = NormalizeDouble(tick.bid - minDist, digits);

   double sellSL   = NormalizeDouble(sellEntry + buffer, digits);
   double sellRisk = sellSL - sellEntry;
   double sellTP   = NormalizeDouble(sellEntry - sellRisk * RiskReward, digits);

   trade.SetExpertMagicNumber(MagicNumber);

   bool b = trade.BuyStop(LotSize, buyEntry, sym, buySL, buyTP);
   if(!b) Print("BuyStop failed (", sym, "): ", GetLastError());

   bool s = trade.SellStop(LotSize, sellEntry, sym, sellSL, sellTP);
   if(!s) Print("SellStop failed (", sym, "): ", GetLastError());

   // Log placement (even if one side fails, we still record the ATR)
   LogCSV(sym, "place", atrPtsForLog, 0.0);

   // store ATR used this day
   lastPlacedATRPoints = atrPtsForLog;
   lastPlacedATRDay = iTime(sym, PERIOD_D1, 0);
}

//=================== TRADE CLOSE LOGGING (PROFIT) ===================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(!EnableCSVLog) return;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0) return;

   if(!HistoryDealSelect(deal)) return;

   string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
   if(sym != GetTradeSymbol()) return;

   long magic = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
   if((int)magic != MagicNumber) return;

   long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT) return; // only log closes

   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_SWAP)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION);

   // use stored ATR for that day if available, otherwise compute current ATR
   datetime today = iTime(sym, PERIOD_D1, 0);
   double atrPts = (today == lastPlacedATRDay && lastPlacedATRPoints > 0) ? lastPlacedATRPoints : ATR_Points(sym);

   LogCSV(sym, "close", atrPts, profit);
}

//=================== INIT ===================
int OnInit()
{
   EnsureCSVHeader();
   return(INIT_SUCCEEDED);
}

//=================== MAIN ===================
void OnTick()
{
   string sym = GetTradeSymbol();
   if(sym == "") return;
   if(!SymbolSelect(sym, true)) return;

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);

   datetime today = iTime(sym, PERIOD_D1, 0);

   // New day reset
   if(today != lastPlacedDay)
   {
      lastPlacedDay = today;
      placedToday = false;
      Print("New day: ", sym, " ", TimeToString(today));
   }

   // End-of-day close & cleanup
   if(t.hour == CloseHour && t.min >= CloseMinute)
   {
      CloseAllPositions(sym);
      DeleteAllPendings(sym);
      return;
   }

   // Place orders ONCE per day after placement time
   if(!placedToday)
   {
      int nowMins   = t.hour * 60 + t.min;
      int placeMins = PlaceHour * 60 + PlaceMinute;

      if(nowMins >= placeMins)
      {
         // MONTHLY filter (replaces weekday filter)
         if(!IsMonthAllowed(t.mon))
         {
            DeleteAllPendings(sym);
            placedToday = true;
            if(LogSkips) LogCSV(sym, "skip_month", 0.0, 0.0);
            return;
         }

         // ATR filter
         double atrPts = ATR_Points(sym);

         if(UseATRFilter && !ATR_Pass(atrPts))
         {
            DeleteAllPendings(sym);
            placedToday = true;
            if(LogSkips) LogCSV(sym, "skip_atr", atrPts, 0.0);
            return;
         }

         // place if no pendings
         if(!HaveOurPendings(sym))
         {
            DeleteAllPendings(sym);
            PlaceOrders(sym, atrPts);
         }

         placedToday = HaveOurPendings(sym);
      }
   }
}
//+------------------------------------------------------------------+
