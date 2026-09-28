//+------------------------------------------------------------------+
//|                                          TrapPyramidPro.mq5      |
//|   v1.50 - XAUUSD M5 | ATR handle | Kalıcı emirler | Filtre sayaç |
//+------------------------------------------------------------------+
#property copyright "KAŞŞŞAR"
#property version   "1.50"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

input group "=== Genel ==="
input double   InpLotBase          = 0.01;      // 1000$ için baz lot (RiskPercent=0 ise)
input double   InpRiskPercent      = 0.0;       // İşlem başı risk % (0 = baz lot yöntemi)
input int      InpMagic            = 202609;
input int      InpSlippage         = 30;
input double   InpCommissionPerLot = 0.0;       // Round-turn komisyon $/lot (brokerdan bak, örn 7)

input group "=== ATR (M5 için) ==="
input int      InpATRPeriod        = 14;
input double   InpTrapATRMult      = 0.6;       // Trap mesafesi = ATR x bu
input double   InpSLATRMult        = 1.0;
input double   InpTPATRMult        = 1.8;       // 0 = TP yok

input group "=== Emir Yönetimi ==="
input int      InpPendingBars      = 6;         // Emir ömrü (bar)
input double   InpRefreshATR       = 0.5;       // Fiyat bu kadar ATR uzaklaşırsa emri yenile

input group "=== Seans ==="
input bool     InpUseSession       = true;
input string   InpSession          = "0800-2000";  // Yalnızca YENİ işlemi engeller

input group "=== Trend Filtresi (opsiyonel) ==="
input bool     InpUseTrend         = false;     // true: sadece trend yönünde tek emir
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_H1;
input int      InpTrendEMA         = 200;

input group "=== Pyramid ==="
input bool     InpEnablePyramid    = true;
input int      InpMaxPyramidBase   = 3;
input int      InpMaxPyramidLimit  = 6;
input double   InpPyramidStepATR   = 0.8;       // Son girişten itibaren adım
input double   InpPyramidLotMult   = 1.0;
input bool     InpPyramidBE        = true;      // Pyramid eklenince eski SL'yi ortalamaya çek

input group "=== Trailing (ATR) ==="
input bool     InpUseTrailing      = false;
input double   InpTrailStartATR    = 1.5;
input double   InpTrailDistATR     = 1.0;

input group "=== Risk ==="
input int      InpMaxSpreadPoints  = 50;        // XAUUSD: 50 puan = 0.50$
input double   InpMaxDailyLoss     = 25.0;      // USD, 0 = kapalı (aşılırsa hepsini kapatır)
input bool     InpOnlyOneDirection = true;

input group "=== Mum Filtresi ==="
input bool     InpUseCandleFilter  = true;
input double   InpMinCandleATR     = 0.2;

//--- global
int      atrHandle = INVALID_HANDLE, emaHandle = INVALID_HANDLE;
datetime lastBarTime = 0;
double   dailyStartBalance = 0, trapRefPrice = 0;
int      lastDay = -1;
bool     dailyStop = false;
int      cntSession=0, cntSpread=0, cntCandle=0, cntDaily=0, cntPlaced=0, cntTrend=0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE) return INIT_FAILED;
   if(InpUseTrend)
   {
      emaHandle = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(emaHandle == INVALID_HANDLE) return INIT_FAILED;
   }

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   lastDay = dt.day;
   Print("TrapPyramidPro v1.50 başlatıldı");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
double GetATR()
{
   double b[1];
   if(CopyBuffer(atrHandle, 0, 1, 1, b) != 1) return 0;
   return b[0];
}

//+------------------------------------------------------------------+
void OnTick()
{
   double atr = GetATR();
   if(atr <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Günlük zarar (her tick, açık pozisyonu kapatır)
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day != lastDay)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDay = dt.day;
      dailyStop = false;
   }
   if(InpMaxDailyLoss > 0 && !dailyStop &&
      AccountInfoDouble(ACCOUNT_EQUITY) <= dailyStartBalance - InpMaxDailyLoss)
   {
      dailyStop = true;
      CloseAllPositions();
      DeleteAllPending();
      Print("Günlük zarar limiti doldu, işlemler kapatıldı.");
   }
   if(dailyStop) return;

   int totalBuy  = CountPositions(POSITION_TYPE_BUY);
   int totalSell = CountPositions(POSITION_TYPE_SELL);
   int totalPos  = totalBuy + totalSell;

   //--- Açık pozisyon yönetimi: seans/spread'den bağımsız, her tick
   if(totalPos > 0)
   {
      if(totalBuy > 0)  DeletePendingByType(ORDER_TYPE_SELL_STOP);
      if(totalSell > 0) DeletePendingByType(ORDER_TYPE_BUY_STOP);
      if(totalPos > 0 && CountPending() > 0 && InpOnlyOneDirection) { /* karşı emir zaten silindi */ }

      if(InpEnablePyramid && totalPos < CalculateDynamicMaxPyramid())
         ManagePyramid(totalBuy, totalSell, ask, bid, atr);
      if(InpUseTrailing) ManageTrailing(atr);
      return;
   }

   //--- Buradan sonrası: yeni işlem/emir mantığı, sadece yeni barda
   if(iTime(_Symbol, PERIOD_CURRENT, 0) == lastBarTime) return;
   lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(InpUseSession && !IsInSession()) { cntSession++; DeleteAllPending(); return; }

   long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPts > InpMaxSpreadPoints) { cntSpread++; return; }

   if(InpUseCandleFilter)
   {
      double rng = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
      if(rng < atr * InpMinCandleATR) { cntCandle++; return; }
   }

   ManageTrapOrders(atr, ask, bid);
}

