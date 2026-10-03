#!/bin/bash
# slim-kodi bootstrap — single-shot script for building Kodi 21.3 on macOS.
#
# What this does:
#   1. Verifies Xcode 16.x is the active developer directory.
#   2. Runs `./bootstrap` to generate `tools/depends/configure`.
#   3. Runs `./configure` for native + target deps.
#   4. Patches the three generated config.site files to pin the SDK to
#      MacOSX26.5.sdk directly (sidesteps the MacOSX.sdk -> 27.0 symlink).
#   5. Builds the depends tree with -j4 (avoids the autotest fork/wait
#      deadlock we hit at higher parallelism).
#   6. Configures and builds Kodi with the slim preset, then runs a smoke
#      check that the binary launches.
#
# Usage:
#   bash scripts/slim-kodi-bootstrap.sh
#
# Expects to run from the slim-kodi checkout root (the directory that
# contains this script). Tested against:
#   - Kodi 21.3-Omega, branch slim-kodi
#   - macOS host 15.x (Apple Silicon, 10 cores)
#   - Xcode Command Line Tools 21.0 + Xcode 16.4 (Xcode 16 must be active)
#   - ~50 GB free on the volume that holds the depends prefix
#
# This script is idempotent: re-running it after a partial build will
# resume where it left off as long as you don't delete the depends
# install dir.

set -euo pipefail

# ---- Tunables ---------------------------------------------------------------

# Where the depends install + Kodi build artifacts go. Must be on a
# volume with at least 50 GB free.
: "${SLIM_KODI_PREFIX:=/Volumes/256/kodi-build/kodi-21.3-depends}"
: "${SLIM_KODI_BUILD:=/Volumes/256/kodi-build/build-slim}"
: "${SLIM_KODI_PARALLEL:=4}"

# SDK to use. We pin to 26.5 directly (NOT MacOSX.sdk) because the
# latter is a symlink to MacOSX27.0.sdk on a fresh Xcode 21 install,
# and Xcode 27 SDK headers trigger -Werror=unguarded-availability-new
# failures against Python's dup3/pipe2 calls and zlib's fdopen macro.
: "${SLIM_KODI_SDK:=26.5}"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX${SLIM_KODI_SDK}.sdk"

# ---- Sanity checks ----------------------------------------------------------

log()  { printf '\033[1;34m[slim-kodi]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[slim-kodi]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[slim-kodi]\033[0m %s\n' "$*" >&2; exit 1; }

# Active developer dir must be Xcode 16 (or any non-CLT Xcode that ships
# the right toolchain). xcode-select without sudo works for read.
ACTIVE_DEV=$(xcode-select -p 2>/dev/null || true)
case "$ACTIVE_DEV" in
  *Xcode*.app/Contents/Developer) log "Active developer: $ACTIVE_DEV" ;;
  *) fail "Active developer dir is '$ACTIVE_DEV' — switch to an Xcode 16 install with: sudo xcode-select -s /path/to/Xcode-16.x.x.app/Contents/Developer" ;;
esac

[ -d "$SDK_PATH" ] \
  || fail "SDK not found at $SDK_PATH. Expected MacOSX${SLIM_KODI_SDK}.sdk in /Library/Developer/CommandLineTools/SDKs/. If you installed a newer Xcode, the SDK may live under /Applications/Xcode-16.x.x.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/. Override SLIM_KODI_SDK or symlink the SDK there."

# Free disk check (need ~50 GB on the volume that holds SLIM_KODI_PREFIX).
PREFIX_VOL=$(df -P "$SLIM_KODI_PREFIX" 2>&1 | tail -1 | awk '{print $1}')
PREFIX_FREE_KB=$(df -Pk "$SLIM_KODI_PREFIX" 2>&1 | tail -1 | awk '{print $4}')
PREFIX_FREE_GB=$((PREFIX_FREE_KB / 1024 / 1024))
[ "$PREFIX_FREE_GB" -ge 50 ] \
  || fail "Need 50 GB free on $PREFIX_VOL (have ${PREFIX_FREE_GB} GB). Free space or change SLIM_KODI_PREFIX."

