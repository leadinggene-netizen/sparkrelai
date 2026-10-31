# Deploying the portal to a VPS — sparkrelai.ecovoyage.net

This is the complete, later-deployment package. Nothing here is running
yet on a public server: your VPS is still to be set up, and this file
is the checklist for when it is.

## 0. What you need before you start

- A VPS: Ubuntu 24.04, 2 vCPU / 4 GB RAM, with a **static public IP**.
- SSH access to that VPS as root (or a sudo user).
- Control of `ecovoyage.net` in Route53 (you already have the hosted zone).
- A demo MT5 account for the first end-to-end test.

## 1. Point DNS at the VPS

In Route53, in the `ecovoyage.net` hosted zone, create:

- Record name: `sparkrelai`
- Record type: `A`
- Value: **your VPS's static public IP** (not `192.0.2.235` — that is only
  AWS's placeholder in the form, and not my VM's address either)
- TTL: `300`

Check it from your own machine (not from my VM, whose resolver is internal):

```bash
dig +short sparkrelai.ecovoyage.net
# should print your VPS public IP
```

## 2. Get the code onto the VPS

Option A — from GitHub (recommended, if you push the new files first):

```bash
ssh root@<VPS-IP>
git clone https://github.com/leadinggene-netizen/sparkrelai.git /opt/sparkrelai-src
cd /opt/sparkrelai-src
```

Option B — upload the zip in this package and unpack it:

```bash
scp sparkrelai-portal-deploy.zip root@<VPS-IP>:/root/
ssh root@<VPS-IP>
unzip -o sparkrelai-portal-deploy.zip -d /root/sparkrelai-src
cd /root/sparkrelai-src
```

Either way, the folder you run the deploy script from must contain
`app.py`, `deploy.sh`, and the `deploy/` folder.

## 3. Run the deploy script

```bash
DOMAIN=sparkrelai.ecovoyage.net ./deploy.sh
```

It installs Python, nginx, ufw and certbot, copies the portal to
`/opt/sparkrelai`, installs the systemd service, and configures nginx
for your domain. The portal itself only listens on `127.0.0.1:8000`;
nginx is the only thing exposed to the internet.

## 4. Add HTTPS (do this after DNS has propagated)

```bash
certbot --nginx -d sparkrelai.ecovoyage.net
```

Then verify:

```bash
curl -f https://sparkrelai.ecovoyage.net/healthz
# {"ok": true}
```

If that fails, check DNS first, then `systemctl status sparkrelai nginx`.

## 5. First use

1. Open `https://sparkrelai.ecovoyage.net` and sign up.
   The first account becomes admin.
2. Create a connection. Note its webhook URL and license key.
3. In MT5 (demo account first):
   - Compile `TradingViewBridge.mq5` in MetaEditor to get the `.ex5`.
   - Tools → Options → Expert Advisors → allow WebRequest for
     `https://sparkrelai.ecovoyage.net`.
   - Attach the EA, enter the license key and portal URL, enable Algo Trading.
4. In TradingView, create an alert with webhook
   `https://sparkrelai.ecovoyage.net/webhook/<WEBHOOK_TOKEN>` and message:
   ```json
   {"action": "buy", "symbol": "XAUUSD", "volume": 0.01}
   ```
5. Watch the connection's signal log go from `pending` to `executed`.

## 6. Operating notes

- Service: `systemctl status sparkrelai`, `journalctl -u sparkrelai -f`
- Data file: `/opt/sparkrelai/portal.db` — back it up regularly.
  It holds users, connections, webhook tokens and signal logs.
- Updates: pull the new code (or re-upload the zip), copy `app.py` and
  the EA into `/opt/sparkrelai`, then `systemctl restart sparkrelai`.
- Do NOT expose port 8000 directly, and do NOT run the portal as a
  public HTTP site without certbot — webhook tokens and passwords
  must travel over HTTPS.
- Before charging real users, add: real Stripe/PayPal webhooks, email
  verification, rate limiting on `/webhook/*`, daily loss limits, and
  per-user signal quotas. Max-volume caps and a kill switch are already
  in this build (see README "Safety controls").

## Files in this package

- `app.py` — portal (Python stdlib, SQLite)
- `TradingViewBridge.mq5` — MT5 EA source
- `README.md` — local run and TradingView/MT5 setup
- `DEPLOY.md` — this file
- `deploy.sh` — VPS install script
- `deploy/nginx-sparkrelai.conf` — nginx template
- `deploy/sparkrelai.service` — systemd template
- `.gitignore` — keeps `portal.db` out of Git
