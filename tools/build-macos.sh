#!/usr/bin/env bash
# Build the game for macOS (Apple silicon). Run ./tools/setup-macos.sh and ./tools/codegen.sh first.
# Running it needs MoltenVK and the Vulkan loader (`brew install molten-vk vulkan-loader`).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test -f "$ROOT/generated/sources.cmake" || { echo "Run ./tools/codegen.sh first." >&2; exit 1; }
"$ROOT/tools/ensure-rexglue-cmake.sh"
cmake --preset macos-arm64-relwithdebinfo -S "$ROOT"
cmake --build --preset macos-arm64-relwithdebinfo
echo "Built: $ROOT/out/build/macos-arm64-relwithdebinfo/RelWithDebInfo/wwe13"