//+------------------------------------------------------------------+
// Kalıcı tuzak emirleri: sadece süre dolunca/fiyat uzaklaşınca yenile
void ManageTrapOrders(double atr, double ask, double bid)
{
   double mid = (ask + bid) / 2.0;
   int pend = CountPending();

   if(pend > 0)
   {
      bool drifted = MathAbs(mid - trapRefPrice) > atr * InpRefreshATR;
      if(!drifted) return;         // emirler yaşasın
      DeleteAllPending();
   }

   double slDist   = CalculateSLDistance(atr);
   double tpDist   = InpTPATRMult > 0 ? atr * InpTPATRMult : 0;
   double lot      = CalculateLot(slDist);
   double minDist  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point + SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double trapDist = MathMax(atr * InpTrapATRMult, minDist * 1.2);

   bool allowBuy = true, allowSell = true;
   if(InpUseTrend)
   {
      double e[1];
      if(CopyBuffer(emaHandle, 0, 1, 1, e) == 1)
      {
         double c = iClose(_Symbol, InpTrendTF, 1);
         if(c > e[0]) allowSell = false; else allowBuy = false;
         cntTrend++;
      }
   }

   datetime exp = TimeCurrent() + InpPendingBars * PeriodSeconds(PERIOD_CURRENT);

   if(allowBuy)
   {
      double p = NormalizeDouble(ask + trapDist, _Digits);
      if(trade.BuyStop(lot, p, _Symbol, NormalizeDouble(p - slDist, _Digits),
                       tpDist > 0 ? NormalizeDouble(p + tpDist, _Digits) : 0,
                       ORDER_TIME_SPECIFIED, exp, "Trap BuyStop")) cntPlaced++;
   }
   if(allowSell)
   {
      double p = NormalizeDouble(bid - trapDist, _Digits);
      if(trade.SellStop(lot, p, _Symbol, NormalizeDouble(p + slDist, _Digits),
                        tpDist > 0 ? NormalizeDouble(p - tpDist, _Digits) : 0,
                        ORDER_TIME_SPECIFIED, exp, "Trap SellStop")) cntPlaced++;
   }
   trapRefPrice = mid;
}

//+------------------------------------------------------------------+
double CalculateLot(double slDist)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot;
   if(InpRiskPercent > 0)
   {
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0 || tickValue <= 0 || slDist <= 0) return NormalizeLot(InpLotBase);
      double riskMoney = balance * InpRiskPercent / 100.0;
      double lossPerLot = (slDist / tickSize) * tickValue + InpCommissionPerLot;
      lot = riskMoney / lossPerLot;
   }
   else
      lot = (balance / 1000.0) * InpLotBase;
   return NormalizeLot(lot);
}

int CalculateDynamicMaxPyramid()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   int m = (int)MathRound((balance / 1000.0) * InpMaxPyramidBase);
   if(m < 1) m = 1;
   if(m > InpMaxPyramidLimit) m = InpMaxPyramidLimit;
   return m;
}

// Komisyon dahil SL mesafesi (komisyon manuel input)
double CalculateSLDistance(double atr)
{
   double baseSL = atr * InpSLATRMult;
   if(InpCommissionPerLot <= 0) return baseSL;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return baseSL;
   double costInPrice = InpCommissionPerLot / (tickValue / tickSize);
   return MathMin(baseSL + costInPrice, atr * 2.5);
}

//+------------------------------------------------------------------+
bool IsInSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int now = dt.hour * 100 + dt.min;
   int s = (int)StringToInteger(StringSubstr(InpSession, 0, 4));
   int e = (int)StringToInteger(StringSubstr(InpSession, 5, 4));
   if(s < e) return (now >= s && now <= e);
   return (now >= s || now <= e);
}

