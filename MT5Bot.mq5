//+------------------------------------------------------------------+
//|                                                     MT5Bot.mq5     |
//|  mt5bot — clean-room TradingView -> MT5 bridge EA for SparkRelai  |
//|                                                                    |
//|  ORIGINAL WORK. This EA was written from the DOCUMENTED BEHAVIOUR |
//|  of PineConnector v3.54.4 (its public Inputs tab, as shown in     |
//|  screenshots) and from the SparkRelai portal protocol. No          |
//|  PineConnector code, binary, or DLL was copied or decompiled —    |
//|  the .ex5 could not be decompiled at all (encrypted MQL5          |
//|  bytecode). mt5bot is a fresh, pure-MQL5 implementation of the    |
//|  same ideas, and it talks to the SparkRelai portal, not to         |
//|  PineConnector's cloud.                                            |
//|                                                                    |
//|  IMPROVEMENT OVER PINECONNECTOR: pure MQL5, NO DLL imports.       |
//|  PineConnector wraps a .NET DLL (mscoree.dll / kernel32.dll) and  |
//|  needs "Allow DLL imports". mt5bot needs no DLL at all.           |
//|                                                                    |
//|  PROTOCOL: polls the SparkRelai portal, exactly like               |
//|  TradingViewBridge.mq5:                                            |
//|    GET {PortalURL}/api/ea/poll?license={LicenseKey}&format=text   |
//|    -> lines:  signal_id|action|symbol|volume|sl|tp                |
//|    actions: buy / sell / close / close_long / close_short         |
//|    volume in lots; sl / tp are in PIPS (PineConnector syntax),   |
//|    0 = use the EA inputs below.                                    |
//|    GET {PortalURL}/api/ea/ack?license=..&signal=..&status=..      |
//|    GET {PortalURL}/api/ea/heartbeat?license=..&account=..&broker=..|
//|  The portal enforces its own per-connection max-volume cap and    |
//|  its kill switch (paused connections return no signals).           |
//|                                                                    |
//|  SETUP:                                                            |
//|  1. Compile this file in MetaEditor (F7). It creates MT5Bot.ex5.  |
//|  2. In MT5: Tools > Options > Expert Advisors > tick "Allow       |
//|     WebRequest for listed URL" and add your portal URL, e.g.      |
//|     https://sparkrelai.ecovoyage.net                               |
//|  3. Attach the EA to any chart, enter LicenseKey and PortalURL,   |
//|     enable Algo Trading.                                           |
//|  4. Test on a DEMO account first. NEVER test a new EA live.       |
//|                                                                    |
//|  LEFT OUT OF THIS CORE BUILD (planned later): daily / cumulative   |
//|  profit-loss halt actions, shadow targets, analytics upload,       |
//|  auto-update, pending-order entry ("pips from market"), account    |
//|  filter.                                                           |
//+------------------------------------------------------------------+
#property copyright "mt5bot — clean-room SparkRelai bridge EA"
#property version   "1.00"
#include <Trade\Trade.mqh>

//--- Connection (mirrors PineConnector "License ID" + portal URL)
input string   LicenseKey      = "";                          // License key from your SparkRelai workspace (REQUIRED — no key, no trading)
input string   PortalURL       = "https://sparkrelai.ecovoyage.net"; // Portal URL, no trailing slash
input int      PollIntervalSeconds = 2;                       // How often to check for signals

//--- Syntax / signal handling (PineConnector "Syntax" + "Input" groups)
input bool     SignalParamsOnly = true;                      // "Signal Parameters Only (Ignore EA Inputs)": signal SL/TP/volume win; EA inputs only fill in 0s
input double   StopLossPips    = 0.0;                        // EA stop loss, in pips (used when signal sl = 0)
input double   TakeProfitPips  = 0.0;                        // EA take profit, in pips (used when signal tp = 0)
input double   RiskLots        = 1.0;                        // Volume (lots) used when a signal carries no volume; 0 = use DefaultVolume instead
input double   DefaultVolume   = 0.10;                       // Fallback volume when signal has no volume and RiskLots = 0
input double   MaxVolumeLots   = 0.10;                       // Second defence: skip buy/sell signals above this (0 = no EA cap; portal cap still applies)
input string   SymbolMap       = "";                          // e.g. BTCUSD=BTCUSD,BTCUSDT.P=BTCUSD (TradingView symbol = broker symbol)
input string   Prefix          = "";                          // Symbol prefix added to the broker symbol (e.g. "m." -> m.BTCUSD)
input string   Suffix          = "";                          // Symbol suffix added to the broker symbol (e.g. ".m" -> BTCUSD.m)

