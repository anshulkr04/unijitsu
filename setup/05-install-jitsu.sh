#!/usr/bin/env bash
#
# 05-install-jitsu.sh — Install OCaml toolchain and build Jitsu
#
# Run as regular user: bash 05-install-jitsu.sh
# (Some parts need sudo for system packages)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JITSU_DIR="${SCRIPT_DIR}/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ─── Install system dependencies ────────────────────────────────────────────

log "Installing system dependencies for OCaml/Jitsu..."
sudo apt-get update -qq
sudo apt-get install -y \
    bubblewrap \
    m4 \
    pkg-config \
    libgmp-dev \
    libffi-dev \
    zlib1g-dev \
    libssl-dev \
    libev-dev \
    libxen-dev \
    libxenctrl-dev \
    libxenguest-dev \
    libxenlight-dev \
    libxentoollog-dev \
    libxenstore-dev \
    libvirt-dev \
    libxml2-dev \
    git \
    unzip \
    curl

# ─── Install opam (OCaml Package Manager) ────────────────────────────────────

if command -v opam &>/dev/null; then
    log "opam already installed: $(opam --version)"
else
    log "Installing opam..."
    # Use the official install script
    bash -c "sh <(curl -fsSL https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh)" <<< "y" || {
        # Fallback: Ubuntu package
        warn "Official installer failed, trying apt..."
        sudo apt-get install -y opam
    }
fi

# ─── Initialize opam ────────────────────────────────────────────────────────

if [[ ! -d "${HOME}/.opam" ]]; then
    log "Initializing opam (this takes a few minutes — compiling OCaml)..."
    opam init --auto-setup --disable-sandboxing --yes

    # Jitsu needs OCaml 4.14 (last version with good camlp4 support)
    # The codebase uses camlp4 syntax extensions (lwt.syntax)
    log "Creating OCaml 4.14.2 switch for Jitsu..."
    opam switch create jitsu 4.14.2 --yes
    eval $(opam env --switch=jitsu)
else
    log "opam already initialized"
    eval $(opam env)

    # Check if jitsu switch exists
    if opam switch list 2>/dev/null | grep -q jitsu; then
        opam switch jitsu
        eval $(opam env --switch=jitsu)
    else
        log "Creating jitsu switch with OCaml 4.14.2..."
        opam switch create jitsu 4.14.2 --yes
        eval $(opam env --switch=jitsu)
    fi
fi

log "OCaml version: $(ocaml -vnum 2>/dev/null || echo 'checking...')"

# ─── Install Jitsu OCaml dependencies ────────────────────────────────────────

log "Installing Jitsu OCaml dependencies (this takes 5-15 minutes)..."
log "Dependencies: lwt, dns, irmin, xenctrl, cmdliner, etc."

# Install dependencies from opam file
cd "$JITSU_DIR"

# Install camlp4 first (needed for lwt.syntax)
opam install camlp4 --yes 2>&1 | tail -5

# Install core dependencies
opam install \
    ocamlfind \
    lwt \
    "dns>=0.15.3" \
    xenstore \
    xenstore_transport \
    cmdliner \
    ipaddr \
    ezxmlm \
    conduit \
    vchan \
    uuidm \
    "irmin>=0.10.0" \
    irmin-unix \
    git \
    alcotest \
    --yes 2>&1 | tail -10

# Install optional backends (these may fail if Xen headers aren't right)
log "Installing VM backend packages..."
opam install xenctrl xenlight xentoollog --yes 2>&1 | tail -5 || \
    warn "xenctrl/xenlight install had issues — libxl backend may not be available"

opam install libvirt --yes 2>&1 | tail -5 || \
    warn "libvirt OCaml bindings install had issues — libvirt backend may not be available"

# ─── Build Jitsu ─────────────────────────────────────────────────────────────

log "Building Jitsu..."
cd "$JITSU_DIR"

eval $(opam env --switch=jitsu)
make clean 2>/dev/null || true
make 2>&1

# ─── Verify ─────────────────────────────────────────────────────────────────

if [[ -f "${JITSU_DIR}/bin/jitsu" ]]; then
    log ""
    log "═══════════════════════════════════════════════════════════════"
    log "  Jitsu built successfully!"
    log "═══════════════════════════════════════════════════════════════"
    log ""
    log "  Binary: ${JITSU_DIR}/bin/jitsu"

    # Show detected backends
    DETECTED=$(make -n 2>/dev/null | grep -o "Detected backends:.*" || echo "unknown")
    log "  Backends: $DETECTED"
    log ""
    log "  Test with: ${JITSU_DIR}/bin/jitsu --help"
    log ""
    log "  NEXT STEP: sudo bash 06-run-jitsu.sh"
    log ""
else
    err "Jitsu build failed. Check the output above for errors."
fi
