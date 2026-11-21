#!/usr/bin/env bash
#
# Local Debug build for macOS using Homebrew Qt 6.
#
# Usage:
#   ./build_debug_macos.sh            # incremental build
#   CLEAN=1 ./build_debug_macos.sh    # wipe the build directory first
#   ./build_debug_macos.sh run        # build, ad-hoc sign and open the GUI
#
# Optional environment variables:
#   BUILD_DIR=build-debug             # build directory
#   INPUTLEAP_BUILD_TESTS=ON|OFF      # build unit/integration tests (default ON)
#   MACOSX_DEPLOYMENT_TARGET=14.4     # defaults to the Qt framework minimum

set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="${BUILD_DIR:-build-debug}"
BUILD_TYPE=Debug

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have brew  || die "Homebrew not found: https://brew.sh"
have cmake || die "cmake not found. Run: brew install cmake"
have ninja || die "ninja not found. Run: brew install ninja"
have xcrun || die "Xcode Command Line Tools not found. Run: xcode-select --install"

BREW_PREFIX="$(brew --prefix)"

# build_dist.sh uses tput for colored output; with TERM=dumb/unset the
# final tput call returns non-zero and makes the build target fail.
case "${TERM:-}" in
    ""|dumb) export TERM=xterm ;;
esac

QT_PREFIX="$(brew --prefix qtbase 2>/dev/null || true)"
[ -n "$QT_PREFIX" ] && [ -d "$QT_PREFIX/lib/cmake/Qt6" ] \
    || die "Qt 6 not found. Run: brew install qtbase qttools"

if [ ! -d "$BREW_PREFIX/lib/cmake/Qt6LinguistTools" ] \
   && [ ! -d "$(brew --prefix qttools 2>/dev/null || true)/lib/cmake/Qt6LinguistTools" ]; then
    die "Qt LinguistTools not found. Run: brew install qttools"
fi

OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
[ -n "$OPENSSL_PREFIX" ] && [ -f "$OPENSSL_PREFIX/lib/libssl.a" ] \
    || die "OpenSSL static libraries not found. Run: brew install openssl@3"

have macdeployqt || die "macdeployqt not found. Run: brew install qtbase"

# Use the Qt framework's minimum OS so the linker accepts it.
QT_MINOS="$(otool -l "$QT_PREFIX/lib/QtCore.framework/Versions/A/QtCore" 2>/dev/null \
            | awk '/minos/{print $2; exit}' || true)"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-${QT_MINOS:-14.0}}"

if [ ! -f ext/gtest/CMakeLists.txt ] || [ ! -d ext/gulrak-filesystem/include ]; then
    echo "==> initialising git submodules"
    git submodule update --init --recursive
fi

if [ "${CLEAN:-0}" = "1" ]; then
    echo "==> removing $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

# Start from a clean app bundle so macdeployqt does not reuse libraries
# from a previous deployment. configure_files recreates the skeleton below.
rm -rf "$BUILD_DIR/bundle/InputLeap.app"

# macdeployqt searches <bundle>/lib but not the Homebrew prefix, and
# Homebrew installs some Qt modules (e.g. QtSvg, needed by the SVG icon
# plugin) outside qtbase. Symlink those frameworks where macdeployqt looks.
mkdir -p "$BUILD_DIR/bundle/lib"
for fw in "$BREW_PREFIX"/lib/*.framework; do
    [ -e "$fw" ] || continue
    name="$(basename "$fw")"
    [ -e "$QT_PREFIX/lib/$name" ] && continue
    ln -sfn "$fw" "$BUILD_DIR/bundle/lib/$name"
done

echo "==> configuring ($BUILD_TYPE, deployment target $DEPLOYMENT_TARGET)"
cmake -S . -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_UNITY_BUILD=1 \
    -DQT_DEFAULT_MAJOR_VERSION=6 \
    -DINPUTLEAP_BUILD_TESTS="${INPUTLEAP_BUILD_TESTS:-ON}" \
    -DINPUTLEAP_VERSION_DESC=local-debug \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    -DCMAKE_PREFIX_PATH="$BREW_PREFIX" \
    -DOpenSSL_ROOT="$OPENSSL_PREFIX"

echo "==> building"
cmake --build "$BUILD_DIR" --parallel

APP="$BUILD_DIR/bundle/InputLeap.app"
if [ -d "$APP" ]; then
    echo "==> ad-hoc signing $APP"
    xattr -cr "$APP"
    codesign --force --deep --sign - "$APP"
    codesign --verify --deep --strict "$APP"
fi

echo
echo "Built:  $APP"
echo "GUI:    open '$APP'"
echo "Tools:  $BUILD_DIR/bin/input-leaps (server), $BUILD_DIR/bin/input-leapc (client)"
echo "Debug:  lldb -- $BUILD_DIR/bin/input-leaps -f -c <config>"

if [ "${1:-}" = "run" ] && [ -d "$APP" ]; then
    open "$APP"
fi
