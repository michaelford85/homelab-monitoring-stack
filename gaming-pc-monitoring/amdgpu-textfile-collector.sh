#!/usr/bin/env bash
#
# amdgpu-textfile-collector.sh
#
# Exposes Prometheus metrics for the *discrete* AMD GPU by reading sysfs and
# writing a node_exporter textfile-collector .prom file. node_exporter (started
# with --collector.textfile.directory) then serves these on :9100 — no extra
# network service, no root needed.
#
# It auto-selects the DISCRETE amdgpu (the card NOT on PCI bus 0000:00 — that
# bus holds the integrated APU graphics) and ignores the iGPU. Override with
# GPU_CARD=card1 if detection picks the wrong one.
#
# Runs in a loop; managed by amdgpu-collector.service (systemd --user).
#
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-$HOME/.local/node_exporter_textfile}"
OUT="${TEXTFILE_DIR}/amdgpu.prom"
INTERVAL="${INTERVAL:-5}"

mkdir -p "${TEXTFILE_DIR}"

# --- pick the discrete amdgpu card ---------------------------------------
find_card() {
  if [[ -n "${GPU_CARD:-}" ]]; then echo "/sys/class/drm/${GPU_CARD}"; return; fi
  local fallback=""
  for d in /sys/class/drm/card[0-9]*; do
    [[ -e "$d/device/gpu_busy_percent" ]] || continue            # must be a GPU
    [[ "$(cat "$d/device/vendor" 2>/dev/null)" == "0x1002" ]] || continue  # AMD
    local pci; pci="$(basename "$(readlink -f "$d/device")")"
    if [[ "$pci" != 0000:00:* ]]; then echo "$d"; return; fi      # discrete
    fallback="${fallback:-$d}"                                    # iGPU (last resort)
  done
  echo "$fallback"
}

CARD="$(find_card)"
if [[ -z "$CARD" || ! -e "$CARD/device/gpu_busy_percent" ]]; then
  echo "amdgpu-collector: no discrete AMD GPU found (set GPU_CARD=cardN to override)" >&2
  exit 1
fi
DEV="$CARD/device"
PCI="$(basename "$(readlink -f "$DEV")")"
CARDNAME="$(basename "$CARD")"
HWMON="$(ls -d "$DEV"/hwmon/hwmon* 2>/dev/null | head -1)"
echo "amdgpu-collector: using $CARDNAME (pci=$PCI, hwmon=${HWMON:-none})" >&2

# current clock = the line marked '*' in pp_dpm_*clk; strip to digits (MHz)
read_clk() {
  [[ -r "$1" ]] || return 0
  awk '/\*/{for(i=1;i<=NF;i++){if($i ~ /[0-9]+[MmGg]?[Hh]z/){n=$i;gsub(/[^0-9]/,"",n);print n;exit}}}' "$1"
}
rd() { cat "$1" 2>/dev/null; }

emit() {
  local L="card=\"$CARDNAME\",pci=\"$PCI\""
  local busy vu vt sclk mclk t p tc pw
  busy="$(rd "$DEV/gpu_busy_percent")"
  vu="$(rd "$DEV/mem_info_vram_used")"; vt="$(rd "$DEV/mem_info_vram_total")"
  sclk="$(read_clk "$DEV/pp_dpm_sclk")"; mclk="$(read_clk "$DEV/pp_dpm_mclk")"
  if [[ -n "${HWMON:-}" ]]; then
    t="$(rd "$HWMON/temp1_input")"; p="$(rd "$HWMON/power1_average")"
    # scale with awk -v (value passed as a variable, never built into the program)
    [[ -n "${t:-}" ]] && tc="$(awk -v v="$t" 'BEGIN{printf "%.1f", v/1000}')"
    [[ -n "${p:-}" ]] && pw="$(awk -v v="$p" 'BEGIN{printf "%.2f", v/1000000}')"
  fi

  {
    echo "# HELP amdgpu_busy_percent Discrete GPU utilization (percent)."
    echo "# TYPE amdgpu_busy_percent gauge"
    [[ -n "$busy" ]] && echo "amdgpu_busy_percent{$L} $busy"
    echo "# HELP amdgpu_vram_used_bytes Discrete GPU VRAM used (bytes)."
    echo "# TYPE amdgpu_vram_used_bytes gauge"
    [[ -n "$vu" ]] && echo "amdgpu_vram_used_bytes{$L} $vu"
    echo "# HELP amdgpu_vram_total_bytes Discrete GPU VRAM total (bytes)."
    echo "# TYPE amdgpu_vram_total_bytes gauge"
    [[ -n "$vt" ]] && echo "amdgpu_vram_total_bytes{$L} $vt"
    echo "# HELP amdgpu_sclk_mhz Discrete GPU current core/shader clock (MHz)."
    echo "# TYPE amdgpu_sclk_mhz gauge"
    [[ -n "$sclk" ]] && echo "amdgpu_sclk_mhz{$L} $sclk"
    echo "# HELP amdgpu_mclk_mhz Discrete GPU current memory clock (MHz)."
    echo "# TYPE amdgpu_mclk_mhz gauge"
    [[ -n "$mclk" ]] && echo "amdgpu_mclk_mhz{$L} $mclk"
    echo "# HELP amdgpu_temp_celsius Discrete GPU edge temperature (Celsius)."
    echo "# TYPE amdgpu_temp_celsius gauge"
    [[ -n "${tc:-}" ]] && echo "amdgpu_temp_celsius{$L} $tc"
    echo "# HELP amdgpu_power_watt Discrete GPU average power draw (Watts)."
    echo "# TYPE amdgpu_power_watt gauge"
    [[ -n "${pw:-}" ]] && echo "amdgpu_power_watt{$L} $pw"
  } > "${OUT}.tmp.$$"
  # separate statement so a falsy guard above never blocks the rename
  mv "${OUT}.tmp.$$" "${OUT}"
}

while true; do
  emit || echo "amdgpu-collector: emit failed" >&2
  sleep "${INTERVAL}"
done
