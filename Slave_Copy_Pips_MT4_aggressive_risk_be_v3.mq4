#property strict

// Risk-based slave copier with automatic initial SL and 1R breakeven.

input string SHOW_VERSION            = "Aggressive Risk BE v3.6 - 2026-06-01";
input bool   DebugLog               = true;
input double RiskPercent            = 1.0;    // Risk per trade as % of slave equity
input double DefaultSL_Pips         = 40.0;   // Used only when master has no SL
input bool   RequireMasterSL         = true;  // Reject OPEN if master has no SL yet
input bool   AutoReduceLotForMargin  = true;  // Lower lots if free margin is insufficient
input bool   EnableBreakeven        = true;
input double BreakevenTriggerR      = 1.0;    // Move SL to BE after this R multiple
input double BreakevenOffsetPips    = 0.0;    // Optional profit locked at BE
input int    Slippage               = 30;
input int    SlaveMagic             = 870001;
input string SlaveChannel           = "S2";
input string SlaveNAS100Symbol       = "US100.cash";
input string SlaveUS30Symbol         = "US30.cash";

string BUS_DIR = "CopyBus\\";
datetime lastModifyErrorLogTime = 0;
int lastModifyErrorTicket = -1;
int lastModifyErrorCode = 0;
string lastModifyErrorReason = "";

void D(string s)
{
   if(DebugLog) Print("[SLAVE_AGGRESSIVE] ", s);
}

double PipSize(string symbol)
{
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);
   double point = MarketInfo(symbol, MODE_POINT);
   if(point <= 0.0) return 0.0;
   if(digits == 3 || digits == 5) return 10.0 * point;
   return point;
}

double StopLevelPips(string symbol)
{
   double pip = PipSize(symbol);
   if(pip <= 0.0) return 0.0;
   return MarketInfo(symbol, MODE_STOPLEVEL) * MarketInfo(symbol, MODE_POINT) / pip;
}

double EnsureMinPips(string symbol, double desiredPips)
{
   double minPips = StopLevelPips(symbol);
   if(minPips > 0.0 && desiredPips < minPips) return minPips;
   return desiredPips;
}

int LotDigits(double lotStep)
{
   if(lotStep >= 1.0) return 0;
   if(lotStep >= 0.1) return 1;
   if(lotStep >= 0.01) return 2;
   return 3;
}

double CalculateLotByRisk(string symbol, double slPips)
{
   if(slPips <= 0.0 || RiskPercent <= 0.0) return 0.0;

   double tickValue = MarketInfo(symbol, MODE_TICKVALUE);
   double tickSize = MarketInfo(symbol, MODE_TICKSIZE);
   double pip = PipSize(symbol);
   if(tickValue <= 0.0 || tickSize <= 0.0 || pip <= 0.0)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] Invalid symbol spec sym=", symbol,
            " tickValue=", DoubleToString(tickValue, 6),
            " tickSize=", DoubleToString(tickSize, 6),
            " pip=", DoubleToString(pip, 6),
            ". Check Slave symbol mapping and Market Watch.");
      return 0.0;
   }

   double pipValuePerLot = tickValue * pip / tickSize;
   double lot = (AccountEquity() * RiskPercent / 100.0) / (slPips * pipValuePerLot);
   double minLot = MarketInfo(symbol, MODE_MINLOT);
   double maxLot = MarketInfo(symbol, MODE_MAXLOT);
   double lotStep = MarketInfo(symbol, MODE_LOTSTEP);
   if(lotStep <= 0.0) return 0.0;

   lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] Calculated lot below broker minimum. sym=", symbol,
            " calculated=", DoubleToString(lot, 3), " min=", DoubleToString(minLot, 3));
      return 0.0;
   }
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, LotDigits(lotStep));
}

bool HasEnoughMargin(string symbol, int cmd, double lot, double &remainingMargin)
{
   ResetLastError();
   remainingMargin = AccountFreeMarginCheck(symbol, cmd, lot);
   int err = GetLastError();
   return remainingMargin > 0.0 && err != 134;
}

