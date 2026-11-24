#!/usr/bin/env bash
# Build the game and the launcher for macOS (Apple silicon), and put them together in
# out/macos-arm64/: the launcher starts the game from its own folder (Play runs ./wwe13), as in
# the Linux release. Run ./tools/setup-macos.sh and ./tools/codegen.sh first.
# Running it needs MoltenVK and the Vulkan loader (`brew install molten-vk vulkan-loader`).
#
# Only the launcher, the game and its FFmpeg libraries are replaced in out/macos-arm64/, so a game
# folder ("WWE 13"), userdata, settings and logs kept there survive a rebuild.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test -f "$ROOT/generated/sources.cmake" || { echo "Run ./tools/codegen.sh first." >&2; exit 1; }
"$ROOT/tools/ensure-rexglue-cmake.sh"

# Game.
cmake --preset macos-arm64-relwithdebinfo -S "$ROOT"
cmake --build --preset macos-arm64-relwithdebinfo
GAME_DIR="$ROOT/out/build/macos-arm64-relwithdebinfo/RelWithDebInfo"

# Launcher (launcher2/, SDL3 + Dear ImGui, built from the SDK's bundled sources).
LAUNCHER_BUILD="$ROOT/out/build/launcher2-macos"
if [ ! -f "$LAUNCHER_BUILD/CMakeCache.txt" ]; then
  cmake -S "$ROOT/launcher2" -B "$LAUNCHER_BUILD" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
fi
cmake --build "$LAUNCHER_BUILD" --target wwe13-launcher

# Assemble: launcher, game and the FFmpeg libraries under the names the game loads (@rpath).
OUT="$ROOT/out/macos-arm64"
mkdir -p "$OUT"
cp -f "$LAUNCHER_BUILD/wwe13-launcher" "$GAME_DIR/wwe13" "$OUT/"
cp -f "$GAME_DIR"/libavcodec.58.dylib "$GAME_DIR"/libavutil.56.dylib "$OUT/"
echo "Built: $OUT"
echo "  Start the launcher: \"$OUT/wwe13-launcher\" (Play starts ./wwe13 from the same folder)."
echo "  Put the game folder at \"$OUT/WWE 13\", or choose it on the launcher's Game files page."
