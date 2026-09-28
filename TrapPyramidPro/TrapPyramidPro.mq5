//+------------------------------------------------------------------+
//|                                          TrapPyramidPro.mq5      |
//|   v1.60 - XAUUSD M5 | Hata düzeltmeleri | Giriş modu | Filtreler  |
//+------------------------------------------------------------------+
//| v1.60 değişiklikleri                                              |
//|  DÜZELTME  Pozisyon kapanınca aynı bar içinde anında yeni tuzak   |
//|            kuruluyordu (lastBarTime pozisyon açıkken hiç          |
//|            güncellenmiyordu). Bar takibi artık her tick yapılır,  |
//|            grup kapanınca en az InpCooldownBars beklenir.         |
//|  DÜZELTME  Pyramid "BE" gerçek başabaş değildi: ortak SL eski     |
//|            ortalamaya çekiliyordu, n pozisyonlu grupta SL'e       |
//|            dönüşte zarar ~ n x adım / 2 idi (her eklemede büyür). |
//|            Ortak SL artık grubun toplam zararını                  |
//|            InpPyramidRiskR x (ilk işlem riski) ile sınırlar       |
//|            (0 = komisyon dahil gerçek başabaş). SL asla geri      |
//|            çekilmez (trailing'in kazandırdığını bozmaz).          |
//|  DÜZELTME  Pyramid adımı "en son açılan"a göre değil (saniye      |
//|            çözünürlüğünde eşitlik sorunu), en uç girişe göre.     |
//|  DÜZELTME  Spread açılınca bekleyen emirler her tick silinir      |
//|            (eskiden sadece yeni emir kurulurken bakılıyordu).     |
//|  DÜZELTME  InpRefreshATR = 0 artık "yenileme kapalı" demek.       |
//|  DÜZELTME  Broker süreli emre izin vermiyorsa GTC + EA'nın kendi  |
//|            süre yönetimi. Fiyatlar tick size'a göre normalize.    |
//|  YENİ      InpEntryMode: Stop tuzak (v1.50) / Kanal kırılımı /    |
//|            Limit fade (düşükten al, yüksekten sat).               |
//|  YENİ      ADX rejim filtresi, ATR/spread filtresi, günlük en     |
//|            fazla işlem grubu sayısı.                              |
//|  DEĞİŞTİ   Günlük zarar limiti bakiyenin %'si (2.5% = 1000$'da 25$)|
//|                                                                   |
//| Ayna testi (kaybın kaynağını ayırmak için; Pyramid = false,       |
//| InpMaxDailyLossPct = 0, aynı tarih aralığı ve modelleme):         |
//|   A) Mod = Stop tuzak, SL = 1.0, TP = 1.8                         |
//|   B) Mod = Limit fade, SL = 1.8, TP = 1.0  (A'nın ters işlemi)    |
//|   Brüt yön etkisi ~ (A - B) / 2, maliyet (spread+kom.) ~ -(A + B)/2|
//+------------------------------------------------------------------+
#property copyright "KAŞŞŞAR"
#property version   "1.60"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

enum ENUM_ENTRY_MODE
{
   ENTRY_STOP_TRAP   = 0,   // Kırılım: fiyat ± mesafe, Stop emir (v1.50)
   ENTRY_RANGE_BREAK = 1,   // Kırılım: son N bar tepe/dip, Stop emir
   ENTRY_LIMIT_FADE  = 2    // Tersine: fiyat ± mesafe, Limit emir
};

input group "=== Genel ==="
input double   InpLotBase          = 0.01;      // 1000$ için baz lot (RiskPercent=0 ise)
input double   InpRiskPercent      = 0.0;       // İşlem başı risk % (0 = baz lot yöntemi)
input int      InpMagic            = 202609;
input int      InpSlippage         = 30;
input double   InpCommissionPerLot = 0.0;       // Round-turn komisyon $/lot (brokerdan bak, örn 7)

input group "=== Giriş Modu ==="
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_STOP_TRAP;
input int      InpRangeBars        = 12;        // Kanal kırılımı: geriye bakılan bar sayısı
input double   InpRangeBufferATR   = 0.1;       // Kanal kırılımı: tepe/dip ötesine tampon (ATR x)
input double   InpRangeMaxATR      = 3.0;       // Kanal kırılımı: kanal genişliği en fazla ATR x (0 = kapalı)