double AdjustLotForMargin(string symbol, int cmd, double requestedLot)
{
   double remainingMargin = 0.0;
   if(HasEnoughMargin(symbol, cmd, requestedLot, remainingMargin))
      return requestedLot;

   double minLot = MarketInfo(symbol, MODE_MINLOT);
   double lotStep = MarketInfo(symbol, MODE_LOTSTEP);
   if(!AutoReduceLotForMargin || lotStep <= 0.0)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] Insufficient margin sym=", symbol,
            " requestedLot=", DoubleToString(requestedLot, 3),
            " freeMargin=", DoubleToString(AccountFreeMargin(), 2));
      return 0.0;
   }

   int maxSteps = (int)MathFloor(requestedLot / lotStep + 0.0000001);
   int minSteps = (int)MathCeil(minLot / lotStep - 0.0000001);
   int low = minSteps;
   int high = maxSteps;
   int best = 0;

   while(low <= high)
   {
      int mid = (low + high) / 2;
      double candidate = NormalizeDouble(mid * lotStep, LotDigits(lotStep));
      if(HasEnoughMargin(symbol, cmd, candidate, remainingMargin))
      {
         best = mid;
         low = mid + 1;
      }
      else
      {
         high = mid - 1;
      }
   }

   if(best <= 0)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] Insufficient margin even for broker minimum sym=", symbol,
            " minLot=", DoubleToString(minLot, 3),
            " freeMargin=", DoubleToString(AccountFreeMargin(), 2));
      return 0.0;
   }

   double adjustedLot = NormalizeDouble(best * lotStep, LotDigits(lotStep));
   HasEnoughMargin(symbol, cmd, adjustedLot, remainingMargin);
   Print("[SLAVE_AGGRESSIVE][WARN] Lot reduced for margin sym=", symbol,
         " requestedLot=", DoubleToString(requestedLot, 3),
         " adjustedLot=", DoubleToString(adjustedLot, 3),
         " freeMarginBefore=", DoubleToString(AccountFreeMargin(), 2),
         " freeMarginAfter=", DoubleToString(remainingMargin, 2));
   return adjustedLot;
}

bool IsTradableSymbol(string symbol)
{
   if(symbol == "") return false;
   SymbolSelect(symbol, true);
   return MarketInfo(symbol, MODE_TRADEALLOWED) != 0;
}

string ResolveSymbol(string preferred, string alt1, string alt2,
                     string alt3, string alt4, string alt5)
{
   string candidates[6];
   candidates[0] = preferred;
   candidates[1] = alt1;
   candidates[2] = alt2;
   candidates[3] = alt3;
   candidates[4] = alt4;
   candidates[5] = alt5;

   for(int i = 0; i < 6; i++)
   {
      if(IsTradableSymbol(candidates[i])) return candidates[i];
   }
   return preferred;
}

string MapSymbol(string masterSymbol)
{
   if(masterSymbol == "NAS100.r" || masterSymbol == "NAS100" ||
      masterSymbol == "US100.cash" || masterSymbol == "US100")
      return ResolveSymbol(SlaveNAS100Symbol, "US100.cash", "NAS100.cash",
                           "NAS100.r", "NAS100", "US100");

   if(masterSymbol == "DJ30.r" || masterSymbol == "DJ30" ||
      masterSymbol == "US30.cash" || masterSymbol == "US30")
      return ResolveSymbol(SlaveUS30Symbol, "US30.cash", "DJ30.cash",
                           "DJ30.r", "DJ30", "US30");

   return masterSymbol;
}

string GV_MAP(int masterTicket)
{
   return "COPYBUS_AGG_MAP_" + SlaveChannel + "_" + IntegerToString(masterTicket);
}

string GV_RISK(int slaveTicket)
{
   return "COPYBUS_AGG_RISK_" + IntegerToString(slaveTicket);
}

string GV_RISK_PROVISIONAL(int slaveTicket)
{
   return "COPYBUS_AGG_RISK_PROVISIONAL_" + IntegerToString(slaveTicket);
}

