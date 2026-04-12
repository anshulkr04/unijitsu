#!/usr/bin/env bash
#
# 01b-setup-bridge.sh — Set up Xen network bridge (SAFE for SSH)
#
# This script creates xenbr0 bridge using `netplan try` which gives you
# 120 seconds to confirm. If SSH dies, the config auto-reverts.
#
# PREREQUISITES:
#   - Xen installed and running (xl info works)
#   - SSH working
#
# Run as root: sudo bash 01b-setup-bridge.sh
#
set -euo pipefail

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

# ─── Verify Xen is running ──────────────────────────────────────────────────

if ! xl info &>/dev/null; then
    err "Xen is not running. Run 01-install-xen.sh first, reboot, then come back."
fi

log "Xen is running:"
xl info | grep -E "xen_version|free_memory|nr_cpus"

# ─── Check if bridge already exists ─────────────────────────────────────────

if brctl show xenbr0 &>/dev/null 2>&1 && ip addr show xenbr0 &>/dev/null 2>&1; then
    BRIDGE_IP=$(ip -4 addr show xenbr0 | grep inet | awk '{print $2}' | head -1)
    if [[ -n "$BRIDGE_IP" ]]; then
        log "Bridge xenbr0 already exists with IP $BRIDGE_IP"
        log "Nothing to do. Proceed to step 02."
        exit 0
    fi
fi

# ─── Detect current network config ──────────────────────────────────────────

PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
PRIMARY_IP=$(ip -4 addr show "$PRIMARY_IF" | grep inet | awk '{print $2}' | head -1)
PRIMARY_GW=$(ip route | grep default | awk '{print $3}' | head -1)

if [[ -z "$PRIMARY_IF" ]] || [[ -z "$PRIMARY_IP" ]] || [[ -z "$PRIMARY_GW" ]]; then
    err "Could not detect network config. Interface=$PRIMARY_IF IP=$PRIMARY_IP GW=$PRIMARY_GW"
fi

log ""
log "Current network:"
log "  Interface: $PRIMARY_IF"
log "  IP:        $PRIMARY_IP"
log "  Gateway:   $PRIMARY_GW"
log ""

# ─── Backup existing netplan configs ─────────────────────────────────────────

NETPLAN_DIR="/etc/netplan"
BACKUP_DIR="/etc/netplan/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

