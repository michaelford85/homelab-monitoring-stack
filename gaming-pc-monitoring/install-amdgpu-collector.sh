#!/usr/bin/env bash
#
# install-amdgpu-collector.sh
#
# Installs a sidecar collector that exposes DISCRETE AMD GPU metrics
# (utilization, VRAM, clocks, temp, power) through node_exporter's textfile
# collector. Run AFTER install-node-exporter.sh, ON the SteamOS PC as `deck`:
#   chmod +x install-amdgpu-collector.sh && ./install-amdgpu-collector.sh
#
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
SERVICE_DIR="${HOME}/.config/systemd/user"
TEXTFILE_DIR="${HOME}/.local/node_exporter_textfile"
SRC="$(dirname "$0")"
NE_UNIT="${SERVICE_DIR}/node_exporter.service"
FLAG='--collector.textfile.directory=%h/.local/node_exporter_textfile'

mkdir -p "${BIN_DIR}" "${SERVICE_DIR}" "${TEXTFILE_DIR}"

echo ">> Installing GPU collector script + service"
install -m 0755 "${SRC}/amdgpu-textfile-collector.sh" "${BIN_DIR}/amdgpu-textfile-collector.sh"
install -m 0644 "${SRC}/amdgpu-collector.service"      "${SERVICE_DIR}/amdgpu-collector.service"

# Ensure node_exporter is started with the textfile directory flag.
if [[ -f "${NE_UNIT}" ]] && ! grep -q "collector.textfile.directory" "${NE_UNIT}"; then
  echo ">> Adding textfile collector flag to existing node_exporter.service"
  sed -i "\#^ExecStart=#{/collector.textfile.directory/!s#\$# ${FLAG}#}" "${NE_UNIT}"
  RESTART_NE=1
fi

echo ">> Enabling services"
systemctl --user daemon-reload
[[ "${RESTART_NE:-0}" == "1" ]] && systemctl --user restart node_exporter.service
systemctl --user enable --now amdgpu-collector.service

# Lingering should already be on from install-node-exporter.sh; ensure anyway.
loginctl enable-linger "$(whoami)" 2>/dev/null || true

sleep 2
echo ""
echo ">> Metrics written to ${TEXTFILE_DIR}/amdgpu.prom:"
grep -E '^amdgpu_' "${TEXTFILE_DIR}/amdgpu.prom" 2>/dev/null | sed 's/^/     /' || echo "     (none yet — check: journalctl --user -u amdgpu-collector -n 30)"
echo ""
echo ">> Confirm node_exporter is serving them:"
echo "     curl -s localhost:9100/metrics | grep '^amdgpu_'"
echo ">> If the wrong GPU was picked, set GPU_CARD in the service, e.g.:"
echo "     systemctl --user edit amdgpu-collector.service   # add Environment=GPU_CARD=card1"