int GetSlaveTicket(int masterTicket)
{
   if(!GlobalVariableCheck(GV_MAP(masterTicket))) return -1;
   return (int)GlobalVariableGet(GV_MAP(masterTicket));
}

void SetSlaveTicket(int masterTicket, int slaveTicket)
{
   GlobalVariableSet(GV_MAP(masterTicket), slaveTicket);
}

void ClearSlaveTicket(int masterTicket)
{
   if(GlobalVariableCheck(GV_MAP(masterTicket))) GlobalVariableDel(GV_MAP(masterTicket));
}

bool ReadEvt(string file, string &type, int &ticket, string &symbol,
             int &cmd, double &lot, double &slPips, double &tpPips)
{
   type=""; ticket=0; symbol=""; cmd=0; lot=0; slPips=0; tpPips=0;
   int h = FileOpen(file, FILE_COMMON | FILE_READ | FILE_TXT);
   if(h < 0)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] FileOpen failed ", file, " err=", GetLastError());
      return false;
   }

   while(!FileIsEnding(h))
   {
      string line = FileReadString(h);
      int p = StringFind(line, "=");
      if(p < 0) continue;
      string k = StringSubstr(line, 0, p);
      string v = StringSubstr(line, p + 1);
      if(k=="event_type") type=v;
      else if(k=="ticket") ticket=(int)StrToInteger(v);
      else if(k=="symbol") symbol=v;
      else if(k=="cmd") cmd=(int)StrToInteger(v);
      else if(k=="lot") lot=StrToDouble(v);
      else if(k=="sl_pips") slPips=StrToDouble(v);
      else if(k=="tp_pips") tpPips=StrToDouble(v);
   }
   FileClose(h);
   return (type!="" && ticket>0);
}

bool ModifyStops(int ticket, double sl, double tp, string reason)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return false;
   int digits = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   if(MathAbs(OrderStopLoss() - sl) < MarketInfo(OrderSymbol(), MODE_POINT) / 2.0 &&
      MathAbs(OrderTakeProfit() - tp) < MarketInfo(OrderSymbol(), MODE_POINT) / 2.0)
      return true;

   if(OrderModify(ticket, OrderOpenPrice(), sl, tp, 0))
   {
      D(reason + " ticket=" + IntegerToString(ticket) +
        " sl=" + DoubleToString(sl, digits) + " tp=" + DoubleToString(tp, digits));
      return true;
   }

   int err = GetLastError();
   datetime now = TimeCurrent();
   if(ticket != lastModifyErrorTicket || err != lastModifyErrorCode ||
      reason != lastModifyErrorReason || now - lastModifyErrorLogTime >= 2)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] ", reason, " failed ticket=", ticket,
            " err=", err, " (retrying)");
      lastModifyErrorTicket = ticket;
      lastModifyErrorCode = err;
      lastModifyErrorReason = reason;
      lastModifyErrorLogTime = now;
   }
   ResetLastError();
   return false;
}

