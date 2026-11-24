#!/usr/bin/env bash
# tools/setup-macos.sh: get, patch, build and install the ReXGlue SDK on macOS (Apple silicon).
#
# The macOS counterpart of tools/setup.sh. The SDK lives next to this repository at ../tools/rexglue
# (the same layout the Linux scripts use). On first run it is cloned from the public fork at the
# pinned base commit and every patch in rexglue-patches/ is applied with `git am`, including the
# Apple platform port. It is then configured with Xcode's compiler for arm64 and installed to
# ../tools/rexglue/out/install/macos-arm64.
#
# Needs: Xcode 16 or newer (or its Command Line Tools), CMake 3.25+, Ninja and Git
# (`brew install cmake ninja`).
#
# Env:
#   BUILD_JOBS        parallel build jobs (default: number of performance cores)
#   REXGLUE_URL       fork URL override
#   REXGLUE_TESTS=1   also build the unit tests, the PowerPC instruction tests and rex_smoke (the
#                     window/MoltenVK/guest-memory smoke test); the instruction tests need a
#                     powerpc-none-elf binutils with VMX128 (as, ld, nm), found through
#                     PPC_BINUTILS_DIR (build it with tools/build-ppc-binutils-macos.sh)
#   PPC_BINUTILS_DIR  folder holding powerpc-none-elf-{as,ld,nm} (only with REXGLUE_TESTS=1)
#   CONFIG            build configuration (default RelWithDebInfo)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SDK="$ROOT/../tools/rexglue"
BASE_COMMIT=987593c0fc6612850a2e1b247b2b03aa5281e663
REXGLUE_URL=${REXGLUE_URL:-https://github.com/HollywoodAkeem/rexglue-sdk-yukes.git}
BUILD_JOBS=${BUILD_JOBS:-$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)}
CONFIG=${CONFIG:-RelWithDebInfo}
REXGLUE_TESTS=${REXGLUE_TESTS:-0}

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "This script is for macOS on Apple silicon (arm64). On Linux use tools/setup.sh." >&2
  exit 1
fi
for command in git cmake ninja xcrun; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command (install Xcode, then: brew install cmake ninja)" >&2
    exit 1
  }
done
CC=$(xcrun --find clang)
CXX=$(xcrun --find clang++)

if [ ! -d "$SDK/.git" ]; then
  echo "== Fetching ReXGlue ($REXGLUE_URL @ $BASE_COMMIT) into $SDK"
  mkdir -p "$(dirname "$SDK")"
  git clone --no-checkout "$REXGLUE_URL" "$SDK"
  git -C "$SDK" checkout -q -b wwe13-fixes "$BASE_COMMIT"
  echo "== Applying the WWE '13 patches from rexglue-patches/"
  git -C "$SDK" -c user.name="WWE13 Recomp" -c user.email="wwe13-recomp@users.noreply.github.com" \
    am -q --keep-cr "$ROOT"/rexglue-patches/*.patch
  git -C "$SDK" submodule update --init --recursive
else
  echo "== Using existing ReXGlue checkout: $SDK ($(git -C "$SDK" rev-parse --short HEAD))"
fi

TEST_ARGS=(-DREXGLUE_BUILD_TESTS=OFF)
if [ "$REXGLUE_TESTS" = "1" ]; then
  TEST_ARGS=(-DREXGLUE_BUILD_TESTS=ON)
  # The SDK ships Linux/Windows powerpc-none-elf binutils for the instruction tests; on macOS
  # point the tests at a native build of them.
  if [ -n "${PPC_BINUTILS_DIR:-}" ]; then
    for tool in as ld nm; do
      test -x "$PPC_BINUTILS_DIR/powerpc-none-elf-$tool" || {
        echo "PPC_BINUTILS_DIR has no powerpc-none-elf-$tool" >&2
        exit 1
      }
      ln -sf "$PPC_BINUTILS_DIR/powerpc-none-elf-$tool" "$SDK/tools/binutils/powerpc-none-elf-$tool"
    done
  else
    echo "REXGLUE_TESTS=1 needs PPC_BINUTILS_DIR (powerpc-none-elf binutils with VMX128;" \
      "build them with tools/build-ppc-binutils-macos.sh)" >&2
    exit 1
  fi
fi

BUILD_DIR="$SDK/out/build/macos-arm64"
if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
  cmake -S "$SDK" -B "$BUILD_DIR" -G "Ninja Multi-Config" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_CONFIGURATION_TYPES="Debug;Release;RelWithDebInfo" \
    -DCMAKE_INSTALL_PREFIX="$SDK/out/install/macos-arm64" \
    "${TEST_ARGS[@]}" -DREXGLUE_ENABLE_FIDELITYFX=OFF -DREXGLUE_ENABLE_PERF_COUNTERS=OFF \
    -DREXGLUE_ENABLE_SANITIZERS=OFF -DREXGLUE_ENABLE_TRACY=OFF -DREXGLUE_FFMPEG_SHARED=ON \
    -DREXGLUE_PROFILE_GUEST_FUNCTIONS=OFF -DREXGLUE_USE_VULKAN=ON
fi
cmake --build "$BUILD_DIR" --config "$CONFIG" --target install -j "$BUILD_JOBS"

REXGLUE_BIN="$SDK/out/macos-arm64/$CONFIG/rexglue"
test -x "$REXGLUE_BIN" || { echo "ReXGlue binary was not produced: $REXGLUE_BIN" >&2; exit 1; }

if [ "$REXGLUE_TESTS" = "1" ]; then
  cmake --build "$BUILD_DIR" --config "$CONFIG" --target unit_tests ppc_tests rex_smoke -j "$BUILD_JOBS"
fi

echo "ReXGlue fetched, patched, built and installed for macOS: $SDK/out/install/macos-arm64"
