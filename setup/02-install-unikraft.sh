#!/usr/bin/env bash
#
# 02-install-unikraft.sh — Install Unikraft toolchain (kraft CLI + build deps)
#
# Run as root: sudo bash 02-install-unikraft.sh
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

# ─── Install build dependencies ─────────────────────────────────────────────

log "Installing build essentials and Unikraft dependencies..."
apt-get update -qq
apt-get install -y \
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    flex \
    bison \
    libncurses-dev \
    libelf-dev \
    libssl-dev \
    gawk \
    git \
    wget \
    curl \
    unzip \
    bc \
    uuid-runtime \
    python3 \
    python3-pip \
    python3-venv \
    socat \
    qemu-system-x86 \
    qemu-utils

# ─── Install kraft CLI ───────────────────────────────────────────────────────

log "Installing kraft CLI..."

# kraft is distributed as a Go binary or can be installed via pip
# The recommended way is via the official installer

# Method 1: pip install (works reliably on Ubuntu 22.04)
if command -v kraft &>/dev/null; then
    warn "kraft already installed: $(kraft --version 2>/dev/null || echo 'unknown version')"
else
    # Install via the official method
    pip3 install git+https://github.com/unikraft/kraftkit.git 2>/dev/null || {
        # Fallback: install via Go binary release
        log "pip install failed, trying binary release..."
        KRAFT_VERSION="0.9.1"
        KRAFT_ARCH="linux_amd64"
        KRAFT_URL="https://github.com/unikraft/kraftkit/releases/latest/download/kraft_${KRAFT_ARCH}.tar.gz"
        
        cd /tmp
        wget -q "$KRAFT_URL" -O kraft.tar.gz 2>/dev/null || {
            # Fallback 2: install via curl
            log "Trying alternative install method..."
            curl -sSfL https://get.kraftkit.sh | sh
        }
        
        if [[ -f kraft.tar.gz ]]; then
            tar xzf kraft.tar.gz
            mv kraft /usr/local/bin/kraft
            chmod +x /usr/local/bin/kraft
            rm -f kraft.tar.gz
        fi
    }
fi

# ─── Install additional tools ────────────────────────────────────────────────

log "Installing additional utilities..."

# GNU make 4.3+ (Ubuntu 22.04 has 4.3)
make --version | head -1

# gcc cross-compilation support (in case arm64 targets are needed later)
apt-get install -y gcc-aarch64-linux-gnu 2>/dev/null || \
    warn "arm64 cross-compiler not available, skipping (only needed for arm64 targets)"

# ─── Configure kraft ─────────────────────────────────────────────────────────

log "Setting up kraft configuration..."

# Create kraft config directory
KRAFT_DIR="${HOME}/.config/kraftkit"
mkdir -p "$KRAFT_DIR"

# Note: kraft sources are configured in Kraftfile per-project,
# but we can set default runtime dir
if [[ ! -f "${KRAFT_DIR}/config.yaml" ]]; then
    cat > "${KRAFT_DIR}/config.yaml" << 'EOF'
# KraftKit configuration
# See: https://unikraft.org/docs/cli/reference
log:
  level: info
  type: fancy
EOF
    log "kraft config written to ${KRAFT_DIR}/config.yaml"
fi

# ─── Verify installation ────────────────────────────────────────────────────

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Unikraft toolchain installation complete!"
log "═══════════════════════════════════════════════════════════════"
log ""

if command -v kraft &>/dev/null; then
    log "  kraft CLI: $(kraft --version 2>/dev/null || echo 'installed')"
else
    warn "  kraft CLI: not found in PATH"
    warn "  Try: pip3 install kraftkit"
    warn "  Or:  curl -sSfL https://get.kraftkit.sh | sh"
fi

log "  GCC:       $(gcc --version | head -1)"
log "  Make:      $(make --version | head -1)"
log "  QEMU:      $(qemu-system-x86_64 --version | head -1)"
log ""
log "  NEXT STEP: bash 03-build-test-unikernel.sh"
log ""
