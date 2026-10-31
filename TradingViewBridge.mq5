//+------------------------------------------------------------------+
//|                                          TradingViewBridge.mq5   |
//|  TradingView -> MT5 Bridge Portal (MVP)                            |
//|  Polls the portal for pending signals and executes them locally.   |
//|  The portal NEVER receives your broker password.                   |
//|                                                                    |
//|  Setup:                                                            |
//|  1. Compile this file in MetaEditor (F7). It creates .ex5.        |
//|  2. In MT5: Tools > Options > Expert Advisors >                   |
//|     tick "Allow WebRequest for listed URL" and add your portal     |
//|     URL, e.g. https://your-portal.example.com                      |
//|  3. Attach the EA to any chart, enter your LicenseKey and          |
//|     ServerURL, and enable Algo Trading.                            |
//|  4. Test on a DEMO account first.                                  |
//+------------------------------------------------------------------+
#property copyright "TradingView to MT5 Bridge Portal (MVP)"
#property version   "1.00"
#include <Trade\Trade.mqh>

input string   LicenseKey      = "";                       // License key from your workspace
input string   ServerURL       = "http://127.0.0.1:8000"; // Portal URL, no trailing slash
input int      PollSeconds     = 2;                        // How often to check for signals
input ulong    MagicNumber     = 20261031;                 // Magic number for EA trades
input double   DefaultVolume   = 0.01;                     // Used when a signal has no volume
input double   MaxVolumeLots   = 0.10;                     // Second defence: skip buy/sell signals above this (0 = no EA cap, portal cap still applies)
input string   SymbolMap       = "";                       // e.g. XAUUSD=XAUUSD.m,EURUSD=EURUSD.pro
input int      MaxSlippagePts  = 30;                       // Max slippage in points

CTrade trade;

//--- Split a string by one character, returns count
int SplitString(const string text, const ushort sep, string &out[])
{
   return StringSplit(text, sep, out);
}

string MappedSymbol(const string tv_symbol)
{
   if(SymbolMap == "") return tv_symbol;
   string pairs[];
   int n = StringSplit(SymbolMap, ',', pairs);
   for(int i = 0; i < n; i++)
   {
      string kv[];
      if(StringSplit(pairs[i], '=', kv) == 2 && kv[0] == tv_symbol)
         return kv[1];
   }
   return tv_symbol;
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
   string headers = "";
   char result[];
   string result_headers = "";
   ResetLastError();
   int res = WebRequest("GET", url, "", 5000, data, result, result_headers);
   if(res == -1)
   {
      Print("WebRequest failed, error ", GetLastError(), ". Did you allow this URL in Tools > Options > Expert Advisors?");
      return "";
   }
   if(res != 200)
   {
      Print("Portal returned HTTP ", res);
      return "";
   }
   return CharArrayToString(result);
}

void Report(const string signal_id, const string status, const ulong ticket, const string note)
{
   string url = StringFormat("%s/api/ea/ack?license=%s&signal=%s&status=%s&ticket=%I64u&note=%s",
      ServerURL, LicenseKey, signal_id, status, ticket, UrlEncode(note));
   HttpGet(url);
}

void Heartbeat()
{
   string url = StringFormat("%s/api/ea/heartbeat?license=%s&account=%I64u&broker=%s",
      ServerURL, LicenseKey, AccountInfoInteger(ACCOUNT_LOGIN), UrlEncode(AccountInfoString(ACCOUNT_COMPANY)));
   HttpGet(url);
}

bool ClosePositions(const string symbol, const int type_to_close) // -1 = any, else POSITION_TYPE_*
{
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      if(type_to_close != -1 && (int)PositionGetInteger(POSITION_TYPE) != type_to_close) continue;
      trade.SetExpertMagicNumber(MagicNumber);
      if(!trade.PositionClose(ticket))
         ok = false;
   }
   return ok;
}

void OnTick()
{
   static datetime last_poll = 0;
   static datetime last_beat = 0;
   if(LicenseKey == "" || ServerURL == "")
      return;
   datetime now = TimeCurrent();
   if(now - last_beat >= 30)
   {
      last_beat = now;
      Heartbeat();
   }
   if(now - last_poll < PollSeconds)
      return;
   last_poll = now;

   string body = HttpGet(ServerURL + "/api/ea/poll?license=" + LicenseKey + "&format=text");
   if(body == "") return;

   string lines[];
   int nlines = StringSplit(body, '\n', lines);
   for(int li = 0; li < nlines; li++)
   {
      string line = lines[li];
      // Trim trailing carriage return
      if(StringLen(line) > 0 && StringGetCharacter(line, StringLen(line) - 1) == 13)
         line = StringSubstr(line, 0, StringLen(line) - 1);
      if(line == "") continue;
      string f[];
      if(StringSplit(line, '|', f) < 6) continue;
      string signal_id = f[0];
      string action    = f[1];
      string tv_symbol = f[2];
      double volume    = StringToDouble(f[3]);
      double sl        = StringToDouble(f[4]);
      double tp        = StringToDouble(f[5]);
      string symbol    = MappedSymbol(tv_symbol);
      if(volume <= 0) volume = DefaultVolume;
      if((action == "buy" || action == "sell") && MaxVolumeLots > 0 && volume > MaxVolumeLots)
      {
         Report(signal_id, "skipped", 0, "volume exceeds EA max: " + DoubleToString(volume, 2));
         continue;
      }

      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetDeviationInPoints(MaxSlippagePts);

      if(action == "close")
      {
         bool ok = ClosePositions(symbol, -1);
         Report(signal_id, ok ? "executed" : "failed", 0, ok ? "closed" : "close failed");
         continue;
      }
      if(action == "close_long")
      {
         bool ok = ClosePositions(symbol, POSITION_TYPE_BUY);
         Report(signal_id, ok ? "executed" : "failed", 0, ok ? "closed long" : "close long failed");
         continue;
      }
      if(action == "close_short")
      {
         bool ok = ClosePositions(symbol, POSITION_TYPE_SELL);
         Report(signal_id, ok ? "executed" : "failed", 0, ok ? "closed short" : "close short failed");
         continue;
      }
      if(action != "buy" && action != "sell")
      {
         Report(signal_id, "skipped", 0, "unknown action: " + action);
         continue;
      }
      if(!SymbolSelect(symbol, true))
      {
         Report(signal_id, "failed", 0, "symbol not in Market Watch: " + symbol);
         continue;
      }
      // Normalise volume to the symbol's lot step / limits
      double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      if(step > 0) volume = MathFloor(volume / step) * step;
      if(volume < vmin) volume = vmin;
      if(volume > vmax) volume = vmax;

      bool ok = false;
      if(action == "buy")
         ok = trade.Buy(volume, symbol, 0, sl, tp, "TV bridge");
      else
         ok = trade.Sell(volume, symbol, 0, sl, tp, "TV bridge");
      if(ok)
         Report(signal_id, "executed", trade.ResultOrder(), "filled");
      else
         Report(signal_id, "failed", 0, "trade failed: " + IntegerToString(trade.ResultRetcode()));
   }
}

int OnInit()
{
   Print("TradingViewBridge started. License set: ", (LicenseKey != "" ? "yes" : "NO - enter your license key"));
   return INIT_SUCCEEDED;
}
