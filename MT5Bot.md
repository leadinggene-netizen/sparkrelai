# mt5bot — clean-room SparkRelai bridge EA (core build, v1.00)

Original MQL5 Expert Advisor, written from the *documented behaviour* of
PineConnector v3.54.4 (its public Inputs tab, as shown in screenshots) and
from the SparkRelai portal protocol. No PineConnector code, binary, or DLL
was copied or decompiled — the `.ex5` could not be decompiled at all
(encrypted MQL5 bytecode) and its logic lives in a .NET DLL
(`mscoree.dll` / `kernel32.dll`).

**Key difference from PineConnector: mt5bot is pure MQL5 — no DLL imports.**
It does not need "Allow DLL imports". It talks to the SparkRelai portal,
not to PineConnector's cloud.

## Protocol (same as TradingViewBridge.mq5)

- `GET {PortalURL}/api/ea/poll?license={LicenseKey}&format=text`
  → lines `signal_id|action|symbol|volume|sl|tp`
- Actions: `buy` / `sell` / `close` / `close_long` / `close_short`
- `GET {PortalURL}/api/ea/ack?license=..&signal=..&status=..&ticket=..&note=..`
  (status is `executed` / `failed` / `skipped`)
- `GET {PortalURL}/api/ea/heartbeat?license=..&account=..&broker=..` (every 30 s)

**Important — SL/TP are in pips, not prices.** PineConnector syntax treats
`sl=` / `tp=` as pips; mt5bot converts pips to prices using the symbol's
point size (10 points per pip on 3/5-digit symbols, 1 point otherwise).
`0` means "use the EA inputs". This differs from TradingViewBridge, which
passes SL/TP through as absolute prices — do not mix the two EAs on one
connection without checking which convention the signals use.

## Core features in this build

- Inputs mirroring the PineConnector config: LicenseKey, PortalURL,
  PollIntervalSeconds (2), SignalParamsOnly (true), StopLossPips /
  TakeProfitPips (0), RiskLots (1.0), DefaultVolume (0.10),
  MaxVolumeLots (0.10, second defence), SymbolMap, Prefix / Suffix,
  Pyramiding (true), CloseOnReverse (false), PartialClosePercent (25),
  MaxOpenPositions / PerSymbol / UniqueSymbols (0 = unlimited),
  MaxSlippagePts (650), ShowDashboard (true), FontSize (13),
  MagicNumber (76), MagicRestriction (true), StartTime 00:00 / EndTime 24:00.
- Buy/sell/close/close_long/close_short via `CTrade`, all orders tagged
  with magic 76; only own-magic positions are managed when MagicRestriction
  is on.
- Volume: signal volume first, then RiskLots, then DefaultVolume; capped by
  MaxVolumeLots and normalised to the symbol's lot step / min / max.
- Pyramiding off blocks adding in the same direction; CloseOnReverse closes
  opposite positions first; position caps enforced before opening.
- Partial close: a close signal closes PartialClosePercent % of each
  matching position (`PositionClosePartial`); 0 or 100 = full close.
- Trading-hours filter: new opens blocked outside Start–End (closes always
  allowed); `00:00–24:00` = always open, overnight windows supported.
- Symbol prefix/suffix applied after the symbol map.
- On-chart dashboard (OBJ_LABEL lines): magic, portal, last poll, last
  signal, status, own open positions / symbols.
- Safety: no LicenseKey → no polling (error logged once); paused portal
  connections return an empty poll → nothing executes; WebRequest failures
  are logged, never crash the EA.

## Deliberately left out (later builds)

Daily / cumulative profit-loss halt actions, shadow targets, analytics
upload, auto-update, pending-order entry ("pips from market"), account
filter, 50-messages-per-tick cap (the portal returns at most 20 signals
per poll, so this is not a live limit).

## Setup

1. Compile `MT5Bot.mq5` in MetaEditor (F7) → `MT5Bot.ex5`.
2. MT5 → Tools → Options → Expert Advisors → tick "Allow WebRequest for
   listed URL" and add the portal URL (e.g. `https://sparkrelai.ecovoyage.net`).
3. Attach to a chart, enter LicenseKey and PortalURL, enable Algo Trading.
4. **Test on a DEMO account first. Never test a new EA live.**

## Testing

The live portal (sparkrelai.ecovoyage.net) has been down since Nov 4 —
test against a local portal first: run `python3 app.py` and set PortalURL
to `http://127.0.0.1:8000`. Send buy / sell / close via the portal and
check the signal log acks, magic-76 positions, and the volume cap.

**Warning: do NOT run mt5bot and the PineConnector EA on the same
account/symbol at the same time with the same magic number (76) — they
would both manage the same positions.** Use a demo account or a different
magic for testing.

## Verification limits

MQL5 cannot be compiled on this Linux VM (no MetaEditor). The code was
verified by review against `TradingViewBridge.mq5`, brace/quote balance
checks, and exact matching of the protocol strings against `app.py`.
Compile in MetaEditor before use and fix any compiler errors there.