//--- General (PineConnector "General" group)
input bool     Pyramiding      = true;                        // Allow adding to an existing position in the same direction
input bool     CloseOnReverse  = false;                       // Close opposite positions before opening a new one
input int      PartialClosePercent = 25;                      // % of a position a close signal closes (0 or 100 = full close)
input int      MaxOpenPositions = 0;                          // Max own positions in total (0 = unlimited)
input int      MaxOpenPositionsPerSymbol = 0;                 // Max own positions per symbol (0 = unlimited)
input int      MaxUniqueSymbols = 0;                          // Max distinct symbols with own positions (0 = unlimited)
input int      MaxSlippagePts  = 650;                         // Max slippage in points

//--- Dashboard (PineConnector "Dashboard" group)
input bool     ShowDashboard   = true;                        // Show on-chart dashboard
input int      FontSize        = 13;                          // Dashboard font size

//--- Miscellaneous (PineConnector "Miscellaneous" group)
input ulong    MagicNumber     = 76;                          // Magic number: tags every mt5bot order/position
input bool     MagicRestriction = true;                       // Only manage positions carrying our magic number
input string   StartTime       = "00:00";                     // Trading window start (HH:MM); 00:00-24:00 = always open
input string   EndTime         = "24:00";                     // Trading window end (HH:MM)

CTrade trade;

//--- Dashboard state
string g_last_signal = "none yet";
string g_last_status = "";
datetime g_last_poll = 0;
int g_signals_seen = 0;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string MappedSymbol(const string tv_symbol)
{
   string mapped = tv_symbol;
   if(SymbolMap != "")
   {
      string pairs[];
      int n = StringSplit(SymbolMap, ',', pairs);
      for(int i = 0; i < n; i++)
      {
         string kv[];
         if(StringSplit(pairs[i], '=', kv) == 2 && kv[0] == tv_symbol)
         {
            mapped = kv[1];
            break;
         }
      }
   }
   return Prefix + mapped + Suffix;
}

string UrlEncode(const string s)
{
   string out = "";
   for(int i = 0; i < StringLen(s); i++)
   {
      string ch = StringSubstr(s, i, 1);
      if(ch == " ") out += "%20";
      else if(ch == "&") out += "%26";
      else if(ch == "?") out += "%3F";
      else if(ch == "=") out += "%3D";
      else out += ch;
   }
   return out;
}

//--- Simple GET via WebRequest. Returns body, or "" on failure.
string HttpGet(const string url)
{
   char data[];
   char result[];
   string result_headers = "";
   ResetLastError();
   int res = WebRequest("GET", url, "", 5000, data, result, result_headers);
   if(res == -1)
   {
      Print("MT5Bot: WebRequest failed, error ", GetLastError(),
            ". Did you allow this URL in Tools > Options > Expert Advisors?");
      return "";
   }
   if(res != 200)
   {
      Print("MT5Bot: portal returned HTTP ", res);
      return "";
   }
   return CharArrayToString(result);
}

void Report(const string signal_id, const string status, const ulong ticket, const string note)
{
   string url = StringFormat("%s/api/ea/ack?license=%s&signal=%s&status=%s&ticket=%I64u&note=%s",
      PortalURL, LicenseKey, signal_id, status, ticket, UrlEncode(note));
   HttpGet(url);
}

void Heartbeat()
{
   string url = StringFormat("%s/api/ea/heartbeat?license=%s&account=%I64u&broker=%s",
      PortalURL, LicenseKey, AccountInfoInteger(ACCOUNT_LOGIN), UrlEncode(AccountInfoString(ACCOUNT_COMPANY)));
   HttpGet(url);
}

//--- One pip in price units: 10 points on 3/5-digit symbols, 1 point otherwise
double PipSize(const string symbol)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
}

//--- Convert a pips distance into an absolute SL/TP price. Returns 0 when pips <= 0.
double PriceFromPips(const string symbol, const bool is_buy, const double pips, const bool is_sl)
{
   if(pips <= 0) return 0.0;
   double pip = PipSize(symbol);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double price = 0.0;
   if(is_buy)
      price = is_sl ? SymbolInfoDouble(symbol, SYMBOL_ASK) - pips * pip
                    : SymbolInfoDouble(symbol, SYMBOL_ASK) + pips * pip;
   else
      price = is_sl ? SymbolInfoDouble(symbol, SYMBOL_BID) + pips * pip
                    : SymbolInfoDouble(symbol, SYMBOL_BID) - pips * pip;
   return NormalizeDouble(price, digits);
}

