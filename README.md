# homelab-monitoring-stack

> Infrastructure monitoring, alerting, and remote tunnel validation for
> a Docker-based homelab using Uptime Kuma, WireGuard, and systemd.

------------------------------------------------------------------------

## Overview

This repository documents the monitoring architecture for my homelab
environment.\
It includes:

-   Uptime Kuma deployment
-   Monitor configuration strategy
-   Slack alerting setup
-   WireGuard remote tunnel validation via EC2
-   Health check scripts
-   systemd services and timers

The goal is repeatable infrastructure monitoring setup in case the
environment ever needs to be rebuilt.

------------------------------------------------------------------------

# Architecture Summary

Monitoring Layers:

1.  Container Health (Docker status)
2.  HTTP Health (Service availability)
3.  DNS Resolution (Pi-hole functionality)
4.  WAN Connectivity (External reachability)
5.  WireGuard Remote Probe (True end-to-end tunnel validation)
6.  Daily System Summary (Slack report)
7.  Real-time Slack Alerts

------------------------------------------------------------------------

# Uptime Kuma Setup

## Docker Deployment

``` bash
docker run -d \
  --name uptime-kuma \
  -p 3001:3001 \
  -v uptime-kuma:/app/data \
  --restart=always \
  louislam/uptime-kuma:latest
```

Access via:

http://`<server-ip>`{=html}:3001

------------------------------------------------------------------------

# Monitor Categories & Recommended Settings

  Category           Interval   Retries   Notes
  ------------------ ---------- --------- -----------------------------------------
  HTTP               60s        2         Detect service-level issues quickly
  Containers         60s        1         Process-level safety check
  DNS                30--60s    2         Fast detection since clients rely on it
  WAN                60s        4--5      Avoid ISP flap noise
  WireGuard Remote   60s push   1         Based on handshake freshness

------------------------------------------------------------------------

# Slack Integration

## Real-Time Alerts

1.  Create Slack Incoming Webhook
2.  Add notification in Uptime Kuma
3.  Assign notification to monitors

## Daily Summary Script

Location:

/usr/local/bin/homelab-daily-summary

Triggered by systemd timer.

------------------------------------------------------------------------

# WireGuard Remote Monitoring

## Why This Exists

Container health does NOT guarantee tunnel usability.

We validate:

-   Public IP reachability
-   Port forwarding
-   Firewall correctness
-   Handshake freshness
-   Routing integrity

## EC2 Remote Peer Setup

1.  Launch small EC2 instance (t4g.nano or similar)
2.  Install WireGuard
3.  Configure split tunnel (NO 0.0.0.0/0)
4.  Add:

PersistentKeepalive = 25

5.  Confirm handshake refresh every \~25 seconds.

------------------------------------------------------------------------

# WireGuard Health Probe Script

Location:

/usr/local/bin/wg-ec2-probe

Purpose:

-   Check handshake age
-   If fresh → Push to Uptime Kuma
-   If stale → Do nothing (monitor goes DOWN)

------------------------------------------------------------------------

# systemd Integration

## Service

/etc/systemd/system/wg-ec2-probe.service

## Timer

/etc/systemd/system/wg-ec2-probe.timer

Enable:

``` bash
sudo systemctl daemon-reload
sudo systemctl enable --now wg-ec2-probe.timer
```

------------------------------------------------------------------------

# Daily Slack Summary

Script location:

/usr/local/bin/homelab-daily-summary

Permissions:

``` bash
sudo chown root:root /usr/local/bin/homelab-daily-summary
sudo chmod 755 /usr/local/bin/homelab-daily-summary
```

Test:

``` bash
sudo /usr/local/bin/homelab-daily-summary
```

------------------------------------------------------------------------

# Lambda Nightly Instance Shutdown

Lambda excludes monitoring node via tag:

AlwaysOn = true

Only instances without that tag are stopped.

Runtime: Python 3.13

------------------------------------------------------------------------

# Disaster Recovery Notes

If rebuilding:

1.  Deploy Uptime Kuma container
2.  Recreate monitors
3.  Configure Slack notifications
4.  Recreate EC2 remote peer
5.  Restore scripts
6.  Enable systemd timers
7.  Validate push monitor heartbeat
8.  Test Slack alert by stopping WireGuard container temporarily

------------------------------------------------------------------------

# Repository Structure Recommendation

    homelab-monitoring-stack/
    ├── README.md
    ├── scripts/
    │   ├── wg-ec2-probe
    │   └── homelab-daily-summary
    ├── systemd/
    │   ├── wg-ec2-probe.service
    │   └── wg-ec2-probe.timer
    └── docs/
        └── architecture.md

------------------------------------------------------------------------

# Author

Generated on 2026-02-12\
Homelab monitoring documentation.
