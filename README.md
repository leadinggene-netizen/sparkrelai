# TradingView → MT5 Bridge Portal — MVP

A PineConnector-style portal, built as a minimal, runnable starting point:
multi-user accounts, subscription plans, per-user workspaces, TradingView
webhooks, a signal log, and an MT5 Expert Advisor that executes signals
locally in the user's own MT5 terminal.

**No broker password is ever sent to, or stored by, the portal.** The EA
only needs its license key.

## What's in here

- `app.py` — the portal. Python standard library only, SQLite storage.
  Sign-up / login, plans, connections, webhook receiver, EA poll/ack/
  heartbeat API, admin user list, EA download.
- `TradingViewBridge.mq5` — the MT5 EA source. Compile it in MetaEditor
  to produce `TradingViewBridge.ex5`. A compiled `.ex5` cannot be built
  on Linux without MetaEditor/Wine, so the source is the deliverable.
- `portal.db` — created on first run. Do not commit real user data.

## Run it locally

```bash
python3 app.py
# open http://127.0.0.1:8000
```

The first account to sign up becomes admin (`/admin`).

Plans in this MVP are placeholders (Starter = 1 connection, Pro = 3,
Scale = 5). Real billing is a later step — see below.

## End-to-end test (demo account only)

1. Sign up, create a connection, note its webhook URL and license key.
2. Download the EA from the workspace, compile it in MetaEditor, and
   attach it to a chart in MT5 on a **demo** account.
3. In MT5: Tools → Options → Expert Advisors → tick
   "Allow WebRequest for listed URL" and add your portal URL.
   Enable Algo Trading. Enter the license key and portal URL in the EA.
4. Send a test signal:
   ```bash
   curl -X POST http://127.0.0.1:8000/webhook/<WEBHOOK_TOKEN> \
     -H 'Content-Type: application/json' \
     -d '{"action":"buy","symbol":"EURUSD","volume":0.01}'
   ```
   Or plain text, PineConnector-style:
   ```bash
   curl -X POST http://127.0.0.1:8000/webhook/<WEBHOOK_TOKEN> \
     -d 'buy,EURUSD,vol=0.01'
   ```
5. The EA polls every 2 seconds, executes, and reports back. Watch the
   connection's signal log change from `pending` to `executed`.

## TradingView setup

1. In TradingView, create an alert for your strategy/indicator.
2. Enable webhook, paste the connection's webhook URL.
3. Set the alert message to JSON, e.g.
   ```json
   {"action": "buy", "symbol": "XAUUSD", "volume": 0.1, "sl": 0, "tp": 0}
   ```
   Supported actions: `buy`, `sell`, `close`, `close_long`, `close_short`.
   Or use text: `buy,XAUUSD,vol=0.1`
4. If your broker's symbol differs (e.g. `XAUUSD.m`), set that mapping
   in the connection or in the EA's `SymbolMap` input.

Note: TradingView webhooks require a paid TradingView plan.

## Deploying to a VPS (outline)

This is the shape of a production deployment, not a one-click setup:

1. VPS: Ubuntu 24.04, 2 vCPU / 4 GB RAM is a fine starting point for
   the portal itself (MT5 itself needs Windows — see below).
2. Put the code in `/opt/tv-mt5-portal`, run it behind a reverse proxy
   (nginx) with HTTPS via Let's Encrypt. Never expose the raw Python
   server to the internet, and set `HOST=127.0.0.1` behind nginx.
3. Run it as a systemd service so it restarts on reboot.
4. Back up `portal.db` regularly, or move to PostgreSQL before launch.
5. Add, before charging users: real Stripe/PayPal webhooks that set the
   plan, email verification and password reset, rate limiting on
   `/webhook/*`, per-user signal quotas, and an audit log.

## The hosted-MT5 question

This MVP deliberately uses **user-run MT5** (their PC or VPS). A hosted
version — where you run MT5 for each user — needs one Windows VPS/terminal
per user, automated MT5 installation, broker-login handling, and
terminal monitoring. That is the biggest cost and complexity in a
PineConnector Edge-style product, and it is best added after the bridge
itself is proven.

## Safety controls

- **Per-connection max volume:** set it when you create a connection,
  and change it on the connection page. Buy/sell webhook signals above
  the cap are rejected (HTTP 400) and never queued. Close signals are
  not volume-capped, so you can always flatten a position.
- **Kill switch:** pause a connection from its own page, or from
  `/admin` (admin only). Pausing blocks new webhooks (HTTP 403), makes
  the EA poll return nothing, and marks pending signals `skipped`, so
  they cannot execute after you resume. Resume from the same button.
- **EA second defence:** the EA's `MaxVolumeLots` input (default 0.10)
  skips buy/sell signals above that size at the terminal, even if a
  signal somehow reached it. Set it to 0 to rely on the portal cap only.
- Still not in this build: daily loss limits, per-user signal quotas,
  rate limiting on `/webhook/*`, email verification, and real billing.
  Add those before offering it to paying users.

## Safety and honesty

- Test on demo first. A bad alert message, symbol map, or volume can
  open real trades.
- Automated trading may be restricted by some brokers and prop firms.
  Check their rules before using it on a funded account.
- Nothing here is financial advice.