//--- Drop an SL/TP that is closer than the broker's minimum stops level. Returns adjusted price (0 = none).
double CheckStopsLevel(const string symbol, const double open_price, const double sl_tp_price, const bool is_sl)
{
   if(sl_tp_price == 0.0) return 0.0;
   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double dist_points = MathAbs(sl_tp_price - open_price) / point;
   if(dist_points < (double)stops_level)
   {
      Print("MT5Bot: ", (is_sl ? "SL" : "TP"), " too close to entry (", DoubleToString(dist_points, 0),
            " pts < stops level ", IntegerToString(stops_level), " pts) — dropped");
      return 0.0;
   }
   return sl_tp_price;
}

//--- Normalise volume to the symbol's lot step / min / max
double NormaliseVolume(const string symbol, double volume)
{
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   if(step > 0) volume = MathFloor(volume / step) * step;
   if(volume < vmin) volume = vmin;
   if(volume > vmax) volume = vmax;
   return volume;
}

//--- Is this position one of ours? (magic filter, if MagicRestriction is on)
bool IsOwnPosition()
{
   if(!MagicRestriction) return true;
   return PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber;
}

int CountOwnPositions(const string symbol) // "" = all symbols
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsOwnPosition()) continue;
      if(symbol != "" && PositionGetString(POSITION_SYMBOL) != symbol) continue;
      count++;
   }
   return count;
}

int CountOwnSymbols()
{
   string seen[];
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsOwnPosition()) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      bool found = false;
      for(int j = 0; j < n; j++)
         if(seen[j] == sym) { found = true; break; }
      if(!found)
      {
         ArrayResize(seen, n + 1);
         seen[n] = sym;
         n++;
      }
   }
   return n;
}

bool HasOwnPosition(const string symbol, const int type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(!IsOwnPosition()) continue;
      if((int)PositionGetInteger(POSITION_TYPE) == type) return true;
   }
   return false;
}

//--- Close (fully or partially) our positions on a symbol.
//--- type_to_close: -1 = any, else POSITION_TYPE_BUY / POSITION_TYPE_SELL.
//--- partial_percent: 0 or >=100 = full close; 1..99 = close that % of each position.
bool ClosePositions(const string symbol, const int type_to_close, const int partial_percent)
{
   bool ok = true;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePts);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(!IsOwnPosition()) continue;
      if(type_to_close != -1 && (int)PositionGetInteger(POSITION_TYPE) != type_to_close) continue;
      double pos_volume = PositionGetDouble(POSITION_VOLUME);
      if(partial_percent > 0 && partial_percent < 100)
      {
         double close_vol = NormaliseVolume(symbol, pos_volume * partial_percent / 100.0);
         if(close_vol <= 0 || close_vol >= pos_volume)
         {
            if(!trade.PositionClose(ticket)) ok = false;
         }
         else
         {
            if(!trade.PositionClosePartial(ticket, close_vol)) ok = false;
         }
      }
      else
      {
         if(!trade.PositionClose(ticket)) ok = false;
      }
   }
   return ok;
}

//--- "HH:MM" -> minutes since midnight (24:00 = 1440). Returns -1 on bad input.
int ParseHHMM(const string t)
{
   string parts[];
   if(StringSplit(t, ':', parts) != 2) return -1;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 24 || m < 0 || m > 59) return -1;
   if(h == 24 && m != 0) return -1;
   return h * 60 + m;
}

bool InTradingHours()
{
   int start = ParseHHMM(StartTime);
   int end = ParseHHMM(EndTime);
   if(start < 0 || end < 0) return true; // bad input: fail open, do not block trading silently
   if(start == end) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int now_min = dt.hour * 60 + dt.min;
   if(start < end) return (now_min >= start && now_min < end);
   return (now_min >= start || now_min < end); // overnight window
}

//+------------------------------------------------------------------+
//| Dashboard (OBJ_LABEL lines, top-left)                            |
//+------------------------------------------------------------------+
#define DASH_LINES 6
void DashboardInit()
{
   if(!ShowDashboard) return;
   for(int i = 0; i < DASH_LINES; i++)
   {
      string name = "MT5Bot_L" + IntegerToString(i);
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20 + i * 18);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, FontSize);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetString(0, name, OBJPROP_TEXT, "");
   }
}