input group "=== ATR (M5 için) ==="
input int      InpATRPeriod        = 14;
input double   InpTrapATRMult      = 0.6;       // Tuzak mesafesi = ATR x bu (Stop tuzak / Limit fade)
input double   InpSLATRMult        = 1.0;
input double   InpTPATRMult        = 1.8;       // 0 = TP yok

input group "=== Emir Yönetimi ==="
input int      InpPendingBars      = 6;         // Emir ömrü (bar)
input double   InpRefreshATR       = 0.5;       // Fiyat bu kadar ATR uzaklaşırsa emri yenile (0 = kapalı)
input int      InpCooldownBars     = 1;         // Grup kapandıktan sonra beklenecek bar (en az 1)
input int      InpMaxGroupsPerDay  = 0;         // Günde en fazla yeni işlem grubu (0 = sınırsız)

input group "=== Seans ==="
input bool     InpUseSession       = true;
input string   InpSession          = "0800-2000";  // Sunucu saati. Yalnızca YENİ işlemi engeller

input group "=== Trend Filtresi (opsiyonel) ==="
input bool     InpUseTrend         = false;     // true: sadece trend yönünde tek emir
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_H1;
input int      InpTrendEMA         = 200;

input group "=== Rejim Filtresi: ADX (opsiyonel) ==="
input bool     InpUseADX           = false;
input ENUM_TIMEFRAMES InpADXTF     = PERIOD_M15;
input int      InpADXPeriod        = 14;
input double   InpADXMinBreakout   = 25.0;      // Kırılım modlarında ADX en az bu olmalı
input double   InpADXMaxFade       = 20.0;      // Fade modunda ADX en fazla bu olmalı

input group "=== Pyramid ==="
input bool     InpEnablePyramid    = true;
input int      InpMaxPyramidBase   = 3;
input int      InpMaxPyramidLimit  = 6;
input double   InpPyramidStepATR   = 0.8;       // En uç girişten itibaren adım
input double   InpPyramidLotMult   = 1.0;
input bool     InpPyramidBE        = true;      // Ekleme olunca grubun ortak SL'sini güncelle
input double   InpPyramidRiskR     = 1.0;       // Ortak SL'de grubun max zararı (ilk risk x), 0 = gerçek başabaş

input group "=== Trailing (ATR) ==="
input bool     InpUseTrailing      = false;
input double   InpTrailStartATR    = 1.5;
input double   InpTrailDistATR     = 1.0;

input group "=== Risk ==="
input int      InpMaxSpreadPoints  = 50;        // XAUUSD: 50 puan = 0.50$ (0 = kapalı)
input double   InpMinATRtoSpread   = 0.0;       // ATR en az spread'in kaç katı olsun (0 = kapalı)
input double   InpMaxDailyLossPct  = 2.5;       // Bakiyenin %'si, 0 = kapalı (aşılırsa hepsini kapatır)
input bool     InpOnlyOneDirection = true;

input group "=== Mum Filtresi ==="
input bool     InpUseCandleFilter  = true;
input double   InpMinCandleATR     = 0.2;

