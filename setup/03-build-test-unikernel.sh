#!/usr/bin/env bash
#
# 03-build-test-unikernel.sh — Build the test agent unikernel for Xen
#
# Run as regular user (not root): bash 03-build-test-unikernel.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${SCRIPT_DIR}/test-agent"
BUILD_DIR="${AGENT_DIR}/build"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ─── Check prerequisites ────────────────────────────────────────────────────

if ! command -v kraft &>/dev/null; then
    err "kraft CLI not found. Run 02-install-unikraft.sh first."
fi

# ─── Build using kraft ───────────────────────────────────────────────────────

log "Building test-agent unikernel for Xen x86_64..."
cd "$AGENT_DIR"

# kraft will:
# 1. Pull the Unikraft core + required libraries
# 2. Configure the build (apply Kconfig options from Kraftfile)
# 3. Compile main.c + all selected Unikraft libraries
# 4. Link into a single Xen-bootable binary
kraft build --plat xen --arch x86_64 --log-level info 2>&1 || {
    warn ""
    warn "kraft build failed. This can happen if:"
    warn "  1. kraft version incompatibility — try: kraft pkg update"
    warn "  2. Missing build deps — re-run 02-install-unikraft.sh"
    warn "  3. Network issues pulling Unikraft packages"
    warn ""
    warn "Trying manual build approach as fallback..."
    warn ""

    # ── Fallback: Manual build using the local Unikraft source tree ──────
    UNIKRAFT_SRC="${SCRIPT_DIR}/../Unikraft"
    if [[ ! -d "$UNIKRAFT_SRC" ]]; then
        err "No local Unikraft source found at $UNIKRAFT_SRC"
    fi

    log "Using local Unikraft source at $UNIKRAFT_SRC"
    log "Building with make..."

    mkdir -p "$BUILD_DIR"

    # Create a minimal KConfig .config for Xen x86_64
    cat > "${BUILD_DIR}/.config" << 'KCONFIG'
#
# Minimal Xen x86_64 config for test-agent
#
CONFIG_PLAT_XEN=y
CONFIG_ARCH_X86_64=y
CONFIG_LIBUKBOOT=y
CONFIG_LIBNOLIBC=y
CONFIG_LIBPOSIX_SOCKET=y
CONFIG_LIBLWIP=y
CONFIG_LWIP_SOCKET=y
CONFIG_LWIP_IPV4=y
CONFIG_LWIP_TCP=y
CONFIG_LWIP_DHCP=y
CONFIG_XEN_NETFRONT=y
CONFIG_LIBUKALLOC=y
CONFIG_LIBUKALLOCBBUDDY=y
CONFIG_LIBUKSCHED=y
CONFIG_LIBUKSCHEDCOOP=y
KCONFIG

    make -C "$UNIKRAFT_SRC" \
        A="$AGENT_DIR" \
        O="$BUILD_DIR" \
        L="$UNIKRAFT_SRC/lib" \
        P="$UNIKRAFT_SRC/plat" \
        olddefconfig 2>&1 || true

    make -C "$UNIKRAFT_SRC" \
        A="$AGENT_DIR" \
        O="$BUILD_DIR" \
        L="$UNIKRAFT_SRC/lib" \
        P="$UNIKRAFT_SRC/plat" \
        -j"$(nproc)" 2>&1
}

# ─── Find the built image ───────────────────────────────────────────────────

log "Looking for built image..."

# kraft stores builds in .unikraft/build/ — look there first
# Filter out: .config files (text metadata), .dbg (debug), .o (objects), .d (deps)
XEN_IMAGE=$(find "$AGENT_DIR" -path "*/.unikraft/build/*" -name "*_xen-x86_64" \
    -type f ! -name "*.dbg" ! -name "*.o" ! -name "*.d" ! -name ".config*" \
    2>/dev/null | head -1)

if [[ -z "$XEN_IMAGE" ]]; then
    # Fallback: any ELF binary with xen in the name
    XEN_IMAGE=$(find "$AGENT_DIR" -name "*_xen-x86_64" -type f \
        ! -name "*.dbg" ! -name "*.o" ! -name "*.d" ! -name ".config*" \
        2>/dev/null | head -1)
fi

if [[ -z "$XEN_IMAGE" ]]; then
    # Also check kraft's default output location
    XEN_IMAGE=$(find "${HOME}/.local/share/kraftkit" -name "*test*agent*xen*" -type f 2>/dev/null | head -1)
fi

if [[ -z "$XEN_IMAGE" ]]; then
    warn "Could not auto-detect the built image."
    warn "Check the build output above for the image path."
    warn "Common locations:"
    warn "  .unikraft/build/test-agent_xen-x86_64"
    warn "  ~/.local/share/kraftkit/..."
    exit 1
fi

# Verify it's actually an ELF binary, not a config file
FILE_TYPE=$(file "$XEN_IMAGE" 2>/dev/null || echo "unknown")
if ! echo "$FILE_TYPE" | grep -q "ELF"; then
    warn "Found $XEN_IMAGE but it's not an ELF binary: $FILE_TYPE"
    warn "Looking for the actual kernel..."
    # Try harder
    XEN_IMAGE=$(find "$AGENT_DIR" -name "*_xen-x86_64" -type f 2>/dev/null | while read f; do
        file "$f" 2>/dev/null | grep -q ELF && echo "$f" && break
    done)
    if [[ -z "$XEN_IMAGE" ]]; then
        err "Could not find a valid ELF kernel binary."
    fi
fi

IMAGE_SIZE=$(du -h "$XEN_IMAGE" | awk '{print $1}')

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Unikraft test-agent built successfully!"
log "═══════════════════════════════════════════════════════════════"
log ""
log "  Image: $XEN_IMAGE"
log "  Size:  $IMAGE_SIZE"
log ""
log "  NEXT STEP: sudo bash 04-test-xen-boot.sh"
log ""

# Save the image path for use by later scripts
echo "$XEN_IMAGE" > "${SCRIPT_DIR}/.last-built-image"