//+------------------------------------------------------------------+
void ManagePyramid(int totalBuy, int totalSell, double ask, double bid, double atr)
{
   double step = atr * InpPyramidStepATR;
   double slDist = CalculateSLDistance(atr);
   double tpDist = InpTPATRMult > 0 ? atr * InpTPATRMult : 0;

   if(totalBuy > 0 && (!InpOnlyOneDirection || totalSell == 0))
   {
      double last = GetLastEntry(POSITION_TYPE_BUY);
      if(bid >= last + step)
      {
         double avgBefore = GetAveragePrice(POSITION_TYPE_BUY);
         double lot = NormalizeLot(CalculateLot(slDist) * MathPow(InpPyramidLotMult, totalBuy));
         double sl  = NormalizeDouble(ask - slDist, _Digits);
         double tp  = tpDist > 0 ? NormalizeDouble(ask + tpDist, _Digits) : 0;
         if(trade.Buy(lot, _Symbol, ask, sl, tp, "Pyramid Buy"))
            ModifyAll(POSITION_TYPE_BUY, InpPyramidBE ? NormalizeDouble(avgBefore, _Digits) : -1, tp);
      }
   }

   if(totalSell > 0 && (!InpOnlyOneDirection || totalBuy == 0))
   {
      double last = GetLastEntry(POSITION_TYPE_SELL);
      if(ask <= last - step)
      {
         double avgBefore = GetAveragePrice(POSITION_TYPE_SELL);
         double lot = NormalizeLot(CalculateLot(slDist) * MathPow(InpPyramidLotMult, totalSell));
         double sl  = NormalizeDouble(bid + slDist, _Digits);
         double tp  = tpDist > 0 ? NormalizeDouble(bid - tpDist, _Digits) : 0;
         if(trade.Sell(lot, _Symbol, bid, sl, tp, "Pyramid Sell"))
            ModifyAll(POSITION_TYPE_SELL, InpPyramidBE ? NormalizeDouble(avgBefore, _Digits) : -1, tp);
      }
   }
}

//+------------------------------------------------------------------+
void ManageTrailing(double atr)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      long   type = PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY && bid - open >= atr * InpTrailStartATR)
      {
         double n = NormalizeDouble(bid - atr * InpTrailDistATR, _Digits);
         if(n > sl) trade.PositionModify(t, n, tp);
      }
      else if(type == POSITION_TYPE_SELL && open - ask >= atr * InpTrailStartATR)
      {
         double n = NormalizeDouble(ask + atr * InpTrailDistATR, _Digits);
         if(sl == 0 || n < sl) trade.PositionModify(t, n, tp);
      }
   }
}

//+------------------------------------------------------------------+
// newSL < 0 ise SL'ye dokunma. TP hepsine uygulanır.
void ModifyAll(ENUM_POSITION_TYPE type, double newSL, double newTP)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetInteger(POSITION_TYPE) != type) continue;
      double sl = (newSL >= 0) ? newSL : PositionGetDouble(POSITION_SL);
      trade.PositionModify(t, sl, newTP);
   }
}

int CountPositions(ENUM_POSITION_TYPE type)
{
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetInteger(POSITION_TYPE) == type) c++;
   }
   return c;
}

double GetAveragePrice(ENUM_POSITION_TYPE type)
{
   double sp = 0, sl = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         double v = PositionGetDouble(POSITION_VOLUME);
         sp += PositionGetDouble(POSITION_PRICE_OPEN) * v;
         sl += v;
      }
   }
   return sl > 0 ? sp / sl : 0;
}

double GetLastEntry(ENUM_POSITION_TYPE type)
{
   datetime lt = 0; double price = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         datetime pt = (datetime)PositionGetInteger(POSITION_TIME);
         if(pt >= lt) { lt = pt; price = PositionGetDouble(POSITION_PRICE_OPEN); }
      }
   }
   return price;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         trade.PositionClose(t);
   }
}

int CountPending()
{
   int c = 0;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic) c++;
   }
   return c;
}

void DeleteAllPending()
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic)
         trade.OrderDelete(t);
   }
}

void DeletePendingByType(ENUM_ORDER_TYPE type)
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic &&
         OrderGetInteger(ORDER_TYPE) == type)
         trade.OrderDelete(t);
   }
}

double NormalizeLot(double lot)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(mn, MathMin(mx, lot));
   lot = MathRound(lot / st) * st;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("v1.50 kapandı | Kurulan emir: %d | Atlanan bar -> seans:%d spread:%d mum:%d",
               cntPlaced, cntSession, cntSpread, cntCandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
}
//+------------------------------------------------------------------+
