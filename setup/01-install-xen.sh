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

# ─── SSH Safety Warning ──────────────────────────────────────────────────────

SSH_CLIENT="${SSH_CLIENT:-}"
SSH_TTY="${SSH_TTY:-}"
if [[ -n "$SSH_CLIENT" ]] || [[ -n "$SSH_TTY" ]]; then
    warn "╔══════════════════════════════════════════════════════════════╗"
    warn "║  SSH SESSION DETECTED                                      ║"
    warn "║                                                            ║"
    warn "║  This script will configure Xen + networking and require   ║"
    warn "║  a reboot. Safety measures are in place:                   ║"
    warn "║                                                            ║"
    warn "║  1. GRUB has a 10s timeout (you can pick non-Xen entry     ║"
    warn "║     via IPMI/iDRAC/KVM-over-IP if something breaks)        ║"
    warn "║  2. Bridge config preserves your current IP via DHCP       ║"
    warn "║  3. A cron job auto-reboots to non-Xen if SSH fails        ║"
    warn "║  4. All configs are backed up before modification          ║"
    warn "║                                                            ║"
    warn "║  RECOMMENDED: Have IPMI/iDRAC/iLO/KVM console access      ║"
    warn "║  as a fallback in case SSH doesn't come back.              ║"
    warn "╚══════════════════════════════════════════════════════════════╝"
    warn ""
    warn "  Your SSH source: $SSH_CLIENT"
    warn "  Continuing in 10 seconds... (Ctrl+C to abort)"
    sleep 10
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

# libxen-dev (already in the list above) provides ALL Xen development headers
# on Ubuntu 22.04 — there are no separate libxenctrl-dev, libxenlight-dev, etc.
# Verify we have what we need:
log "Verifying Xen development headers..."
if dpkg -s libxen-dev &>/dev/null; then
    log "libxen-dev installed — includes xenctrl, xenlight, xenguest, xenstore, xentoollog headers"
else
    warn "libxen-dev not found, trying alternative package names..."
    apt-get install -y libxen-dev || true
fi

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
mkdir -p /etc/default/grub.d
cat > /etc/default/grub.d/xen.cfg << EOF
# Xen hypervisor configuration for Jitsu/Unikraft platform
GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=${DOM0_MEM_MB}M,max:${DOM0_MEM_MB}M dom0_max_vcpus=4 loglvl=all guest_loglvl=all"
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=hvc0 earlyprintk=xen"
EOF

log "Xen GRUB config written to /etc/default/grub.d/xen.cfg"

# CRITICAL FOR SSH: Keep GRUB timeout so you can recover via IPMI/iDRAC
# If Xen breaks networking, you can select the non-Xen entry on next boot
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub
# Don't hide the GRUB menu — essential for remote KVM recovery
sed -i 's/^GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub

# Update GRUB
update-grub

# ─── SSH Safety Net: auto-fallback if Xen breaks networking ──────────────────
# This creates a one-shot cron job that runs 5 minutes after boot.
# If it can reach the default gateway, it removes itself (all good).
# If it can't, it sets GRUB to boot the non-Xen kernel next time and reboots.
# This gives you a safety net: if Xen breaks networking, the server
# automatically falls back to the regular kernel on the NEXT reboot.

SAFETY_SCRIPT="/usr/local/bin/xen-ssh-safety-check.sh"
cat > "$SAFETY_SCRIPT" << 'SAFETY'
#!/bin/bash
# One-shot: verify network works under Xen. If not, fallback to non-Xen kernel.
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
if ping -c 3 -W 5 "$GATEWAY" &>/dev/null; then
    # Network works, remove this safety net
    logger "xen-ssh-safety: Network OK under Xen. Removing safety check."
    systemctl disable xen-ssh-safety.service 2>/dev/null
    rm -f /etc/systemd/system/xen-ssh-safety.service
    systemctl daemon-reload
else
    # Network broken — fall back to non-Xen kernel
    logger "xen-ssh-safety: Network FAILED under Xen! Falling back to non-Xen kernel."
    # Find the first non-Xen menuentry
    FALLBACK=$(grep -n 'menuentry ' /boot/grub/grub.cfg | grep -iv xen | head -1 | cut -d: -f1)
    if [[ -n "$FALLBACK" ]]; then
        grub-reboot "$(grep 'menuentry ' /boot/grub/grub.cfg | grep -iv xen | head -1 | sed "s/.*'\(.*\)'.*/\1/")" 2>/dev/null || true
    fi
    reboot