void DashboardUpdate(const string status_line)
{
   if(!ShowDashboard) return;
   string lines[DASH_LINES];
   lines[0] = "MT5Bot  |  Magic " + IntegerToString((long)MagicNumber) + "  |  " + (LicenseKey == "" ? "NO LICENSE KEY" : "license set");
   lines[1] = "Portal: " + PortalURL;
   lines[2] = "Last poll: " + (g_last_poll == 0 ? "never" : TimeToString(g_last_poll, TIME_DATE | TIME_SECONDS)) + "  |  signals: " + IntegerToString(g_signals_seen);
   lines[3] = "Last signal: " + g_last_signal;
   lines[4] = "Status: " + status_line;
   lines[5] = "Open positions (own): " + IntegerToString(CountOwnPositions("")) + "  |  symbols: " + IntegerToString(CountOwnSymbols());
   for(int i = 0; i < DASH_LINES; i++)
      ObjectSetString(0, "MT5Bot_L" + IntegerToString(i), OBJPROP_TEXT, lines[i]);
   ChartRedraw(0);
}

void DashboardRemove()
{
   for(int i = 0; i < DASH_LINES; i++)
      ObjectDelete(0, "MT5Bot_L" + IntegerToString(i));
}

//+------------------------------------------------------------------+
//| Signal execution                                                 |
//+------------------------------------------------------------------+
void ExecuteSignal(const string signal_id, const string action, const string tv_symbol,
                   const double sig_volume, const double sig_sl_pips, const double sig_tp_pips)
{
   string symbol = MappedSymbol(tv_symbol);
   g_last_signal = action + " " + tv_symbol + " -> " + symbol;
   g_signals_seen++;

   //--- Resolve SL/TP in pips: signal wins when SignalParamsOnly, else EA inputs win
   double sl_pips = 0.0, tp_pips = 0.0;
   if(SignalParamsOnly)
   {
      sl_pips = (sig_sl_pips > 0) ? sig_sl_pips : StopLossPips;
      tp_pips = (sig_tp_pips > 0) ? sig_tp_pips : TakeProfitPips;
   }
   else
   {
      sl_pips = (StopLossPips > 0) ? StopLossPips : sig_sl_pips;
      tp_pips = (TakeProfitPips > 0) ? TakeProfitPips : sig_tp_pips;
   }

   //--- Close actions: closes are always allowed (even outside trading hours)
   if(action == "close" || action == "close_long" || action == "close_short")
   {
      int type_to_close = -1;
      if(action == "close_long") type_to_close = POSITION_TYPE_BUY;
      if(action == "close_short") type_to_close = POSITION_TYPE_SELL;
      int pct = PartialClosePercent;
      if(pct < 0) pct = 0;
      if(pct > 100) pct = 100;
      bool ok = ClosePositions(symbol, type_to_close, pct);
      string note = (pct > 0 && pct < 100)
         ? StringFormat("partial close %d%%", pct)
         : "closed";
      Report(signal_id, ok ? "executed" : "failed", 0, ok ? note : "close failed");
      g_last_status = ok ? ("close executed (" + note + ")") : "close FAILED";
      return;
   }

   if(action != "buy" && action != "sell")
   {
      Report(signal_id, "skipped", 0, "unknown action: " + action);
      g_last_status = "skipped: unknown action " + action;
      return;
   }

   //--- Trading-hours filter: no NEW opens outside the window
   if(!InTradingHours())
   {
      Report(signal_id, "skipped", 0, "outside trading hours " + StartTime + "-" + EndTime);
      g_last_status = "skipped: outside trading hours";
      return;
   }

   //--- Volume: signal first, then RiskLots, then DefaultVolume; then the EA cap
   double volume = sig_volume;
   if(volume <= 0)
      volume = (RiskLots > 0) ? RiskLots : DefaultVolume;
   if(MaxVolumeLots > 0 && volume > MaxVolumeLots)
   {
      Report(signal_id, "skipped", 0, "volume exceeds EA max: " + DoubleToString(volume, 2));
      g_last_status = "skipped: volume exceeds EA max";
      return;
   }

   if(!SymbolSelect(symbol, true))
   {
      Report(signal_id, "failed", 0, "symbol not in Market Watch: " + symbol);
      g_last_status = "failed: symbol not in Market Watch";
      return;
   }
   volume = NormaliseVolume(symbol, volume);
   if(volume <= 0)
   {
      Report(signal_id, "failed", 0, "volume normalises to 0 for " + symbol);
      g_last_status = "failed: volume 0 after normalise";
      return;
   }

   bool is_buy = (action == "buy");
   int my_type = is_buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   int opp_type = is_buy ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   //--- Close-on-reverse: clear the other side first
   if(CloseOnReverse && HasOwnPosition(symbol, opp_type))
   {
      ClosePositions(symbol, opp_type, 100);
   }

   //--- Pyramiding: when off, refuse to add in the same direction
   if(!Pyramiding && HasOwnPosition(symbol, my_type))
   {
      Report(signal_id, "skipped", 0, "pyramiding off and position already open on " + symbol);
      g_last_status = "skipped: pyramiding off";
      return;
   }

   //--- Position caps (0 = unlimited)
   if(MaxOpenPositions > 0 && CountOwnPositions("") >= MaxOpenPositions)
   {
      Report(signal_id, "skipped", 0, "max open positions reached");
      g_last_status = "skipped: max open positions";
      return;
   }
   if(MaxOpenPositionsPerSymbol > 0 && CountOwnPositions(symbol) >= MaxOpenPositionsPerSymbol)
   {
      Report(signal_id, "skipped", 0, "max open positions per symbol reached");
      g_last_status = "skipped: max per-symbol positions";
      return;
   }
   if(MaxUniqueSymbols > 0 && !HasOwnPosition(symbol, POSITION_TYPE_BUY) && !HasOwnPosition(symbol, POSITION_TYPE_SELL)
      && CountOwnSymbols() >= MaxUniqueSymbols)
   {
      Report(signal_id, "skipped", 0, "max unique symbols reached");
      g_last_status = "skipped: max unique symbols";
      return;
   }

   //--- SL/TP prices from pips, with stops-level guard
   double open_price = is_buy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   double sl = CheckStopsLevel(symbol, open_price, PriceFromPips(symbol, is_buy, sl_pips, true), true);
   double tp = CheckStopsLevel(symbol, open_price, PriceFromPips(symbol, is_buy, tp_pips, false), false);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePts);
   bool ok = false;
   if(is_buy)
      ok = trade.Buy(volume, symbol, 0, sl, tp, "mt5bot");
   else
      ok = trade.Sell(volume, symbol, 0, sl, tp, "mt5bot");
   if(ok)
   {
      Report(signal_id, "executed", trade.ResultOrder(), "filled");
      g_last_status = action + " executed " + DoubleToString(volume, 2) + " " + symbol;
   }
   else
   {
      Report(signal_id, "failed", 0, "trade failed: " + IntegerToString(trade.ResultRetcode()));
      g_last_status = action + " FAILED retcode " + IntegerToString(trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| Expert functions                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   static datetime last_poll = 0;
   static datetime last_beat = 0;
   static bool no_key_warned = false;

   if(LicenseKey == "" || PortalURL == "")
   {
      if(!no_key_warned)
      {
         Print("MT5Bot: LicenseKey / PortalURL not set — polling disabled. Enter them in the EA inputs.");
         no_key_warned = true;
      }
      DashboardUpdate("NO LICENSE KEY — set LicenseKey + PortalURL");
      return;
   }

   datetime now = TimeCurrent();
   if(now - last_beat >= 30)
   {
      last_beat = now;
      Heartbeat();
   }
   if(now - last_poll < PollIntervalSeconds)
      return;
   last_poll = now;
   g_last_poll = now;

   // Paused (kill switch) connections return an empty body: nothing to do.
   string body = HttpGet(PortalURL + "/api/ea/poll?license=" + LicenseKey + "&format=text");
   if(body == "")
   {
      DashboardUpdate("poll ok — no signals (or connection paused)");
      return;
   }

   string lines[];
   int nlines = StringSplit(body, '\n', lines);
   for(int li = 0; li < nlines; li++)
   {
      string line = lines[li];
      if(StringLen(line) > 0 && StringGetCharacter(line, StringLen(line) - 1) == 13)
         line = StringSubstr(line, 0, StringLen(line) - 1);
      if(line == "") continue;
      string f[];
      if(StringSplit(line, '|', f) < 6) continue;
      ExecuteSignal(f[0], f[1], f[2], StringToDouble(f[3]), StringToDouble(f[4]), StringToDouble(f[5]));
   }
   DashboardUpdate(g_last_status);
}

int OnInit()
{
   Print("MT5Bot started. License set: ", (LicenseKey != "" ? "yes" : "NO - enter your license key"),
         " | Portal: ", PortalURL, " | Magic: ", IntegerToString((long)MagicNumber));
   if(ParseHHMM(StartTime) < 0 || ParseHHMM(EndTime) < 0)
      Print("MT5Bot: WARNING — StartTime/EndTime not in HH:MM format, trading-hours filter disabled");
   if(MaxVolumeLots > 0 && DefaultVolume > MaxVolumeLots)
      Print("MT5Bot: WARNING — DefaultVolume above MaxVolumeLots; signals at DefaultVolume will be capped");
   DashboardInit();
   DashboardUpdate("started — waiting for signals");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DashboardRemove();
   Comment("");
}
//+------------------------------------------------------------------+
