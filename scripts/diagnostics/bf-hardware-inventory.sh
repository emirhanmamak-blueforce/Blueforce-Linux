#!/usr/bin/env bash
#
# bf-hardware-inventory.sh - Scan field-terminal hardware and emit JSON + Markdown.
#
# Covers every field in docs/02-DEVICE-NAMING-AND-INVENTORY.md §9:
# Manufacturer/Model/Serial/BIOS/CPU/RAM/Disk/SMART/NIC/MAC/GPU/USB/
# SerialPorts/Kernel/Arch/TPM/Virt/Temps. Missing probes report
# "unknown" instead of aborting. Never prints secrets, keys, or passwords.
#
# Install: install -m 0755 bf-hardware-inventory.sh /usr/local/bin/bf-hardware-inventory.sh
# Usage: bf-hardware-inventory.sh [--dealer-id ID] [--out-dir DIR] [--json] [--markdown] [--help]
#
set -euo pipefail

DEALER_ID=""
OUT_DIR=""
MODE="both"  # json | markdown | both

usage() {
    cat <<'EOF'
Usage: bf-hardware-inventory.sh [--dealer-id ID] [--out-dir DIR] [--json] [--markdown] [--help]

Scan hardware and emit inventory (JSON for machines, Markdown for humans).

Options:
  --dealer-id ID   8-digit dealer number (validates ^[0-9]{8}$ when given)
  --out-dir DIR    Write BF-<id>.json and BF-<id>.md into DIR
                   (requires --dealer-id; default filenames use hostname)
  --json           Print only JSON to stdout
  --markdown       Print only Markdown to stdout
  --help           Show this help and exit

Fields (doc 02 §9): Manufacturer, Model, Serial, BIOS, CPU, RAM,
Disk, SMART, NIC, MAC, GPU, USB, SerialPorts, Kernel, Arch, TPM,
Virt, Temps. Unavailable probes report "unknown".
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dealer-id) DEALER_ID="${2:?missing value for --dealer-id}"; shift 2 ;;
        --out-dir) OUT_DIR="${2:?missing value for --out-dir}"; shift 2 ;;
        --json) MODE="json"; shift ;;
        --markdown) MODE="markdown"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -n "${DEALER_ID}" ]] && ! [[ "${DEALER_ID}" =~ ^[0-9]{8}$ ]]; then
    echo "ERROR: --dealer-id must match ^[0-9]{8}$ (got: ${DEALER_ID})" >&2
    exit 2
fi
if [[ -n "${OUT_DIR}" && -z "${DEALER_ID}" ]]; then
    echo "ERROR: --out-dir requires --dealer-id" >&2
    exit 2
fi

set +e  # probes must not abort the report

HOST="$(hostname 2>/dev/null || echo unknown)"
if [[ -n "${DEALER_ID}" ]]; then
    DEVICE_ID="BF-${DEALER_ID}"
    LOWER_HOST="bf-${DEALER_ID}"
else
    DEVICE_ID="$(echo "${HOST}" | tr '[:lower:]' '[:upper:]')"
    LOWER_HOST="$(echo "${HOST}" | tr '[:upper:]' '[:lower:]')"
fi
NOW="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown)"

json_escape() { # stdin -> JSON string body
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null || sed 's/"/\\"/g' | tr -d '\n'
}
val() { # $1 raw -> "unknown" fallback, no newlines
    local v="$1"
    v="$(echo "${v}" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${v}" ]] && echo "unknown" || echo "${v}"
}

# --- Probes (all fields from doc 02) ---
MANUFACTURER="$(val "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || dmidecode -s system-manufacturer 2>/dev/null)")"
MODEL="$(val "$(cat /sys/class/dmi/id/product_name 2>/dev/null || dmidecode -s system-product-name 2>/dev/null)")"
SERIAL="$(val "$(cat /sys/class/dmi/id/product_serial 2>/dev/null || dmidecode -s system-serial-number 2>/dev/null)")"
BIOS_VENDOR="$(val "$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || dmidecode -s bios-vendor 2>/dev/null)")"
BIOS_VERSION="$(val "$(cat /sys/class/dmi/id/bios_version 2>/dev/null || dmidecode -s bios-version 2>/dev/null)")"
BIOS_DATE="$(val "$(cat /sys/class/dmi/id/bios_date 2>/dev/null || dmidecode -s bios-release-date 2>/dev/null)")"
CPU_MODEL="$(val "$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || lscpu 2>/dev/null | awk -F': *' '/Model name/ {print $2; exit}')")"
CPU_CORES="$(val "$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)")"
ARCH="$(val "$(uname -m 2>/dev/null)")"
KERNEL="$(val "$(uname -sr 2>/dev/null)")"
MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)"
MEMORY_MB="$([ -n "${MEM_KB}" ] && echo $((MEM_KB / 1024)) || echo "unknown")"
MEMORY_STR="$([ "${MEMORY_MB}" != "unknown" ] && echo "${MEMORY_MB} MB" || echo "unknown")"