//--- global
int      atrHandle = INVALID_HANDLE, emaHandle = INVALID_HANDLE, adxHandle = INVALID_HANDLE;
datetime lastBarTime = 0, cooldownUntil = 0, trapPlacedTime = 0;
double   dailyStartBalance = 0, trapRefPrice = 0;
int      lastDay = -1, groupsToday = 0, sessStart = 0, sessEnd = 0;
bool     dailyStop = false, inGroup = false;
int      cntSession=0, cntSpread=0, cntCandle=0, cntDaily=0, cntPlaced=0, cntCooldown=0,
         cntMaxDay=0, cntRegime=0, cntATRSpread=0, cntRange=0, cntSpreadDel=0,
         cntGroups=0, cntPyramid=0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpUseSession)
   {
      if(StringLen(InpSession) < 9)
      {
         Print("InpSession HHMM-HHMM biçiminde olmalı, örn 0800-2000");
         return INIT_PARAMETERS_INCORRECT;
      }
      sessStart = (int)StringToInteger(StringSubstr(InpSession, 0, 4));
      sessEnd   = (int)StringToInteger(StringSubstr(InpSession, 5, 4));
   }
   if(InpEntryMode == ENTRY_RANGE_BREAK && InpRangeBars < 2)
   {
      Print("Kanal kırılımı için InpRangeBars en az 2 olmalı");
      return INIT_PARAMETERS_INCORRECT;
   }

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE) return INIT_FAILED;
   if(InpUseTrend)
   {
      emaHandle = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(emaHandle == INVALID_HANDLE) return INIT_FAILED;
   }
   if(InpUseADX)
   {
      adxHandle = iADX(_Symbol, InpADXTF, InpADXPeriod);
      if(adxHandle == INVALID_HANDLE) return INIT_FAILED;
   }

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   lastDay = dt.day;
   PrintFormat("TrapPyramidPro v1.60 başlatıldı | Mod: %s", EnumToString(InpEntryMode));
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

   //--- Bar takibi her tick (v1.50'de pozisyon açıkken güncellenmiyordu)
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool     newBar  = (barTime != lastBarTime);
   if(newBar) lastBarTime = barTime;

   //--- Gün değişimi
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day != lastDay)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDay     = dt.day;
      dailyStop   = false;
      groupsToday = 0;
   }

   //--- Günlük zarar (her tick, açık pozisyonu kapatır)
   if(InpMaxDailyLossPct > 0 && !dailyStop &&
      AccountInfoDouble(ACCOUNT_EQUITY) <= dailyStartBalance * (1.0 - InpMaxDailyLossPct / 100.0))
   {
      dailyStop = true;
      inGroup   = false;
      cntDaily++;
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
      if(!inGroup) { inGroup = true; groupsToday++; cntGroups++; }
      if(CountPending() > 0) DeleteAllPending();          // OCO: karşı emri iptal et

      if(InpEnablePyramid && totalPos < CalculateDynamicMaxPyramid())
         ManagePyramid(totalBuy, totalSell, ask, bid, atr);
      if(InpUseTrailing) ManageTrailing(atr);
      return;
   }

   //--- Grup az önce kapandı: aynı barda anında yeni tuzak kurma, bekle
   if(inGroup)
   {
      inGroup = false;
      int cd = InpCooldownBars < 1 ? 1 : InpCooldownBars;
      cooldownUntil = barTime + cd * PeriodSeconds(PERIOD_CURRENT);
   }

   //--- Bekleyen emir varken spread açılırsa emirleri çek (her tick)
   long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(InpMaxSpreadPoints > 0 && spreadPts > InpMaxSpreadPoints && CountPending() > 0)
   {
      DeleteAllPending();
      cntSpreadDel++;
   }

   //--- Buradan sonrası: yeni işlem/emir mantığı, sadece yeni barda
   if(!newBar) return;
   if(barTime < cooldownUntil) { cntCooldown++; return; }
   if(InpUseSession && !IsInSession()) { cntSession++; DeleteAllPending(); return; }
   if(InpMaxGroupsPerDay > 0 && groupsToday >= InpMaxGroupsPerDay) { cntMaxDay++; DeleteAllPending(); return; }
   if(InpMaxSpreadPoints > 0 && spreadPts > InpMaxSpreadPoints) { cntSpread++; return; }
   if(InpMinATRtoSpread > 0 && atr < spreadPts * _Point * InpMinATRtoSpread)
   {
      cntATRSpread++; DeleteAllPending(); return;
   }

   if(InpUseCandleFilter)
   {
      double rng = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
      if(rng < atr * InpMinCandleATR) { cntCandle++; return; }
   }

   if(!RegimeOK()) { cntRegime++; DeleteAllPending(); return; }

   ManageEntryOrders(atr, ask, bid);
}

