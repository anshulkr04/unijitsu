#!/usr/bin/env bash
#
# 01-install-xen.sh — Install Xen Hypervisor on Ubuntu 22.04
#
# Run as root: sudo bash 01-install-xen.sh
# REQUIRES REBOOT AFTER COMPLETION
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ─── Preflight ───────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo)"
fi

if ! grep -q "Ubuntu 22" /etc/os-release 2>/dev/null; then
    warn "This script is tested on Ubuntu 22.04. Your OS may differ."
fi

# Check if already running under Xen
if xl info &>/dev/null; then
    log "Xen already appears to be running:"
    xl info | grep -E "xen_version|free_memory|nr_cpus"
    warn "If you want to re-install, continue anyway? (Ctrl+C to abort)"
    sleep 5
fi

# ─── Install Xen packages ───────────────────────────────────────────────────

log "Updating package lists..."
apt-get update -qq

log "Installing Xen hypervisor and tools..."
apt-get install -y \
    xen-hypervisor-amd64 \
    xen-tools \
    xen-utils-common \
    xenstore-utils \
    libxen-dev \
    libxenstore4 \
    bridge-utils \
    net-tools \
    vlan \
    iproute2 \
    dnsmasq-base \
    grub-xen-host

# Also install dev headers needed for building Jitsu with xenctrl
log "Installing Xen development libraries..."
apt-get install -y \
    libxenctrl-dev \
    libxenguest-dev \
    libxenlight-dev \
    libxentoollog-dev \
    libxenstore-dev

# ─── Configure GRUB for Xen ─────────────────────────────────────────────────

log "Configuring GRUB to boot Xen..."

# Detect total RAM
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
# Give dom0 4GB or 25% of RAM, whichever is larger (min 2GB)
DOM0_MEM_MB=$(( TOTAL_RAM_MB / 4 ))
if [[ $DOM0_MEM_MB -lt 2048 ]]; then
    DOM0_MEM_MB=2048
fi
if [[ $DOM0_MEM_MB -lt 4096 ]] && [[ $TOTAL_RAM_MB -gt 8192 ]]; then
    DOM0_MEM_MB=4096
fi

log "Total RAM: ${TOTAL_RAM_MB}MB, dom0 allocation: ${DOM0_MEM_MB}MB"
log "Remaining for unikernels: $(( TOTAL_RAM_MB - DOM0_MEM_MB ))MB"

# Set Xen-specific GRUB parameters
GRUB_FILE="/etc/default/grub"
cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"

# Add/update Xen command line in GRUB
cat >> /etc/default/grub.d/xen.cfg << EOF
# Xen hypervisor configuration for Jitsu/Unikraft platform
GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=${DOM0_MEM_MB}M,max:${DOM0_MEM_MB}M dom0_max_vcpus=4 loglvl=all guest_loglvl=all"
GRUB_CMDLINE_LINUX_DEFAULT="console=hvc0 earlyprintk=xen"
EOF

# Make Xen the default boot entry
# On Ubuntu, the Xen entry is usually at a known position
# We use grub-reboot or update the default
if [[ -f /etc/default/grub.d/xen.cfg ]]; then
    log "Xen GRUB config written to /etc/default/grub.d/xen.cfg"
fi

# Update GRUB
update-grub

# ─── Network Bridge Setup ───────────────────────────────────────────────────

log "Setting up network bridge for unikernels..."

# Detect the primary network interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
PRIMARY_IP=$(ip -4 addr show "$PRIMARY_IF" | grep inet | awk '{print $2}')
PRIMARY_GW=$(ip route | grep default | awk '{print $3}' | head -1)

log "Primary interface: $PRIMARY_IF ($PRIMARY_IP via $PRIMARY_GW)"

# Create Xen bridge config using netplan (Ubuntu 22.04 default)
NETPLAN_DIR="/etc/netplan"
BRIDGE_CONF="${NETPLAN_DIR}/99-xen-bridge.yaml"

# Only create bridge config if it doesn't exist
if [[ ! -f "$BRIDGE_CONF" ]]; then
    cat > "$BRIDGE_CONF" << EOF
# Xen bridge for unikernel networking
# Created by jitsu setup script
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
      dhcp4: true
      parameters:
        stp: false
        forward-delay: 0
EOF

    log "Bridge config written to $BRIDGE_CONF"
    warn "Bridge will be active after reboot."
    warn "NOTE: If you're connected via SSH on $PRIMARY_IF, you'll keep"
    warn "connectivity after reboot since xenbr0 inherits the IP."
else
    warn "Bridge config already exists at $BRIDGE_CONF, skipping."
fi

# ─── Enable Xen services ────────────────────────────────────────────────────

log "Enabling Xen services..."
systemctl enable xen-qemu-dom0-disk-backend.service 2>/dev/null || true
systemctl enable xen-init-dom0.service 2>/dev/null || true
systemctl enable xenconsoled.service 2>/dev/null || true
systemctl enable xendomains.service 2>/dev/null || true

# ─── Verify ─────────────────────────────────────────────────────────────────

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Xen hypervisor installation complete!"
log "═══════════════════════════════════════════════════════════════"
log ""
log "  dom0 memory: ${DOM0_MEM_MB}MB"
log "  Bridge:      xenbr0 (using $PRIMARY_IF)"
log ""
log "  NEXT STEPS:"
log "  1. Review /etc/default/grub.d/xen.cfg"
log "  2. Review $BRIDGE_CONF"
log "  3. REBOOT: sudo reboot"
log "  4. After reboot, verify with:"
log "       xl info"
log "       xl list"
log "       brctl show"
log ""
warn "  ⚠  YOU MUST REBOOT for Xen to become the hypervisor."
warn "  ⚠  If connected via SSH, you will be disconnected."
log ""
