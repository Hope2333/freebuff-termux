#!/data/data/com.termux/files/usr/bin/bash
#
# tools/produce-local.sh — Download freebuff binary + build hooks locally
#
# This is the "produce" step in the produce → stage → install pipeline.
# It downloads the freebuff binary from GitHub, compiles hook.so and the C
# wrapper, and places them in tools/ for local testing.
#
# Usage:
#   bash tools/produce-local.sh          # default (latest version)
#   bash tools/produce-local.sh v1.2.3   # specific version
#
# Output artifacts:
#   tools/hook.so           — glibc LD_PRELOAD hook
#   tools/freebuff-wrapper  — Bionic C wrapper (NOT installed)
#   downloads/freebuff      — unpacked binary
#
# Environment:
#   NO_PATCH=1    skip patchelf + glibc linker fix (faster iteration)
#   NO_BUILD=1    skip C compilation (use existing binaries)
#   NO_DOWNLOAD=1 skip binary download (use existing binary)
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPDIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── Config ──────────────────────────────────────────────────────────
VERSION="${1:-latest}"
BINARY_DIR="${HOME}/.config/manicode"
BINARY_PATH="${BINARY_DIR}/freebuff"
GLIBC_LIB="/data/data/com.termux/files/usr/glibc/lib"
GLIBC_LD="${GLIBC_LIB}/ld-linux-aarch64.so.1"
GLIBC_INC="/data/data/com.termux/files/usr/glibc/include"
BUN_REPO="oven-sh/bun"  # Bun publishes freebuff-compatible linux binaries
ARCH="arm64"

# ── Step 1: Determine version ───────────────────────────────────────
if [ "$VERSION" = "latest" ]; then
    log "Finding latest freebuff version..."
    VERSION=$(npm view freebuff version 2>/dev/null || \
              curl -sL https://registry.npmjs.org/freebuff/latest | \
              node -e "process.stdin.resume(); let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>console.log(JSON.parse(d).version))")
    log "Latest: $VERSION"
fi

# ── Step 2: Download binary from GitHub ─────────────────────────────
BUN_VERSION="${VERSION#v}"
DOWNLOAD_DIR="$PROJECT_DIR/downloads"
mkdir -p "$DOWNLOAD_DIR"
TARBALL="$DOWNLOAD_DIR/freebuff-linux-${ARCH}.tar.gz"
BINARY_IN_TAR="freebuff-linux-${ARCH}/freebuff"

if [ ! -f "$BINARY_PATH" ] && [ "${NO_DOWNLOAD:-0}" != "1" ]; then
    URLS=(
        "https://github.com/CodebuffAI/codebuff-community/releases/download/v${BUN_VERSION}/freebuff-linux-${ARCH}.tar.gz"
        "https://github.com/CodebuffAI/codebuff/releases/download/v${BUN_VERSION}/freebuff-linux-${ARCH}.tar.gz"
        "https://github.com/oven-sh/bun/releases/download/freebuff-v${BUN_VERSION}/freebuff-linux-${ARCH}.tar.gz"
    )

    DOWNLOADED=0
    for URL in "${URLS[@]}"; do
        log "Trying: $URL"
        if command -v wget >/dev/null 2>&1; then
            wget -c --timeout=300 "$URL" -O "$TARBALL" 2>&1 && DOWNLOADED=1 && break
        else
            curl -fL --connect-timeout 10 --max-time 600 -o "$TARBALL" "$URL" 2>&1 && DOWNLOADED=1 && break
        fi
    done

    if [ "$DOWNLOADED" != "1" ]; then
        err "Failed to download freebuff binary from any URL.
Either supply the version as argument, or download manually and place at:
  $BINARY_PATH"
    fi

    log "Extracting binary..."
    mkdir -p "$BINARY_DIR"
    tar -xzf "$TARBALL" -C "$DOWNLOAD_DIR"
    # Find the actual binary (structure may vary)
    BIN="$(find "$DOWNLOAD_DIR" -type f \( -name "freebuff" -o -name "freebuff-linux-*" \) ! -name "*.tar.gz" 2>/dev/null | head -1)"
    if [ -z "$BIN" ]; then
        # Try direct path
        BIN="$DOWNLOAD_DIR/$BINARY_IN_TAR"
    fi
    [ -f "$BIN" ] || BIN="$(find "$DOWNLOAD_DIR" -type f -executable 2>/dev/null | head -1)"
    cp "$BIN" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    log "Binary installed: $BINARY_PATH ($(du -h "$BINARY_PATH" | cut -f1))"
