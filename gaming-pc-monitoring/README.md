# Monitoring a SteamOS Gaming PC with Prometheus + Grafana

A complete, beginner-friendly guide to collecting hardware metrics (CPU, RAM,
disk, network, temperatures) from a **SteamOS** gaming PC — like a Steam Deck or
a desktop running SteamOS — and graphing them in Grafana.

This guide is written to be shareable: it contains **no secrets** and uses
placeholders for everything machine-specific:

- `<STEAMOS_PC_IP>` — the LAN IP address of your SteamOS PC
- `<HOMELAB_SERVER_IP>` — the IP of the server running Prometheus + Grafana
- `deck` — the standard, built-in SteamOS user (this is not a secret; it is the
  default username on every SteamOS device)

> **The short version:** install Prometheus
> [Node Exporter](https://github.com/prometheus/node_exporter) on the SteamOS PC
> under `/home/deck`, run it as a systemd *user* service, point Prometheus at
> `<STEAMOS_PC_IP>:9100`, and import a Grafana dashboard. The rest of this
> document explains the *why* and the gotchas.

---

## Table of contents

- [Why SteamOS is different (the read-only filesystem)](#why-steamos-is-different-the-read-only-filesystem)
- [Overview of the setup](#overview-of-the-setup)
- [Step 1 — Install Node Exporter on SteamOS](#step-1--install-node-exporter-on-steamos)
- [Step 2 — Persist it with a systemd user service](#step-2--persist-it-with-a-systemd-user-service)
- [Step 3 — Add the target to Prometheus](#step-3--add-the-target-to-prometheus)
- [Step 4 — Build the Grafana dashboard](#step-4--build-the-grafana-dashboard)
- [What metrics are available](#what-metrics-are-available)
- [Troubleshooting](#troubleshooting)

---

## Why SteamOS is different (the read-only filesystem)

SteamOS (the Arch-based OS on the Steam Deck and SteamOS desktops) ships with an
**immutable, read-only root filesystem**. The system partition that holds `/usr`,
`/etc`, and most system directories is mounted read-only by default. Valve does
this on purpose:

- **Reliability** — you can't accidentally break the OS, and a bad update can be
  rolled back atomically.
- **Atomic updates** — SteamOS updates replace the entire system image. Anything
  you wrote into system directories is **wiped or reverted** on the next update.

You *can* temporarily unlock the filesystem (`sudo steamos-readonly disable`) and
install packages with `pacman`, but **don't** — those changes do not survive
system updates, and you'd have to redo them (and re-init the pacman keyring)
after every SteamOS release.

**The update-proof approach** is to keep everything in the one place SteamOS
treats as yours and never touches: your **home directory**, `/home/deck`. The
home partition is writable and persistent across updates. So we:

1. Download the Node Exporter binary into `/home/deck/node_exporter`.
2. Run it as a **systemd *user* service** (units in `~/.config/systemd/user`),
   which also lives in your home directory.
3. Enable **lingering** so the user service starts at boot without you having to
   log in to the desktop first.

No `sudo`, no unlocking the filesystem, no pacman — nothing that an update can
undo.

---

## Overview of the setup

```text
┌───────────────────────────────┐         ┌──────────────────────────────┐
│  Homelab server               │ scrape  │  SteamOS gaming PC           │
│  <HOMELAB_SERVER_IP>          │  every  │  <STEAMOS_PC_IP>             │
│                               │   15s   │                              │
│  Prometheus :9090  ◀──────────┼─────────┤  Node Exporter :9100         │
│  Grafana    :3000             │         │  (systemd --user service)    │
└───────────────────────────────┘         └──────────────────────────────┘
```

You'll do steps 1–2 **on the SteamOS PC**, and steps 3–4 **on the homelab
server** (or its web UIs).

---

## Step 1 — Install Node Exporter on SteamOS

Node Exporter is a single static binary — no dependencies, no installer. We put
it under `/home/deck` so it survives updates.

You can either run the provided script or do it by hand.

### Option A — use the install script (recommended)

Copy [`install-node-exporter.sh`](install-node-exporter.sh) and
[`node_exporter.service`](node_exporter.service) onto the SteamOS PC (via `scp`,
a USB stick, or by cloning this repo), then:

```bash
# On the SteamOS PC, as the deck user:
chmod +x install-node-exporter.sh
./install-node-exporter.sh
```

The script downloads Node Exporter into `/home/deck/node_exporter`, installs the
systemd user service, enables it, and turns on lingering. Skip to
[Step 3](#step-3--add-the-target-to-prometheus) once it finishes.

### Option B — manual install

First, switch to **Desktop Mode** on SteamOS and open **Konsole** (the
terminal). All commands run as the `deck` user — **no `sudo` needed**.

```bash
# 1. Pick a version and download into your home directory
VERSION=1.8.2
cd ~
mkdir -p ~/node_exporter && cd ~/node_exporter
curl -fSLO "https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-amd64.tar.gz"

# 2. Extract
tar -xzf "node_exporter-${VERSION}.linux-amd64.tar.gz"

# 3. Put a stable symlink on your PATH so future upgrades don't break the service
mkdir -p ~/.local/bin
ln -sf ~/node_exporter/node_exporter-${VERSION}.linux-amd64/node_exporter ~/.local/bin/node_exporter

# 4. Quick smoke test (Ctrl-C to stop)
~/.local/bin/node_exporter
```

In another terminal, confirm it's serving metrics:

```bash
curl -s localhost:9100/metrics | head
```

You should see lines like `node_cpu_seconds_total{...}`. Stop the foreground
process with `Ctrl-C` and continue to Step 2 to make it permanent.

---

## Step 2 — Persist it with a systemd user service

A **user** service (as opposed to a system service) keeps the unit file in your
home directory (`~/.config/systemd/user/`), so it too survives SteamOS updates.

Create the unit (this matches the bundled
[`node_exporter.service`](node_exporter.service)):

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter (user service)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=%h/.local/bin/node_exporter
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
```

`%h` expands to your home directory (`/home/deck`), so the unit never hard-codes
a path that an update could invalidate.

Enable and start it:

```bash
systemctl --user daemon-reload
systemctl --user enable --now node_exporter.service
systemctl --user status node_exporter.service   # should say "active (running)"
```

### Make it start at boot (lingering)

By default, a user's services only run while that user is logged in. To make
Node Exporter start at boot and keep running even when no one is logged into the
desktop, enable **lingering** for the `deck` user:

```bash
sudo loginctl enable-linger deck
```

This is the one command that needs `sudo`, but it only flips a flag in
`/var/lib/systemd/linger` (on the writable partition) — it does not touch the
read-only system image, so it survives updates.

Verify after a reboot:

```bash
systemctl --user is-active node_exporter.service   # -> active
curl -s localhost:9100/metrics | head
```

---

## Step 3 — Add the target to Prometheus

On the homelab server, edit `~/docker/prometheus/prometheus.yml` and make sure
the SteamOS job is present (replace the placeholder with your real LAN IP):

```yaml
scrape_configs:
  - job_name: "steamos-pc"
    static_configs:
      - targets: ["<STEAMOS_PC_IP>:9100"]
        labels:
          host: "steamos-pc"
```

The global `scrape_interval` is already `15s`. Apply the change by restarting
Prometheus:

```bash
cd ~/docker/prometheus && docker compose restart prometheus
```

> **Why restart and not `curl -X POST .../-/reload`?** `prometheus.yml` is
> bind-mounted as a single file. Most editors save atomically (write a temp file,
> then rename), which swaps the file's inode — but the container is still bound to
> the *old* inode, so a hot-reload re-reads stale content and silently misses your
> edit. A `docker compose restart` re-binds the mount to the current file.

Then open **`http://<HOMELAB_SERVER_IP>:9090/targets`** and confirm the
`steamos-pc` target shows **`UP`**.

---

## Step 4 — Build the Grafana dashboard

1. Open Grafana at **`http://<HOMELAB_SERVER_IP>:3000`** and log in.
2. The **Prometheus** data source is already provisioned, so you can go straight
   to dashboards.
3. Import the community **Node Exporter Full** dashboard, which is purpose-built
   for these metrics:
   - *Dashboards → New → Import*
   - Enter dashboard ID **`1860`** and click *Load*
   - Select the **Prometheus** data source and click *Import*
4. At the top of the dashboard, pick `host = steamos-pc` (or the matching
   `instance`) to view your gaming PC.

You now have live graphs of CPU, memory, disk, network, and temperatures.

---

## What metrics are available

Node Exporter exposes hundreds of metrics. The most useful for a gaming PC:

| Category | Example metrics | What it tells you |
|---|---|---|
| **CPU** | `node_cpu_seconds_total` | Per-core usage, load, time spent in user/system/idle |
| **Memory** | `node_memory_MemAvailable_bytes`, `node_memory_MemTotal_bytes` | RAM used vs. free |
| **Disk** | `node_filesystem_avail_bytes`, `node_disk_io_time_seconds_total` | Free space per mount, disk I/O |
| **Network** | `node_network_receive_bytes_total`, `node_network_transmit_bytes_total` | Throughput per interface |
| **Temperatures** | `node_hwmon_temp_celsius` | CPU/GPU/board sensor temps (from the `hwmon` collector) |
| **Load / uptime** | `node_load1`, `node_load5`, `node_time_seconds`, `node_boot_time_seconds` | System load and uptime |
| **Filesystem health** | `node_filesystem_files_free` | Inode exhaustion warning signs |

> **Tip on temperatures:** the `hwmon` collector is enabled by default and reads
> from `/sys/class/hwmon`. Sensor *names* vary by hardware — use Grafana's
> *Explore* view and query `node_hwmon_temp_celsius` to see which sensors your
> specific board exposes, then label your panels accordingly.

To browse everything your device exposes, query the raw endpoint:

```bash
curl -s http://<STEAMOS_PC_IP>:9100/metrics | less
```

---

## Troubleshooting

### Node Exporter not starting after a SteamOS update

A SteamOS update should **not** affect a home-directory install — that's the
whole point of this approach. But if Node Exporter is missing after an update:

- **It was installed system-wide by mistake.** If you previously unlocked the
  filesystem and used `pacman` or copied the binary to `/usr/local/bin`, that's
  gone now. Reinstall under `/home/deck` following
  [Step 1, Option B](#option-b--manual-install).
- **The user service isn't running.** Check it:

  ```bash
  systemctl --user status node_exporter.service
  journalctl --user -u node_exporter.service -n 50 --no-pager
  ```

- **Lingering got reset.** Re-enable it so the service starts at boot without a
  login:

  ```bash
  sudo loginctl enable-linger deck
  ```

- **The binary symlink is dangling** (e.g. you upgraded versions). Re-point it:

  ```bash
  ls -l ~/.local/bin/node_exporter
  ln -sf ~/node_exporter/node_exporter-<VERSION>.linux-amd64/node_exporter ~/.local/bin/node_exporter
  systemctl --user restart node_exporter.service
  ```

### Firewall / port access issues

Symptom: `curl localhost:9100/metrics` works **on** the SteamOS PC, but the
homelab server can't reach `<STEAMOS_PC_IP>:9100`.

- **Test reachability from the server:**

  ```bash
  curl -s http://<STEAMOS_PC_IP>:9100/metrics | head
  # or:
  nc -vz <STEAMOS_PC_IP> 9100
  ```

- **SteamOS firewall.** Stock SteamOS usually has no active firewall, but if
  you've installed one (e.g. `firewalld` / `ufw`), allow port 9100 from your LAN:

  ```bash
  # firewalld example
  sudo firewall-cmd --add-port=9100/tcp --permanent && sudo firewall-cmd --reload
  ```

- **Node Exporter bound only to localhost?** By default it listens on all
  interfaces (`:9100`). If you previously set `--web.listen-address=127.0.0.1:9100`,
  remove that so it listens on `0.0.0.0:9100`.

- **Different subnet / VLAN.** Make sure the SteamOS PC and the homelab server
  are on the same network or can route to each other.

### Prometheus not scraping the target

Open `http://<HOMELAB_SERVER_IP>:9090/targets` and read the error next to the
`steamos-pc` target:

- **`connection refused`** — Node Exporter isn't running on the SteamOS PC, or
  the firewall is blocking it. See the two sections above.
- **`context deadline exceeded` / timeout** — usually a firewall dropping
  packets (no RST), or the wrong IP. Verify with `nc -vz <STEAMOS_PC_IP> 9100`.
- **Wrong IP / it changed** — the SteamOS PC got a new DHCP lease. Set a DHCP
  reservation for it on your router, then update `prometheus.yml`.
- **Edited config but nothing changed** — restart Prometheus so it re-binds the
  mounted config file (a hot-reload can miss edits made by atomic-save editors,
  because the bind-mounted file's inode changed):

  ```bash
  cd ~/docker/prometheus && docker compose restart prometheus
  ```

  Check the Prometheus logs for config errors:

  ```bash
  docker logs prometheus --tail 50
  ```

- **YAML indentation error** — `prometheus.yml` is whitespace-sensitive. Validate
  it before reloading:

  ```bash
  docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
  ```

---

*Happy monitoring. Pull requests and improvements welcome.*