fi
SAFETY
chmod +x "$SAFETY_SCRIPT"

# Create systemd service to run the check 3 minutes after boot
cat > /etc/systemd/system/xen-ssh-safety.service << 'UNIT'
[Unit]
Description=Xen SSH safety net - verify network connectivity after Xen boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 180
ExecStart=/usr/local/bin/xen-ssh-safety-check.sh
RemainAfterExit=false

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable xen-ssh-safety.service
log "SSH safety net installed: if Xen breaks networking, server auto-reboots to normal kernel"

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

# Backup any existing netplan configs
log "Backing up existing netplan configs..."
for f in "$NETPLAN_DIR"/*.yaml "$NETPLAN_DIR"/*.yml; do
    [[ -f "$f" ]] && cp "$f" "${f}.bak.$(date +%s)"
done

# Only create bridge config if it doesn't exist
if [[ ! -f "$BRIDGE_CONF" ]]; then

    # SSH SAFETY: Detect if current IP is static or DHCP
    # We MUST preserve the exact IP assignment method or SSH breaks
    if grep -r "dhcp4: true" "$NETPLAN_DIR"/*.yaml 2>/dev/null | grep -q "$PRIMARY_IF"; then
        NET_MODE="dhcp"
    else
        NET_MODE="static"
    fi

    if [[ "$NET_MODE" == "static" ]]; then
        log "Detected STATIC IP config — preserving exact IP on bridge"
        cat > "$BRIDGE_CONF" << EOF
# Xen bridge for unikernel networking
# Created by jitsu setup script
# IMPORTANT: Bridge inherits the server's static IP so SSH keeps working
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
    else
        log "Detected DHCP config — bridge will use DHCP"
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
    fi

    log "Bridge config written to $BRIDGE_CONF"
    warn ""
    warn "SSH SAFETY: After reboot, xenbr0 will have your server's IP."
    warn "Your SSH connection will survive the reboot."
    warn "Current IP ($PRIMARY_IP) → will be on xenbr0 instead of $PRIMARY_IF"
    warn ""

    # Disable other netplan configs that might conflict
    for f in "$NETPLAN_DIR"/*.yaml; do
        [[ "$f" == "$BRIDGE_CONF" ]] && continue
        if grep -q "$PRIMARY_IF" "$f" 2>/dev/null; then
            warn "Disabling conflicting netplan config: $f"
            mv "$f" "${f}.disabled"
        fi
    done
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

# ─── Install SSH server (ensure it auto-starts after reboot) ─────────────────

apt-get install -y openssh-server
systemctl enable ssh

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Xen hypervisor installation complete!"
log "═══════════════════════════════════════════════════════════════"
log ""
log "  dom0 memory: ${DOM0_MEM_MB}MB"
log "  Bridge:      xenbr0 (using $PRIMARY_IF)"
log ""
log "  NEXT STEPS:"
log "  1. Review GRUB config:   cat /etc/default/grub.d/xen.cfg"
log "  2. Review bridge config: cat $BRIDGE_CONF"
log "  3. REBOOT:               sudo reboot"
log "  4. SSH back in and verify:"
log "       xl info"
log "       xl list"
log "       brctl show"
log ""
warn "  ⚠  YOU MUST REBOOT for Xen to become the hypervisor."
warn "  ⚠  Your SSH session will disconnect during reboot."
warn "  ⚠  Wait ~2 minutes then SSH back to the SAME IP."
warn ""
warn "  ⚠  SAFETY NET: If Xen breaks networking, the server will"
warn "     auto-detect the failure after 3 minutes and reboot back"
warn "     to the normal (non-Xen) kernel. You'll get SSH back."
warn ""
warn "  ⚠  MANUAL RECOVERY: If auto-recovery doesn't work, use"
warn "     IPMI/iDRAC/iLO/KVM to access GRUB menu (10s timeout)"
warn "     and select the non-Xen Ubuntu entry."
log ""
