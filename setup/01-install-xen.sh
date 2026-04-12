#!/usr/bin/env bash
#
# 01-install-xen.sh — Install Xen Hypervisor on Ubuntu 22.04
#
# SAFE VERSION: Only installs Xen packages + configures GRUB.
# Does NOT touch networking. Does NOT create bridges.
# Networking is handled separately in 01b-setup-bridge.sh
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
    log "You can skip this step and go to 01b-setup-bridge.sh"
    exit 0
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
    iproute2 \
    openssh-server

# Verify Xen dev headers
log "Verifying Xen development headers..."
if dpkg -s libxen-dev &>/dev/null; then
    log "libxen-dev installed (includes xenctrl, xenlight, xenguest, xenstore headers)"
else
    warn "libxen-dev not found after install — Jitsu build may fail later"
fi

# Ensure SSH survives reboot
systemctl enable ssh

# ─── Configure GRUB for Xen ─────────────────────────────────────────────────

log "Configuring GRUB to boot Xen..."

# Detect total RAM
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
DOM0_MEM_MB=$(( TOTAL_RAM_MB / 4 ))
[[ $DOM0_MEM_MB -lt 2048 ]] && DOM0_MEM_MB=2048
[[ $DOM0_MEM_MB -lt 4096 ]] && [[ $TOTAL_RAM_MB -gt 8192 ]] && DOM0_MEM_MB=4096

log "Total RAM: ${TOTAL_RAM_MB}MB, dom0 allocation: ${DOM0_MEM_MB}MB"
log "Free for unikernels: $(( TOTAL_RAM_MB - DOM0_MEM_MB ))MB"

# Backup GRUB config
cp /etc/default/grub "/etc/default/grub.bak.$(date +%s)"

# Write Xen GRUB config
mkdir -p /etc/default/grub.d
cat > /etc/default/grub.d/xen.cfg << EOF
# Xen hypervisor configuration
GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=${DOM0_MEM_MB}M,max:${DOM0_MEM_MB}M dom0_max_vcpus=4 loglvl=all guest_loglvl=all"
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=hvc0 earlyprintk=xen"
EOF

# Keep GRUB menu visible (10s timeout) for recovery
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub
sed -i 's/^GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub

update-grub

# ─── Enable Xen services ────────────────────────────────────────────────────

log "Enabling Xen services..."
systemctl enable xen-qemu-dom0-disk-backend.service 2>/dev/null || true
systemctl enable xen-init-dom0.service 2>/dev/null || true
systemctl enable xenconsoled.service 2>/dev/null || true

# ─── Done ────────────────────────────────────────────────────────────────────

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Xen hypervisor installed!"
log "═══════════════════════════════════════════════════════════════"
log ""
log "  dom0 memory:     ${DOM0_MEM_MB}MB"
log "  Networking:      UNTOUCHED (your SSH is safe)"
log ""
log "  WHAT TO DO NOW:"
log ""
log "  1. Reboot:       sudo reboot"
log "  2. SSH back in:  ssh root@$(hostname -I | awk '{print $1}')"
log "  3. Verify:       xl info"
log "  4. Then run:     sudo bash setup/01b-setup-bridge.sh"
log ""
warn "  This script did NOT change networking."
warn "  Your SSH connection will survive the reboot."
log ""