# ---- Step 1: bootstrap ------------------------------------------------------

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
DEPENDS_DIR="$REPO_ROOT/tools/depends"

if [ ! -x "$DEPENDS_DIR/configure" ]; then
  log "Running ./bootstrap to generate $DEPENDS_DIR/configure"
  (cd "$DEPENDS_DIR" && ./bootstrap)
fi

# ---- Step 2: configure ------------------------------------------------------

log "Configuring depends (host=aarch64-apple-darwin, platform=macos, sdk=$SLIM_KODI_SDK)"
(cd "$DEPENDS_DIR" && \
  ./configure \
    --host=aarch64-apple-darwin \
    --with-platform=macos \
    --prefix="$SLIM_KODI_PREFIX" \
    --with-sdk="$SLIM_KODI_SDK" \
    --with-sdk-path="$SDK_PATH")

# ---- Step 3: pin SDK in config.site (override the MacOSX.sdk symlink) ------

patch_config_site() {
  local f="$1"
  if grep -q "MacOSX.sdk" "$f"; then
    log "Patching SDK path in $f (MacOSX.sdk -> MacOSX${SLIM_KODI_SDK}.sdk)"
    sed -i '' "s|SDKs/MacOSX\\.sdk|SDKs/MacOSX${SLIM_KODI_SDK}.sdk|g" "$f"
  fi
}
patch_config_site "$DEPENDS_DIR/target/config.site"
patch_config_site "$DEPENDS_DIR/target/config-binaddons.site"
patch_config_site "$DEPENDS_DIR/native/config.site.native"

# ---- Step 4: build depends -------------------------------------------------

log "Building depends with -j${SLIM_KODI_PARALLEL} (ETA 1.5-3 hours)"
(cd "$DEPENDS_DIR" && make -j"$SLIM_KODI_PARALLEL")
log "Depends tree complete at $SLIM_KODI_PREFIX"

# ---- Step 5: build Kodi ----------------------------------------------------

TOOLCHAIN="$SLIM_KODI_PREFIX/macosx${SLIM_KODI_SDK}_arm64-target-debug/share/Toolchain.cmake"
[ -f "$TOOLCHAIN" ] || fail "Toolchain.cmake not at $TOOLCHAIN"

log "Configuring Kodi with slim preset"
cmake -S "$REPO_ROOT" -B "$SLIM_KODI_BUILD" \
  -C "$REPO_ROOT/cmake/presets/slim.cmake" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCORE_PLATFORM_NAME=osx \
  -DENABLE_TESTING=OFF \
  -DENABLE_LCMS2=OFF

log "Building Kodi (ETA 30-60 minutes)"
cmake --build "$SLIM_KODI_BUILD" -j"$SLIM_KODI_PARALLEL"

# ---- Step 6: smoke test ----------------------------------------------------

KODI_BIN="$SLIM_KODI_BUILD/$APP_NAME_LC"  # CORE_SYSTEM_NAME derived, but easier to glob
if compgen -G "$SLIM_KODI_BUILD/Kodi.app" > /dev/null; then
  log "Build OK. App bundle at: $SLIM_KODI_BUILD/Kodi.app"
  log "Smoke test: file '$SLIM_KODI_BUILD/Kodi.app/Contents/MacOS/Kodi' && echo binary present"
  file "$SLIM_KODI_BUILD/Kodi.app/Contents/MacOS/Kodi" 2>&1 || true
else
  warn "Build finished but Kodi.app not found at expected path. Inspect $SLIM_KODI_BUILD manually."
fi

log "Done. Open $SLIM_KODI_BUILD/Kodi.app to launch, or rebuild with: cmake --build $SLIM_KODI_BUILD"