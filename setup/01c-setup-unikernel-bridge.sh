#!/usr/bin/env bash
#
# 01c-setup-unikernel-bridge.sh — Private bridge for unikernel networking
#
# Creates a SEPARATE bridge (ukbr0, 10.0.0.1/24) for unikernel traffic.
# dom0 NATs unikernel traffic to the internet.
#
# WHY a separate bridge instead of xenbr0:
#   xenbr0 holds the server's public IP (140.82.51.42).
#   Vultr (and most cloud providers) use MAC-based anti-spoofing — they
#   silently drop traffic from IPs/MACs not registered to the server.
#   A unikernel on xenbr0 with a "new" IP gets no traffic at all.
#
#   Solution: private subnet (10.0.0.x) on a separate bridge.
#   dom0 routes/NATs for unikernels. Jitsu talks to unikernels at 10.0.0.x.
#
# Architecture after this script:
#   Internet → xenbr0 (140.82.51.42) → dom0 → NAT → ukbr0 (10.0.0.1) → unikernels
#
# Run as root: sudo bash 01c-setup-unikernel-bridge.sh
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

if [[ $EUID -ne 0 ]]; then err "Run as root"; fi

UNIKERNEL_BRIDGE="ukbr0"
UNIKERNEL_GW="10.0.0.1"
UNIKERNEL_SUBNET="10.0.0.0/24"

# ─── Check if already set up ────────────────────────────────────────────────

if ip addr show "$UNIKERNEL_BRIDGE" &>/dev/null; then
    GW_IP=$(ip -4 addr show "$UNIKERNEL_BRIDGE" | grep inet | awk '{print $2}' | head -1)
    if [[ "$GW_IP" == "${UNIKERNEL_GW}/24" ]]; then
        log "ukbr0 already configured as ${UNIKERNEL_GW}/24 — nothing to do."
        log "NEXT STEP: bash setup/02-install-unikraft.sh"
        exit 0
    fi
fi

# ─── Create the bridge ──────────────────────────────────────────────────────

log "Creating private bridge $UNIKERNEL_BRIDGE for unikernel networking..."

# Create bridge (brctl or ip link)
if command -v brctl &>/dev/null; then
    brctl addbr "$UNIKERNEL_BRIDGE" 2>/dev/null || true
    brctl stp "$UNIKERNEL_BRIDGE" off
else
    ip link add name "$UNIKERNEL_BRIDGE" type bridge 2>/dev/null || true
fi

ip link set "$UNIKERNEL_BRIDGE" up
ip addr add "${UNIKERNEL_GW}/24" dev "$UNIKERNEL_BRIDGE" 2>/dev/null || true

log "Bridge $UNIKERNEL_BRIDGE created with IP ${UNIKERNEL_GW}/24"

# ─── Enable IP forwarding ───────────────────────────────────────────────────

log "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# Make persistent
if grep -q "net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/#*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# ─── Set up NAT (masquerade unikernel traffic) ──────────────────────────────

PUBLIC_IF=$(ip route | grep default | awk '{print $5}' | head -1)
log "Setting up NAT: $UNIKERNEL_SUBNET → $PUBLIC_IF..."

# Install iptables-persistent if available (to survive reboots)
apt-get install -y iptables-persistent 2>/dev/null || true

# Remove any existing masquerade rules for this subnet to avoid duplicates
iptables -t nat -D POSTROUTING -s "$UNIKERNEL_SUBNET" -o "$PUBLIC_IF" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "$UNIKERNEL_BRIDGE" -o "$PUBLIC_IF" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$PUBLIC_IF" -o "$UNIKERNEL_BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# Add the rules
iptables -t nat -A POSTROUTING -s "$UNIKERNEL_SUBNET" -o "$PUBLIC_IF" -j MASQUERADE
iptables -A FORWARD -i "$UNIKERNEL_BRIDGE" -o "$PUBLIC_IF" -j ACCEPT
iptables -A FORWARD -i "$PUBLIC_IF" -o "$UNIKERNEL_BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT

# Save rules
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true

log "NAT configured"

# ─── Make bridge persistent across reboots ──────────────────────────────────

log "Making bridge persistent via /etc/rc.local..."

RC_LOCAL="/etc/rc.local"
MARKER="# ukbr0 unikernel bridge"

if ! grep -q "$MARKER" "$RC_LOCAL" 2>/dev/null; then
    # Create rc.local if it doesn't exist
    if [[ ! -f "$RC_LOCAL" ]]; then
        cat > "$RC_LOCAL" << 'EOF'
#!/bin/bash
exit 0
EOF
        chmod +x "$RC_LOCAL"
    fi

    # Insert before the final exit 0
    sed -i "s|^exit 0|${MARKER}\nip link add name ukbr0 type bridge 2>/dev/null || true\nip link set ukbr0 up\nip addr add 10.0.0.1/24 dev ukbr0 2>/dev/null || true\necho 1 > /proc/sys/net/ipv4/ip_forward\n\nexit 0|" "$RC_LOCAL"
fi

# ─── Verify ─────────────────────────────────────────────────────────────────

log ""
log "Verification:"
log "  Bridge:    $(ip link show ukbr0 | head -1)"
log "  IP:        $(ip -4 addr show ukbr0 | grep inet | awk '{print $2}')"
log "  Forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"
log "  NAT rules:"
iptables -t nat -L POSTROUTING -n | grep 10.0.0 || true

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Private unikernel bridge ready!"
log "═══════════════════════════════════════════════════════════════"
log ""
log "  Bridge:   ukbr0"
log "  dom0 IP:  10.0.0.1  (gateway for unikernels)"
log "  Unikernel IPs: 10.0.0.100, 10.0.0.101, ..."
log ""
log "  Unikernels go on ukbr0 with IPs in 10.0.0.x/24"
log "  dom0 NATs their traffic to the internet"
log ""
log "  NEXT STEP: bash setup/02-install-unikraft.sh"
log ""

# Save for later scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "ukbr0" > "${SCRIPT_DIR}/.unikernel-bridge"
echo "10.0.0.1" > "${SCRIPT_DIR}/.unikernel-gateway"
echo "10.0.0" > "${SCRIPT_DIR}/.unikernel-subnet-prefix"
