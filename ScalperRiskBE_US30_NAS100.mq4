//+------------------------------------------------------------------+
//|                                      ScalperRiskBE_US30_NAS100.mq4 |
//|                         Manual-order risk SL + 1R breakeven helper |
//+------------------------------------------------------------------+
#property strict

input double RiskMoney              = 50.0;   // Risk per trade in account currency
input bool   SetSLOnlyWhenMissing   = true;   // Do not overwrite an existing SL
input int    BreakevenOffsetPoints  = 0;      // Extra points beyond entry when moving to BE
input int    SlippagePoints         = 30;     // Modify tolerance

datetime lastLogTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(RiskMoney <= 0.0)
   {
      Print("RiskMoney must be greater than 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   Print("ScalperRiskBE_US30_NAS100 started. RiskMoney=", DoubleToString(RiskMoney, 2));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   RefreshRates();

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;

      ManageOrder();
   }
}

//+------------------------------------------------------------------+
void ManageOrder()
{
   if(OrderLots() <= 0.0)
      return;

   string symbol = OrderSymbol();
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);
   double point = MarketInfo(symbol, MODE_POINT);
   double openPrice = OrderOpenPrice();
   double currentSL = OrderStopLoss();

   if(currentSL <= 0.0 || !SetSLOnlyWhenMissing)
   {
      double newSL = CalculateRiskStopLoss(symbol, OrderType(), OrderLots(), openPrice);
      if(newSL > 0.0 && IsValidStopLoss(symbol, OrderType(), newSL))
      {
         if(ModifyOrderSL(NormalizeDouble(newSL, digits), "initial risk SL"))
            currentSL = NormalizeDouble(newSL, digits);
      }
   }

   if(currentSL <= 0.0)
      return;

   double riskDistance = MathAbs(openPrice - currentSL);
   if(riskDistance < point)
      return;

   double bid = MarketInfo(symbol, MODE_BID);
   double ask = MarketInfo(symbol, MODE_ASK);
   double beOffset = BreakevenOffsetPoints * point;

   if(OrderType() == OP_BUY)
   {
      double triggerBuy = openPrice + riskDistance;
      double beBuy = NormalizeDouble(openPrice + beOffset, digits);

      if(bid >= triggerBuy && currentSL < beBuy && IsValidStopLoss(symbol, OP_BUY, beBuy))
         ModifyOrderSL(beBuy, "1R breakeven");
   }
   else if(OrderType() == OP_SELL)
   {
      double triggerSell = openPrice - riskDistance;
      double beSell = NormalizeDouble(openPrice - beOffset, digits);

      if(ask <= triggerSell && (currentSL > beSell || currentSL <= 0.0) && IsValidStopLoss(symbol, OP_SELL, beSell))
         ModifyOrderSL(beSell, "1R breakeven");
   }
}

//+------------------------------------------------------------------+
double CalculateRiskStopLoss(string symbol, int orderType, double lots, double openPrice)
{
   double tickValue = MarketInfo(symbol, MODE_TICKVALUE);
   double tickSize = MarketInfo(symbol, MODE_TICKSIZE);
   double point = MarketInfo(symbol, MODE_POINT);
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);

   if(tickValue <= 0.0 || tickSize <= 0.0 || lots <= 0.0)
   {
      ThrottledPrint("Cannot calculate SL for ", symbol, ". Check tick value/tick size from broker.");
      return(0.0);
   }

   double valuePerPriceUnit = tickValue / tickSize;
   double priceDistance = RiskMoney / (lots * valuePerPriceUnit);

   double stopLevel = MarketInfo(symbol, MODE_STOPLEVEL) * point;
   if(stopLevel > 0.0 && priceDistance < stopLevel)
      priceDistance = stopLevel;

   if(orderType == OP_BUY)
      return(NormalizeDouble(openPrice - priceDistance, digits));

   if(orderType == OP_SELL)
      return(NormalizeDouble(openPrice + priceDistance, digits));

   return(0.0);
}

//+------------------------------------------------------------------+
bool IsValidStopLoss(string symbol, int orderType, double stopLoss)
{
   double point = MarketInfo(symbol, MODE_POINT);
   double stopLevel = MarketInfo(symbol, MODE_STOPLEVEL) * point;
   double bid = MarketInfo(symbol, MODE_BID);
   double ask = MarketInfo(symbol, MODE_ASK);

   if(orderType == OP_BUY)
      return(stopLoss < bid - stopLevel);

   if(orderType == OP_SELL)
      return(stopLoss > ask + stopLevel);

   return(false);
}

//+------------------------------------------------------------------+
bool ModifyOrderSL(double stopLoss, string reason)
{
   int ticket = OrderTicket();
   bool ok = OrderModify(
      ticket,
      OrderOpenPrice(),
      stopLoss,
      OrderTakeProfit(),
      0,
      clrNONE
   );

   if(ok)
   {
      Print("Order #", ticket, " ", reason, " set SL=", DoubleToString(stopLoss, (int)MarketInfo(OrderSymbol(), MODE_DIGITS)));
      return(true);
   }

   int err = GetLastError();
   Print("OrderModify failed for #", ticket, " while setting ", reason, ". Error=", err);
   ResetLastError();
   return(false);
}

//+------------------------------------------------------------------+
void ThrottledPrint(string a, string b, string c)
{
   datetime now = TimeCurrent();
   if(now - lastLogTime >= 30)
   {
      Print(a, b, c);
      lastLogTime = now;
   }
}
//+------------------------------------------------------------------+
