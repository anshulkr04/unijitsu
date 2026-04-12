#!/usr/bin/env bash
#
# 06-run-jitsu.sh — Start Jitsu with the test unikernel registered
#
# Run as root: sudo bash 06-run-jitsu.sh
# Requires: Xen running, unikernel built, Jitsu built
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JITSU_DIR="${SCRIPT_DIR}/.."
JITSU_BIN="${JITSU_DIR}/bin/jitsu"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo)"
fi

if [[ ! -f "$JITSU_BIN" ]]; then
    err "Jitsu binary not found at $JITSU_BIN. Run 05-install-jitsu.sh first."
fi

if ! xl info &>/dev/null; then
    err "Xen not running. Did you reboot after step 01?"
fi

# ─── Load saved config from previous steps ───────────────────────────────────

# Unikernel image
if [[ -f "${SCRIPT_DIR}/.last-built-image" ]]; then
    XEN_IMAGE=$(cat "${SCRIPT_DIR}/.last-built-image")
else
    XEN_IMAGE=$(find "${SCRIPT_DIR}/test-agent" -name "*xen*x86*" -type f 2>/dev/null | head -1)
fi

if [[ -z "${XEN_IMAGE:-}" ]] || [[ ! -f "$XEN_IMAGE" ]]; then
    err "Cannot find unikernel image. Run 03-build-test-unikernel.sh first."
fi

# Bridge
if [[ -f "${SCRIPT_DIR}/.bridge" ]]; then
    BRIDGE=$(cat "${SCRIPT_DIR}/.bridge")
else
    BRIDGE=$(brctl show 2>/dev/null | awk 'NR>1 && $1 != "" {print $1}' | head -1)
    BRIDGE="${BRIDGE:-xenbr0}"
fi

# IP
if [[ -f "${SCRIPT_DIR}/.unikernel-ip" ]]; then
    UNIKERNEL_IP=$(cat "${SCRIPT_DIR}/.unikernel-ip")
else
    BRIDGE_IP=$(ip -4 addr show "$BRIDGE" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    UNIKERNEL_IP=$(echo "${BRIDGE_IP:-10.0.0.1}" | sed 's/\.[0-9]*$/.100/')
fi

DNS_NAME="test-agent.unikernel.local"
VM_NAME="test-agent"
VM_MEMORY=32000  # in KB (32MB)
TTL=60           # seconds before scale-to-zero

log "Configuration:"
log "  Image:  $XEN_IMAGE"
log "  IP:     $UNIKERNEL_IP"
log "  Bridge: $BRIDGE"
log "  DNS:    $DNS_NAME"
log "  TTL:    ${TTL}s (destroy after ${TTL}s idle)"

# ─── Destroy any existing test domain ────────────────────────────────────────

xl destroy "$VM_NAME" 2>/dev/null || true

# ─── Start Jitsu ─────────────────────────────────────────────────────────────

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Starting Jitsu DNS-triggered orchestrator"
log "═══════════════════════════════════════════════════════════════"
log ""
log "  Jitsu is now listening on UDP port 53 for DNS queries."
log "  It will boot the unikernel when it receives a query for:"
log ""
log "    $DNS_NAME"
log ""
log "  TEST IT (from another terminal):"
log ""
log "    dig @127.0.0.1 $DNS_NAME"
log "    # → Jitsu boots the unikernel and returns $UNIKERNEL_IP"
log ""
log "    curl http://${UNIKERNEL_IP}:8080/health"
log "    # → {\"status\":\"ok\",\"agent\":\"test-agent\"}"
log ""
log "    # Wait ${TTL}s without any DNS queries..."
log "    # → Jitsu destroys the unikernel (scale to zero)"
log ""
log "    xl list"
log "    # → test-agent should disappear after TTL"
log ""
log "  Press Ctrl+C to stop Jitsu."
log ""

# Determine which backend to use
# Jitsu supports: libvirt, libxl, xapi
# We prefer libxl (direct Xen toolstack, lowest overhead)
BACKEND="libxl"

# OCaml env (needed for Jitsu's dynamic loading)
eval $(opam env --switch=jitsu 2>/dev/null) || true

# Run Jitsu
# Format: jitsu [options] dns=<domain>,ip=<ip>,kernel=<path>,memory=<kb>,name=<name>,nic=<bridge>
exec "$JITSU_BIN" \
    -x "$BACKEND" \
    -f \
    -l 53 \
    -m destroy \
    -t "$TTL" \
    "dns=${DNS_NAME},ip=${UNIKERNEL_IP},kernel=${XEN_IMAGE},memory=${VM_MEMORY},name=${VM_NAME},nic=${BRIDGE}"