void DoOpen(int masterTicket, string masterSymbol, int cmd,
            double masterLot, double slPips, double tpPips)
{
   if(cmd != OP_BUY && cmd != OP_SELL) return;

   string symbol = MapSymbol(masterSymbol);
   D("MAP symbol " + masterSymbol + " -> " + symbol);
   if(MarketInfo(symbol, MODE_TRADEALLOWED) == 0)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] Symbol not tradable: ", symbol);
      return;
   }

   bool provisionalRisk = MathAbs(slPips) <= 0.0;
   if(provisionalRisk && RequireMasterSL)
   {
      Print("[SLAVE_AGGRESSIVE][WARN] OPEN ignored because master SL is missing. master=",
            masterTicket, " sym=", symbol);
      return;
   }

   double usedSLPips = provisionalRisk ? DefaultSL_Pips : MathAbs(slPips);
   usedSLPips = EnsureMinPips(symbol, usedSLPips);
   double lot = CalculateLotByRisk(symbol, usedSLPips);
   if(lot <= 0.0)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] Lot calculation failed sym=", symbol,
            " slPips=", DoubleToString(usedSLPips, 2));
      return;
   }
   lot = AdjustLotForMargin(symbol, cmd, lot);
   if(lot <= 0.0) return;

   double price = (cmd == OP_BUY) ? MarketInfo(symbol, MODE_ASK) : MarketInfo(symbol, MODE_BID);
   int st = OrderSend(symbol, cmd, lot, price, Slippage, 0, 0,
                      "COPYBUS master=" + IntegerToString(masterTicket), SlaveMagic, 0);
   if(st <= 0)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] OPEN failed err=", GetLastError(),
            " sym=", symbol, " lot=", DoubleToString(lot, 3));
      return;
   }

   SetSlaveTicket(masterTicket, st);
   if(!OrderSelect(st, SELECT_BY_TICKET)) return;

   double pip = PipSize(symbol);
   double sl = (cmd == OP_BUY) ? OrderOpenPrice() - usedSLPips * pip
                               : OrderOpenPrice() + usedSLPips * pip;
   double tp = 0.0;
   if(tpPips != 0.0) tp = OrderOpenPrice() + tpPips * pip;

   GlobalVariableSet(GV_RISK(st), usedSLPips * pip);
   if(provisionalRisk) GlobalVariableSet(GV_RISK_PROVISIONAL(st), 1.0);
   ModifyStops(st, sl, tp, "OPEN protection");
   D("OPEN master=" + IntegerToString(masterTicket) + " slave=" + IntegerToString(st) +
     " riskUnits=" + DoubleToString(usedSLPips, 2) +
     " riskPriceDistance=" + DoubleToString(usedSLPips * pip, (int)MarketInfo(symbol, MODE_DIGITS)) +
     " lot=" + DoubleToString(lot, 3));
}

void DoModify(int masterTicket, double slPips, double tpPips)
{
   int st = GetSlaveTicket(masterTicket);
   if(st < 0 || !OrderSelect(st, SELECT_BY_TICKET)) return;

   double pip = PipSize(OrderSymbol());
   double sl = OrderStopLoss();
   double tp = OrderTakeProfit();

   // Master sends signed distances from its entry. Preserve the sign for BE and trailing SL.
   if(slPips != 0.0)
   {
      sl = OrderOpenPrice() + slPips * pip;
      if(GlobalVariableCheck(GV_RISK_PROVISIONAL(st)))
      {
         GlobalVariableSet(GV_RISK(st), MathAbs(sl - OrderOpenPrice()));
         GlobalVariableDel(GV_RISK_PROVISIONAL(st));
         D("Risk baseline updated from master SL ticket=" + IntegerToString(st));
      }
   }
   if(tpPips != 0.0) tp = OrderOpenPrice() + tpPips * pip;
   ModifyStops(st, sl, tp, "MASTER modify");
}

void DoClose(int masterTicket)
{
   int st = GetSlaveTicket(masterTicket);
   if(st < 0) return;
   if(!OrderSelect(st, SELECT_BY_TICKET))
   {
      ClearSlaveTicket(masterTicket);
      return;
   }

   string symbol = OrderSymbol();
   double price = (OrderType() == OP_BUY) ? MarketInfo(symbol, MODE_BID)
                                          : MarketInfo(symbol, MODE_ASK);
   if(OrderClose(st, OrderLots(), price, Slippage))
   {
      ClearSlaveTicket(masterTicket);
      if(GlobalVariableCheck(GV_RISK(st))) GlobalVariableDel(GV_RISK(st));
      if(GlobalVariableCheck(GV_RISK_PROVISIONAL(st))) GlobalVariableDel(GV_RISK_PROVISIONAL(st));
      D("CLOSE master=" + IntegerToString(masterTicket));
   }
   else Print("[SLAVE_AGGRESSIVE][ERR] CLOSE failed err=", GetLastError());
}

