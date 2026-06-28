#!/usr/bin/env bash
#
# install-node-exporter.sh
#
# Installs Prometheus Node Exporter on a SteamOS gaming PC (the "deck" user).
#
# SteamOS uses an immutable, read-only root filesystem (`/usr` is read-only and
# gets wiped/replaced on every system update). System-wide installs under
# /usr/local/bin or system systemd units therefore do NOT survive updates.
# To be update-proof, we install entirely under the user's home directory
# (/home/deck) and run as a systemd *user* service.
#
# Run this ON the SteamOS machine as the `deck` user:
#   chmod +x install-node-exporter.sh && ./install-node-exporter.sh
#
set -euo pipefail

VERSION="1.8.2"                       # Node Exporter release to install
ARCH="linux-amd64"                    # SteamOS PCs are x86_64
INSTALL_DIR="${HOME}/node_exporter"   # lives under /home/deck — survives updates
BIN_DIR="${HOME}/.local/bin"
SERVICE_DIR="${HOME}/.config/systemd/user"

TARBALL="node_exporter-${VERSION}.${ARCH}.tar.gz"
URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${TARBALL}"

TEXTFILE_DIR="${HOME}/.local/node_exporter_textfile"  # sidecar *.prom metrics (e.g. GPU)

echo ">> Installing Node Exporter v${VERSION} for the 'deck' user"
mkdir -p "${INSTALL_DIR}" "${BIN_DIR}" "${SERVICE_DIR}" "${TEXTFILE_DIR}"

echo ">> Downloading ${URL}"
cd "${INSTALL_DIR}"
curl -fSL -o "${TARBALL}" "${URL}"

echo ">> Extracting"
tar -xzf "${TARBALL}"
rm -f "${TARBALL}"

# Symlink a stable path so the systemd unit doesn't need editing on upgrades.
ln -sf "${INSTALL_DIR}/node_exporter-${VERSION}.${ARCH}/node_exporter" "${BIN_DIR}/node_exporter"

echo ">> Installing systemd user service"
cp "$(dirname "$0")/node_exporter.service" "${SERVICE_DIR}/node_exporter.service" 2>/dev/null || \
cat > "${SERVICE_DIR}/node_exporter.service" <<EOF
[Unit]
Description=Prometheus Node Exporter (user service)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=%h/.local/bin/node_exporter --collector.textfile.directory=%h/.local/node_exporter_textfile
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

echo ">> Enabling and starting the service"
systemctl --user daemon-reload
systemctl --user enable --now node_exporter.service

# Allow the user service to keep running after logout / across reboots without
# an active login session (important for a headless-style scrape target).
echo ">> Enabling lingering so the service runs across reboots"
loginctl enable-linger "$(whoami)" || \
  echo "   (could not enable linger automatically; run: sudo loginctl enable-linger deck)"

echo ""
echo ">> Done. Verify with:"
echo "     systemctl --user status node_exporter.service"
echo "     curl -s localhost:9100/metrics | head"
echo ""
echo ">> Add this machine to Prometheus as: <STEAMOS_PC_IP>:9100"