//+------------------------------------------------------------------+
// Kalıcı giriş emirleri: süre dolunca / fiyat uzaklaşınca yenile.
// Kanal modunda seviyeler bar bar değiştiği için her yeni barda yeniden kurulur.
void ManageEntryOrders(double atr, double ask, double bid)
{
   double mid = (ask + bid) / 2.0;

   if(CountPending() > 0)
   {
      long life    = (long)InpPendingBars * PeriodSeconds(PERIOD_CURRENT);
      bool expired = (TimeCurrent() - trapPlacedTime) >= life;
      bool drifted = InpRefreshATR > 0 && MathAbs(mid - trapRefPrice) > atr * InpRefreshATR;
      if(InpEntryMode != ENTRY_RANGE_BREAK && !expired && !drifted) return;   // emirler yaşasın
      DeleteAllPending();
   }

   double spread   = ask - bid;
   double stopLvl  = StopLevelPrice();
   double minDist  = stopLvl + spread;
   double slDist   = MathMax(CalculateSLDistance(atr), stopLvl + _Point);
   double tpDist   = InpTPATRMult > 0 ? MathMax(atr * InpTPATRMult, stopLvl + _Point) : 0;
   double lot      = CalculateLot(slDist);
   double trapDist = MathMax(atr * InpTrapATRMult, minDist * 1.2);

   bool allowBuy = true, allowSell = true;
   if(InpUseTrend)
   {
      double e[1];
      if(CopyBuffer(emaHandle, 0, 1, 1, e) != 1) return;    // trend bilinmiyorsa emir yok
      double c = iClose(_Symbol, InpTrendTF, 1);
      if(c > e[0]) allowSell = false; else allowBuy = false;
   }

   bool   useStop = (InpEntryMode != ENTRY_LIMIT_FADE);
   double buyPx = 0, sellPx = 0;
   if(InpEntryMode == ENTRY_STOP_TRAP)
   {
      buyPx  = ask + trapDist;          // fiyat yükselirse al (kırılım)
      sellPx = bid - trapDist;          // fiyat düşerse sat
   }
   else if(InpEntryMode == ENTRY_LIMIT_FADE)
   {
      buyPx  = ask - trapDist;          // fiyat düşerse al  (düşükten al)
      sellPx = bid + trapDist;          // fiyat yükselirse sat (yüksekten sat)
   }
   else
   {
      int hi = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpRangeBars, 1);
      int lo = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpRangeBars, 1);
      if(hi < 0 || lo < 0) return;
      double hh = iHigh(_Symbol, PERIOD_CURRENT, hi);
      double ll = iLow(_Symbol, PERIOD_CURRENT, lo);
      if(InpRangeMaxATR > 0 && hh - ll > atr * InpRangeMaxATR) { cntRange++; return; }   // sıkışma yok
      double buf = atr * InpRangeBufferATR;
      buyPx  = hh + buf + spread;       // grafik BID çizer, Buy Stop ASK ile tetiklenir
      sellPx = ll - buf;
      if(buyPx  < ask + minDist) allowBuy  = false;   // fiyat zaten kanal dışında: kovalama
      if(sellPx > bid - minDist) allowSell = false;
   }

   ENUM_ORDER_TYPE_TIME tt = ORDER_TIME_GTC;
   datetime exp = 0;
   GetExpiry(tt, exp);

   bool placed = false;
   if(allowBuy)
   {
      double p  = NormalizePrice(buyPx);
      double sl = NormalizePrice(p - slDist);
      double tp = tpDist > 0 ? NormalizePrice(p + tpDist) : 0;
      bool ok = useStop ? trade.BuyStop(lot, p, _Symbol, sl, tp, tt, exp, "Trap BuyStop")
                        : trade.BuyLimit(lot, p, _Symbol, sl, tp, tt, exp, "Fade BuyLimit");
      if(ok) { cntPlaced++; placed = true; }
   }
   if(allowSell)
   {
      double p  = NormalizePrice(sellPx);
      double sl = NormalizePrice(p + slDist);
      double tp = tpDist > 0 ? NormalizePrice(p - tpDist) : 0;
      bool ok = useStop ? trade.SellStop(lot, p, _Symbol, sl, tp, tt, exp, "Trap SellStop")
                        : trade.SellLimit(lot, p, _Symbol, sl, tp, tt, exp, "Fade SellLimit");
      if(ok) { cntPlaced++; placed = true; }
   }
   if(placed)
   {
      trapRefPrice   = mid;
      trapPlacedTime = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
// Broker süreli emre izin veriyorsa kullan, vermiyorsa GTC (süreyi EA yönetir)
void GetExpiry(ENUM_ORDER_TYPE_TIME &tt, datetime &exp)
{
   long modes = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if((modes & SYMBOL_EXPIRATION_SPECIFIED) == SYMBOL_EXPIRATION_SPECIFIED)
   {
      tt  = ORDER_TIME_SPECIFIED;
      exp = TimeCurrent() + InpPendingBars * PeriodSeconds(PERIOD_CURRENT);
   }
   else
   {
      tt  = ORDER_TIME_GTC;
      exp = 0;
   }
}

// Kırılım modları trendli/hareketli piyasada, fade modu yatay piyasada çalışsın
bool RegimeOK()
{
   if(!InpUseADX) return true;
   double a[1];
   if(CopyBuffer(adxHandle, 0, 1, 1, a) != 1) return false;
   if(InpEntryMode == ENTRY_LIMIT_FADE) return (a[0] <= InpADXMaxFade);
   return (a[0] >= InpADXMinBreakout);
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

// Round-turn komisyonun fiyat cinsinden karşılığı (1 lot için)
double CommissionInPrice()
{
   if(InpCommissionPerLot <= 0) return 0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0;
   return InpCommissionPerLot / (tickValue / tickSize);
}

// Komisyon dahil SL mesafesi (komisyon manuel input)
double CalculateSLDistance(double atr)
{
   double baseSL = atr * InpSLATRMult;
   double cost   = CommissionInPrice();
   if(cost <= 0) return baseSL;
   return MathMin(baseSL + cost, atr * 2.5);
}

// Brokerın izin verdiği en yakın SL/TP/emir mesafesi (stops ve freeze level'dan büyüğü)
double StopLevelPrice()
{
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(stops > freeze ? stops : freeze) * _Point;
}

double NormalizePrice(double p)
{
   if(p <= 0) return 0;
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts > 0) p = MathRound(p / ts) * ts;
   return NormalizeDouble(p, _Digits);
}

//+------------------------------------------------------------------+
bool IsInSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int now = dt.hour * 100 + dt.min;
   if(sessStart < sessEnd) return (now >= sessStart && now <= sessEnd);
   return (now >= sessStart || now <= sessEnd);
}

