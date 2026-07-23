# Setting up your Restaurant OS hub (Ubuntu)

This is the small computer that runs your restaurant locally and keeps working
even if the internet goes down. Setup takes about 10 minutes and you only do it
once. The installer does the technical parts for you.

You'll need: the hub computer running **Ubuntu**, its power and network cable, and
the **pairing code** from your Restaurant OS dashboard.

---

## Step 1 — Download and run the installer

1. Open the **Terminal** (press the Super/Windows key, type "Terminal", press Enter).
2. Copy and paste these two lines, one at a time, and press Enter after each:

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/Vahan132/restaurant-os-hub/main/install-hub.sh
   sudo bash install-hub.sh
   ```

3. If it asks for your password, type it (the screen won't show anything as you
   type — that's normal) and press Enter.

The installer sets everything up: it installs Docker if needed, downloads the hub,
creates its settings, opens the network port, starts it, and makes it start again
automatically after a power cut. Wait until it says **"Done. The hub is starting."**

It prints two web addresses — one for this computer, one for tablets/phones on the
same network. Keep them for the next step.

> Safer alternative to a one-line "pipe to shell": the two lines above **download**
> the script first so it can be inspected, then run it — nothing runs from the
> internet unseen.

---

## Step 2 — Pair the hub

1. On the hub computer, open a web browser and go to **http://localhost:3001/setup**
   (or the address the installer printed).
2. Enter your **pairing code** and confirm.
3. The page confirms it's connected. That's it — the hub is live and running your
   branch.

From a tablet or phone on the same Wi-Fi, open the "From a tablet" address the
installer printed (the hub's network address) to reach it too.

---

## It already starts on its own

The installer set up a **systemd service** (`edge-hub.service`), so the hub comes
back **by itself** after a power cut or reboot — no login, nothing to click. You can
test it: reboot the computer, wait a minute or two, and open the `/setup` (or your
normal) page — it should be back.

---

## Everyday use

**Is it running?**

```bash
cd /opt/restaurant-os
sudo docker compose -f docker-compose.edge.yml --env-file .env.edge ps
```

You should see `restaurantos-edge-api` and `restaurantos-edge-postgres` as **Up**.
(You can also check the service: `systemctl status edge-hub.service`.)

**Update the hub.** When you're told a new version is available:

```bash
cd /opt/restaurant-os
sudo bash update-hub.sh
```

It updates and restarts in place — your data and pairing are kept, and it's safe to
do during service.

**Restart the hub.** Just reboot the computer; the hub returns on its own.

---

## Important: re-pairing

Only pair the hub **once**. Running pairing again with a new code will **disconnect
the current setup** and start fresh. Don't re-pair unless support tells you to.

---

## If something's wrong

- **The `/setup` page won't open.** Check the containers are up with the `ps` command
  above. If they're not, run `sudo systemctl restart edge-hub.service`.
- **A tablet can't reach the hub.** Make sure it's on the same network as the hub and
  you're using the hub's network address (not `localhost`). If you have a firewall
  on, allow the port: `sudo ufw allow 3001/tcp`.
- **See what happened:** `sudo docker compose -f /opt/restaurant-os/docker-compose.edge.yml --env-file /opt/restaurant-os/.env.edge logs api`

You never need a password or account to run the hub itself — only your pairing code.