else
    if [ -f "$BINARY_PATH" ]; then
        log "Binary already present: $BINARY_PATH ($(du -h "$BINARY_PATH" | cut -f1))"
    fi
fi

# ── Step 3: Patch binary (patchelf + glibc) ─────────────────────────
if command -v patchelf >/dev/null && [ "${NO_PATCH:-0}" != "1" ] && [ -f "$BINARY_PATH" ]; then
    log "Patching binary interpreter to glibc..."
    CURRENT_INTERP=$(patchelf --print-interpreter "$BINARY_PATH" 2>/dev/null || echo "")
    if [ "$CURRENT_INTERP" != "$GLIBC_LD" ]; then
        patchelf --set-interpreter "$GLIBC_LD" "$BINARY_PATH"
        log "Interpreter changed to: $GLIBC_LD"
    else
        log "Interpreter already correct: $GLIBC_LD"
    fi

    # Fix glibc linker scripts (.so → symlink)
    if [ -d "$GLIBC_LIB" ]; then
        log "Fixing glibc linker scripts..."
        for f in libc.so libm.so libgcc_s.so libpthread.so librt.so libdl.so libutil.so; do
            fpath="$GLIBC_LIB/$f"
            if [ -f "$fpath" ] && ! head -c 4 "$fpath" | grep -q $'\x7fELF'; then
                TARGET=$(grep -oP 'GROUP\s*\(\s*\K[^)]+' "$fpath" 2>/dev/null | \
                         tr -d ' ' | tr ',' '\n' | grep -E '\.so\.[0-9]+' | head -1)
                if [ -n "$TARGET" ] && [ -f "$GLIBC_LIB/$TARGET" ]; then
                    rm -f "$fpath"
                    ln -sf "$TARGET" "$fpath"
                    log "  $f → symlink to $TARGET"
                fi
            fi
        done
    fi
else
    warn "Skipping binary patching (patchelf not found or NO_PATCH=1)"
fi

# ── Step 4: Build hook.so (glibc LD_PRELOAD .so) ────────────────────
if [ "${NO_BUILD:-0}" != "1" ]; then
    HOOK_SRC="$SCRIPT_DIR/hook.c"
    HOOK_OUT="$SCRIPT_DIR/hook.so"

    if [ -f "$HOOK_SRC" ]; then
        log "Compiling hook.so (glibc)..."
        GCC_CMD=(
            gcc -fPIC -shared -o "$HOOK_OUT" "$HOOK_SRC"
            -I"$GLIBC_INC"
            -L"$GLIBC_LIB"
            -nostdlib -lc -ldl
            -Wl,-rpath,"$GLIBC_LIB"
        )
        if "${GCC_CMD[@]}" 2>&1; then
            log "hook.so compiled ($(du -h "$HOOK_OUT" | cut -f1))"
        else
            warn "hook.so compilation failed (glibc headers/libs not found?)"
            warn "Try: apt install glibc-repo && apt update && apt install -y glibc openssl-glibc"
        fi
    else
        warn "hook.c not found at $HOOK_SRC, skipping hook build"
    fi

    # Build C wrapper (Bionic)
    WRAPPER_SRC="$PROJECT_DIR/scripts/freebuff-wrapper.c"
    WRAPPER_OUT="$SCRIPT_DIR/freebuff-wrapper"
    if [ -f "$WRAPPER_SRC" ]; then
        log "Compiling freebuff-wrapper (Bionic)..."
        if gcc -O2 -s -o "$WRAPPER_OUT" "$WRAPPER_SRC" 2>&1; then
            log "freebuff-wrapper compiled ($(du -h "$WRAPPER_OUT" | cut -f1))"
        else
            warn "freebuff-wrapper compilation failed"
        fi
    fi
else
    log "Skipping compilation (NO_BUILD=1)"
fi

# ── Done ────────────────────────────────────────────────────────────
log ""
log "═══════════════════════════════════════════"
log "  produce-local.sh complete!"
log ""
log "  Binary:   $BINARY_PATH"
log "  hook.so:  $HOOK_SRC → $SCRIPT_DIR/hook.so"
log "  Wrapper:  $WRAPPER_SRC → $SCRIPT_DIR/freebuff-wrapper"
log ""
log "  Test:     timeout 10 tools/freebuff-wrapper --version"
log "  Install:  make install"
log "═══════════════════════════════════════════"