//+------------------------------------------------------------------+
void ManagePyramid(int totalBuy, int totalSell, double ask, double bid, double atr)
{
   double step    = atr * InpPyramidStepATR;
   double slDist  = CalculateSLDistance(atr);
   double tpDist  = InpTPATRMult > 0 ? atr * InpTPATRMult : 0;
   double baseLot = CalculateLot(slDist);
   double stopLvl = StopLevelPrice();

   if(totalBuy > 0 && (!InpOnlyOneDirection || totalSell == 0))
   {
      double extreme = GetExtremeEntry(POSITION_TYPE_BUY);       // en yüksek alış
      if(extreme > 0 && bid >= extreme + step)
      {
         double lot = NormalizeLot(baseLot * MathPow(InpPyramidLotMult, totalBuy));
         double sl  = ask - slDist;
         if(InpPyramidBE)
            sl = MathMin(GroupStopLevel(POSITION_TYPE_BUY, lot, ask, slDist, baseLot), bid - stopLvl - _Point);
         sl = NormalizePrice(sl);
         double tp = tpDist > 0 ? NormalizePrice(ask + tpDist) : 0;
         if(trade.Buy(lot, _Symbol, ask, sl, tp, "Pyramid Buy"))
         {
            cntPyramid++;
            ModifyGroup(POSITION_TYPE_BUY, InpPyramidBE ? sl : -1, tp);
         }
      }
   }

   if(totalSell > 0 && (!InpOnlyOneDirection || totalBuy == 0))
   {
      double extreme = GetExtremeEntry(POSITION_TYPE_SELL);      // en düşük satış
      if(extreme > 0 && ask <= extreme - step)
      {
         double lot = NormalizeLot(baseLot * MathPow(InpPyramidLotMult, totalSell));
         double sl  = bid + slDist;
         if(InpPyramidBE)
            sl = MathMax(GroupStopLevel(POSITION_TYPE_SELL, lot, bid, slDist, baseLot), ask + stopLvl + _Point);
         sl = NormalizePrice(sl);
         double tp = tpDist > 0 ? NormalizePrice(bid - tpDist) : 0;
         if(trade.Sell(lot, _Symbol, bid, sl, tp, "Pyramid Sell"))
         {
            cntPyramid++;
            ModifyGroup(POSITION_TYPE_SELL, InpPyramidBE ? sl : -1, tp);
         }
      }
   }
}

