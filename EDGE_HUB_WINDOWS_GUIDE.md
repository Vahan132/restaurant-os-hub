# Setting up your Restaurant OS hub (Windows)

This is the small computer that runs your restaurant locally and keeps working
even if the internet goes down. Setup takes about 15 minutes and you only do it
once. You don't need to know any commands — just follow the steps.

You'll need: the hub computer, its power and network cable, and the **pairing
code** from your Restaurant OS dashboard.

---

## Step 1 — Run the hub installer

1. Download the setup files into one folder, e.g. on the Desktop. Get them from the
   public hub page (no GitHub account or login needed):
   **https://github.com/Vahan132/restaurant-os-hub** — you need at least
   `install-hub.bat` and `install-hub.ps1` (grab the other `*.ps1` scripts too so
   updates and boot-on-power work). Click each file → **Download raw file**, or use
   the green **Code → Download ZIP** button and unzip them into one folder.
2. **Double-click `install-hub.bat`.**
3. Windows will ask for permission ("Do you want to allow this app to make
   changes?") — click **Yes**.
4. A black window opens and does everything for you, including **installing Docker
   (the program that runs the hub) if it isn't already there.** It then downloads
   the hub, creates its settings, opens the network port, and starts it. Wait until
   it says **"Done. The hub is starting."**

The installer also prints two web addresses — one for this computer, one for
tablets/phones on the same network. Keep them handy for the next step.

> **If it asks you to restart.** The very first time, Windows sometimes needs one
> restart to finish turning on the piece Docker runs on (WSL2). If the window tells
> you to restart, do it, then **double-click `install-hub.bat` again** — it picks up
> where it left off. This only happens once.
>
> **If it can't install Docker automatically** (rare — usually an older Windows
> without the app installer), it will print a link to
> **https://www.docker.com/products/docker-desktop/**. Install Docker Desktop from
> there (keep **"Use WSL 2"** ticked), open it once until it says **"Engine
> running,"** then run `install-hub.bat` again.

---

## Step 2 — Pair the hub

1. On the hub computer, open a web browser and go to **http://localhost:3001/setup**
   (or click the address the installer printed).
2. Type in your **pairing code** and confirm.
3. The page will tell you it's connected. That's it — the hub is live and will now
   run your branch.

You can also open the "From a tablet" address on another device on the same Wi-Fi
to reach the hub.

---

## Step 3 — Make it start by itself after a power cut (recommended)

So the hub comes back on its own if the power blips, run the boot-on-power setup
once:

1. Right-click **`enable-boot-on-power.ps1`** → **Run with PowerShell** (say **Yes**
   to the permission prompt). For fully unattended restarts, an installer can pass
   the auto-login option for you — ask whoever set this up.
2. It configures Docker to start with Windows and the hub to come up automatically.

Test it: restart the computer, wait about two minutes, and open the `/setup` (or your
normal) page — it should be back without you doing anything.

---

## Everyday use

**Is it running?** Open Docker Desktop → **Containers**. You should see
`restaurantos-edge-api` and `restaurantos-edge-postgres` marked **Running** (green).

**Update the hub.** When you're told a new version is available, double-click
**`update-hub.bat`** (or right-click `update-hub.ps1` → Run with PowerShell). It
updates and restarts in place — your data and pairing are kept, and it's safe to do
during service.

**Restart the hub.** Just restart the computer; the hub comes back on its own (if
you did Step 3).

---

## Important: re-pairing

Only pair the hub **once**. If you run pairing again with a new code, it will
**disconnect the current setup** and start fresh. Don't re-pair unless support tells
you to.

---

## If something's wrong

- **The `/setup` page won't open.** Open Docker Desktop and check the two containers
  are **Running**. If Docker itself isn't running, open Docker Desktop and wait for
  "Engine running," then try again — or just run `install-hub.bat` again, which
  starts Docker for you.
- **A tablet can't reach the hub.** Make sure it's on the same Wi-Fi as the hub, and
  use the "From a tablet" address (the hub's network address), not `localhost`.
- **Still stuck?** In Docker Desktop, click the `restaurantos-edge-api` container to
  see its logs, or contact support with what you see there.

You never need a password or account to run the hub itself — only your pairing code.