log "Backing up netplan configs to $BACKUP_DIR"
for f in "$NETPLAN_DIR"/*.yaml "$NETPLAN_DIR"/*.yml; do
    [[ -f "$f" ]] && cp "$f" "$BACKUP_DIR/"
done

# ─── Write bridge config ────────────────────────────────────────────────────

BRIDGE_CONF="${NETPLAN_DIR}/99-xen-bridge.yaml"

log "Writing bridge config..."

# We move the IP, gateway, and DNS from the interface to the bridge.
# The interface becomes a "dumb" member of the bridge.
cat > "$BRIDGE_CONF" << EOF
# Xen bridge for unikernel networking
# Created by 01b-setup-bridge.sh
# xenbr0 inherits the server's IP so SSH keeps working
network:
  version: 2
  renderer: networkd
  ethernets:
    ${PRIMARY_IF}:
      dhcp4: false
      dhcp6: false
  bridges:
    xenbr0:
      interfaces: [${PRIMARY_IF}]
      addresses: [${PRIMARY_IP}]
      routes:
        - to: default
          via: ${PRIMARY_GW}
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      parameters:
        stp: false
        forward-delay: 0
EOF

# Disable other netplan configs that assign an IP to the same interface
# (otherwise two configs will fight over the interface)
for f in "$NETPLAN_DIR"/*.yaml; do
    [[ "$f" == "$BRIDGE_CONF" ]] && continue
    if grep -q "$PRIMARY_IF" "$f" 2>/dev/null; then
        warn "Moving conflicting config out of the way: $f -> ${f}.pre-bridge"
        mv "$f" "${f}.pre-bridge"
    fi
done

log ""
log "Bridge config written:"
cat "$BRIDGE_CONF"
log ""

# ─── Apply with netplan try (THE SAFE WAY) ──────────────────────────────────

warn "═══════════════════════════════════════════════════════════════"
warn "  APPLYING BRIDGE CONFIG WITH 120-SECOND SAFETY TIMEOUT"
warn ""
warn "  netplan try will apply the new config. You have 120 seconds."
warn ""
warn "  IF SSH STAYS ALIVE:"
warn "    → Press ENTER in this terminal to confirm"
warn ""
warn "  IF SSH DIES:"
warn "    → Config auto-reverts after 120 seconds"
warn "    → SSH comes back with the old config"
warn "    → No harm done"
warn ""
warn "  Starting in 5 seconds..."
warn "═══════════════════════════════════════════════════════════════"
sleep 5

log "Running: netplan try --timeout 120"
log ""

# netplan try applies the config and waits for confirmation.
# If you don't press ENTER within 120 seconds, it REVERTS automatically.
# This is the critical safety mechanism for SSH.
if netplan try --timeout 120; then
    log ""
    log "Bridge config CONFIRMED and applied permanently!"
else
    warn ""
    warn "netplan try failed or was not confirmed."
    warn "Config has been REVERTED. Your old networking is restored."
    warn ""
    warn "To debug, check:"
    warn "  cat $BRIDGE_CONF"
    warn "  networkctl status"
    warn ""

    # Restore backed up configs
    log "Restoring original configs from $BACKUP_DIR..."
    rm -f "$BRIDGE_CONF"
    for f in "$NETPLAN_DIR"/*.pre-bridge; do
        [[ -f "$f" ]] && mv "$f" "${f%.pre-bridge}"
    done
    cp "$BACKUP_DIR"/* "$NETPLAN_DIR/" 2>/dev/null || true
    netplan apply 2>/dev/null || true

    err "Bridge setup failed. Original networking restored."
fi

# ─── Verify bridge is working ────────────────────────────────────────────────

log ""
log "Verifying bridge..."

BRIDGE_IP_NEW=$(ip -4 addr show xenbr0 2>/dev/null | grep inet | awk '{print $2}' | head -1)
if [[ -z "$BRIDGE_IP_NEW" ]]; then
    warn "xenbr0 has no IP address. Something may be wrong."
else
    log "xenbr0 IP: $BRIDGE_IP_NEW"
fi

log ""
log "Bridge members:"
brctl show xenbr0 2>/dev/null || ip link show master xenbr0 2>/dev/null || true

log ""
log "Testing gateway connectivity..."
if ping -c 2 -W 3 "$PRIMARY_GW" &>/dev/null; then
    log "Gateway $PRIMARY_GW reachable - network is working!"
else
    warn "Gateway $PRIMARY_GW not reachable via bridge."
    warn "This might fix itself in a few seconds as the bridge settles."
fi

log ""
log "Testing internet connectivity..."
if ping -c 2 -W 5 8.8.8.8 &>/dev/null; then
    log "Internet reachable!"
else
    warn "Internet not reachable. DNS/routing may need time to settle."
fi

# Save bridge name for later scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "xenbr0" > "${SCRIPT_DIR}/.bridge"
echo "$PRIMARY_IF" > "${SCRIPT_DIR}/.primary-if"

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Bridge setup complete!"
log "═══════════════════════════════════════════════════════════════"
log ""
log "  Bridge:    xenbr0"
log "  IP:        $BRIDGE_IP_NEW"
log "  Members:   $PRIMARY_IF"
log "  Gateway:   $PRIMARY_GW"
log ""
log "  Unikernels will use vif='bridge=xenbr0' to get network access."
log ""
log "  NEXT STEP: bash setup/02-install-unikraft.sh"
log ""