// Eklenecek pozisyon dahil grubun ortak SL seviyesi: bu seviyede grubun toplam zararı
// en fazla InpPyramidRiskR x (baz lot x slDist) olur. 0 -> komisyon dahil başabaş.
double GroupStopLevel(ENUM_POSITION_TYPE type, double addLot, double addPrice, double slDist, double baseLot)
{
   double lots = 0, lotPx = 0;
   GroupSums(type, lots, lotPx);
   lots  += addLot;
   lotPx += addLot * addPrice;
   if(lots <= 0) return 0;

   double avg     = lotPx / lots;
   double allowed = MathMax(InpPyramidRiskR, 0.0) * slDist * baseLot / lots;
   double comm    = CommissionInPrice();
   if(type == POSITION_TYPE_BUY) return avg - allowed + comm;
   return avg + allowed - comm;
}

//+------------------------------------------------------------------+
void ManageTrailing(double atr)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minGap = StopLevelPrice() + _Point;
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
         double n = NormalizePrice(bid - MathMax(atr * InpTrailDistATR, minGap));
         if(n > sl + _Point * 0.5) trade.PositionModify(t, n, tp);
      }
      else if(type == POSITION_TYPE_SELL && open - ask >= atr * InpTrailStartATR)
      {
         double n = NormalizePrice(ask + MathMax(atr * InpTrailDistATR, minGap));
         if(sl <= 0 || n < sl - _Point * 0.5) trade.PositionModify(t, n, tp);
      }
   }
}

//+------------------------------------------------------------------+
// newSL <= 0 ise SL'ye dokunma. SL yalnızca kâr yönünde taşınır. TP hepsine uygulanır.
void ModifyGroup(ENUM_POSITION_TYPE type, double newSL, double newTP)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetInteger(POSITION_TYPE) != type) continue;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double sl    = curSL;
      if(newSL > 0)
      {
         if(curSL <= 0)                     sl = newSL;
         else if(type == POSITION_TYPE_BUY) sl = MathMax(curSL, newSL);
         else                               sl = MathMin(curSL, newSL);
      }
      sl = NormalizePrice(sl);
      double tp = NormalizePrice(newTP);
      if(MathAbs(sl - curSL) < _Point * 0.5 && MathAbs(tp - curTP) < _Point * 0.5) continue;
      trade.PositionModify(t, sl, tp);
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

void GroupSums(ENUM_POSITION_TYPE type, double &lots, double &lotPx)
{
   lots = 0; lotPx = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         double v = PositionGetDouble(POSITION_VOLUME);
         lots  += v;
         lotPx += v * PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
}

// Alışlarda en yüksek, satışlarda en düşük giriş fiyatı
double GetExtremeEntry(ENUM_POSITION_TYPE type)
{
   double ext = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         double op = PositionGetDouble(POSITION_PRICE_OPEN);
         if(ext == 0 || (type == POSITION_TYPE_BUY ? op > ext : op < ext)) ext = op;
      }
   }
   return ext;
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

double NormalizeLot(double lot)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(mn, MathMin(mx, lot));
   if(st > 0) lot = MathRound(lot / st) * st;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("v1.60 kapandı | Mod: %s | Kurulan emir: %d | İşlem grubu: %d | Pyramid ekleme: %d | Günlük stop: %d",
               EnumToString(InpEntryMode), cntPlaced, cntGroups, cntPyramid, cntDaily);
   PrintFormat("Atlanan bar -> seans:%d spread:%d mum:%d bekleme:%d günlük-max:%d rejim:%d atr/spread:%d kanal:%d | spread ile silinen emir:%d",
               cntSession, cntSpread, cntCandle, cntCooldown, cntMaxDay, cntRegime, cntATRSpread, cntRange, cntSpreadDel);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
   if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
}
//+------------------------------------------------------------------+