DISKS="$(lsblk -d -n -o NAME,SIZE,TYPE,ROTA 2>/dev/null || echo unknown)"
GPU="$(val "$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -3 | sed 's/^[^:]*: //')")"
NIC_LIST="$(val "$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | tr '\n' ',' | sed 's/,$//')")"
MAC_LIST="$(val "$(for n in /sys/class/net/*; do [[ "$(basename "$n")" == lo ]] && continue; cat "$n/address" 2>/dev/null; done | tr '\n' ',' | sed 's/,$//')")"
USB_LIST="$(val "$(lsusb 2>/dev/null | head -20 || echo '')")"
SERIAL_PORTS="$(val "$(ls /dev/ttyS* /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | tr '\n' ',' | sed 's/,$//')")"
TPM="$(val "$( ([ -c /dev/tpm0 ] && echo -n 'present (/dev/tpm0)') ; dmesg 2>/dev/null | grep -im1 'tpm' | head -1 | sed 's/^/ /')")"
VIRT="$(val "$(systemd-detect-virt 2>/dev/null || echo none)")"
TEMPS="$(val "$( (cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -5 | tr '\n' ' '); sensors 2>/dev/null | grep -iE 'core|temp|package' | head -5 | tr '\n' ';')")"

SMART_SUMMARY="unknown"
if command -v smartctl >/dev/null 2>&1; then
    SMART_SUMMARY="$(for dev in /dev/sd? /dev/nvme?n1; do
        [[ -b "${dev}" ]] || continue
        echo -n "${dev}: "
        smartctl -H "${dev}" 2>/dev/null | grep -im1 'health\|result' | sed 's/^[[:space:]]*//' | head -1
        echo -n '; '
    done)"
    SMART_SUMMARY="$(val "${SMART_SUMMARY}")"
else
    SMART_SUMMARY="smartctl not installed"
fi

OS_PRETTY="$(val "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')")"

E() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null || printf '%s' "$1"; }

JSON="$(cat <<EOF
{
  "schema_version": 1,
  "device_id": "$(E "${DEVICE_ID}")",
  "hostname": "$(E "${LOWER_HOST}")",
  "dealer_id": "$(E "${DEALER_ID:-unknown}")",
  "collected_at": "$(E "${NOW}")",
  "manufacturer": "$(E "${MANUFACTURER}")",
  "model": "$(E "${MODEL}")",
  "serial": "$(E "${SERIAL}")",
  "bios": {"vendor": "$(E "${BIOS_VENDOR}")", "version": "$(E "${BIOS_VERSION}")", "date": "$(E "${BIOS_DATE}")"},
  "cpu": {"model": "$(E "${CPU_MODEL}")", "cores": "$(E "${CPU_CORES}")", "arch": "$(E "${ARCH}")"},
  "memory_mb": "$(E "${MEMORY_MB}")",
  "disks": "$(E "${DISKS}")",
  "smart": "$(E "${SMART_SUMMARY}")",
  "network": {"interfaces": "$(E "${NIC_LIST}")", "macs": "$(E "${MAC_LIST}")"},
  "gpu": {"model": "$(E "${GPU}")"},
  "usb": "$(E "${USB_LIST}")",
  "serial_ports": "$(E "${SERIAL_PORTS}")",
  "os": {"distro": "$(E "${OS_PRETTY}")", "kernel": "$(E "${KERNEL}")"},
  "tpm": "$(E "${TPM}")",
  "virt": "$(E "${VIRT}")",
  "temps": "$(E "${TEMPS}")",
  "notes": ""
}
EOF
)"

MD="$(cat <<EOF
# Donanım Envanteri — ${DEVICE_ID}

| Field | Value |
|---|---|
| Device ID | ${DEVICE_ID} |
| Hostname | ${LOWER_HOST} |
| Dealer ID | ${DEALER_ID:-unknown} |
| Collected at | ${NOW} |
| Manufacturer | ${MANUFACTURER} |
| Model | ${MODEL} |
| Serial | ${SERIAL} |
| BIOS Vendor | ${BIOS_VENDOR} |
| BIOS Version | ${BIOS_VERSION} |
| BIOS Date | ${BIOS_DATE} |
| CPU | ${CPU_MODEL} (${CPU_CORES} cores) |
| Arch | ${ARCH} |
| Kernel | ${KERNEL} |
| RAM | ${MEMORY_STR} |
| Disk | ${DISKS} |
| SMART | ${SMART_SUMMARY} |
| NIC | ${NIC_LIST} |
| MAC | ${MAC_LIST} |
| GPU | ${GPU} |
| USB | ${USB_LIST} |
| Serial Ports | ${SERIAL_PORTS} |
| TPM | ${TPM} |
| Virt | ${VIRT} |
| Temps | ${TEMPS} |
| OS | ${OS_PRETTY} |
EOF
)"

case "${MODE}" in
    json) printf '%s\n' "${JSON}" ;;
    markdown) printf '%s\n' "${MD}" ;;
    both)
        if [[ -n "${OUT_DIR}" ]]; then
            mkdir -p "${OUT_DIR}"
            printf '%s\n' "${JSON}" > "${OUT_DIR}/BF-${DEALER_ID}.json"
            printf '%s\n' "${MD}" > "${OUT_DIR}/BF-${DEALER_ID}.md"
            echo "wrote ${OUT_DIR}/BF-${DEALER_ID}.json ${OUT_DIR}/BF-${DEALER_ID}.md"
        else
            printf '%s\n\n%s\n' "${JSON}" "${MD}"
        fi
        ;;
esac