bool IsValidStopLoss(string symbol, int cmd, double sl)
{
   double minDistance = MarketInfo(symbol, MODE_STOPLEVEL) * MarketInfo(symbol, MODE_POINT);
   if(cmd == OP_BUY) return sl < MarketInfo(symbol, MODE_BID) - minDistance;
   if(cmd == OP_SELL) return sl > MarketInfo(symbol, MODE_ASK) + minDistance;
   return false;
}

void ManageBreakeven()
{
   if(!EnableBreakeven || BreakevenTriggerR <= 0.0) return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != SlaveMagic) continue;
      if(StringFind(OrderComment(), "COPYBUS master=") != 0) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      double riskDistance = 0.0;
      if(GlobalVariableCheck(GV_RISK(OrderTicket())))
         riskDistance = GlobalVariableGet(GV_RISK(OrderTicket()));
      else if(OrderStopLoss() > 0.0)
      {
         riskDistance = MathAbs(OrderOpenPrice() - OrderStopLoss());
         GlobalVariableSet(GV_RISK(OrderTicket()), riskDistance);
      }
      if(riskDistance <= 0.0) continue;

      string symbol = OrderSymbol();
      double pip = PipSize(symbol);
      int digits = (int)MarketInfo(symbol, MODE_DIGITS);

      // Retry initial protection if the broker rejected the first post-fill modify.
      if(OrderStopLoss() <= 0.0)
      {
         double initialSL = (OrderType() == OP_BUY) ? OrderOpenPrice() - riskDistance
                                                    : OrderOpenPrice() + riskDistance;
         if(IsValidStopLoss(symbol, OrderType(), initialSL))
            ModifyStops(OrderTicket(), initialSL, OrderTakeProfit(), "SL retry");
         continue;
      }

      if(OrderType() == OP_BUY)
      {
         double beBuy = NormalizeDouble(OrderOpenPrice() + BreakevenOffsetPips * pip, digits);
         if(MarketInfo(symbol, MODE_BID) >= OrderOpenPrice() + riskDistance * BreakevenTriggerR &&
            OrderStopLoss() < beBuy && IsValidStopLoss(symbol, OP_BUY, beBuy))
            ModifyStops(OrderTicket(), beBuy, OrderTakeProfit(), "AUTO breakeven");
      }
      else
      {
         double beSell = NormalizeDouble(OrderOpenPrice() - BreakevenOffsetPips * pip, digits);
         if(MarketInfo(symbol, MODE_ASK) <= OrderOpenPrice() - riskDistance * BreakevenTriggerR &&
            (OrderStopLoss() > beSell || OrderStopLoss() <= 0.0) &&
            IsValidStopLoss(symbol, OP_SELL, beSell))
            ModifyStops(OrderTicket(), beSell, OrderTakeProfit(), "AUTO breakeven");
      }
   }
}

void ScanBus()
{
   string fname = "";
   long h = FileFindFirst(BUS_DIR + "*.evt", fname, FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   do
   {
      string type="", symbol="";
      int ticket=0, cmd=0;
      double lot=0, slPips=0, tpPips=0;
      if(!ReadEvt(BUS_DIR + fname, type, ticket, symbol, cmd, lot, slPips, tpPips)) continue;

      if(type=="OPEN") DoOpen(ticket, symbol, cmd, lot, slPips, tpPips);
      else if(type=="MODIFY") DoModify(ticket, slPips, tpPips);
      else if(type=="CLOSE") DoClose(ticket);
      FileDelete(BUS_DIR + fname, FILE_COMMON);
   }
   while(FileFindNext(h, fname));
   FileFindClose(h);
}

int OnInit()
{
   if(RiskPercent <= 0.0 || DefaultSL_Pips <= 0.0)
   {
      Print("[SLAVE_AGGRESSIVE][ERR] RiskPercent and DefaultSL_Pips must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }
   BUS_DIR = "CopyBus\\" + SlaveChannel + "\\";
   EventSetTimer(1);
   D("Started version=" + SHOW_VERSION + " BUS_DIR=" + BUS_DIR);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   ManageBreakeven();
}

void OnTimer()
{
   ScanBus();
   ManageBreakeven();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}
