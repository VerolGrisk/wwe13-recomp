#!/usr/bin/env bash
# tools/build-ios.sh: build the ReXGlue smoke test (rex_smoke) as an iOS / iPadOS app and package it
# as an unsigned-for-distribution IPA (ad-hoc signed, with the entitlements the game needs) for a
# signing service such as Signulous, or for Xcode/devicectl installs.
#
# Run on a Mac with Xcode (iOS SDK) after ./tools/setup-macos.sh, which fetches and patches the SDK.
# The first milestone is rex_smoke: window, MoltenVK on the iPad GPU, guest memory (Mach memory
# entries on iOS), MMIO traps, address-space limits. The game itself comes later.
#
# Env:
#   MOLTENVK_VERSION     MoltenVK release to download (default v1.4.2)
#   MOLTENVK_SHA256      expected SHA-256 of the release archive (printed on first download)
#   MOLTENVK_FRAMEWORK   use this ios-arm64 MoltenVK.framework instead of downloading one
#                        (e.g. from the LunarG Vulkan SDK: .../iOS/lib/MoltenVK.xcframework/
#                        ios-arm64/MoltenVK.framework)
#   BUILD_JOBS           parallel build jobs (default: performance cores)
#   CONFIG               RelWithDebInfo (default) or Release
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SDK="$ROOT/../tools/rexglue"
TOOLS="$ROOT/../tools"
CONFIG=${CONFIG:-RelWithDebInfo}
BUILD_JOBS=${BUILD_JOBS:-$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)}
MOLTENVK_VERSION=${MOLTENVK_VERSION:-v1.4.2}

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Build the iOS app on a Mac with Xcode." >&2
  exit 1
fi
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || {
  echo "The iOS SDK was not found: install Xcode (not only the Command Line Tools) and run" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
}
for command in cmake ninja; do
  command -v "$command" >/dev/null || { echo "Missing $command (brew install cmake ninja)" >&2; exit 1; }
done
test -d "$SDK/.git" || { echo "Run ./tools/setup-macos.sh first (it fetches and patches the SDK)." >&2; exit 1; }

# --- MoltenVK for iOS (dynamic framework embedded in the app) ----------------------------------
if [ -n "${MOLTENVK_FRAMEWORK:-}" ]; then
  MVK_FRAMEWORK="$MOLTENVK_FRAMEWORK"
else
  MVK_DIR="$TOOLS/moltenvk-ios/$MOLTENVK_VERSION"
  MVK_FRAMEWORK=$(find "$MVK_DIR" -path "*dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework" \
                    -maxdepth 8 -type d 2>/dev/null | head -1 || true)
  if [ -z "$MVK_FRAMEWORK" ]; then
    mkdir -p "$MVK_DIR"
    archive="$MVK_DIR/MoltenVK-ios.tar"
    echo "== Downloading MoltenVK $MOLTENVK_VERSION for iOS"
    base="https://github.com/KhronosGroup/MoltenVK/releases/download/$MOLTENVK_VERSION"
    curl -fL --retry 3 -o "$archive" "$base/MoltenVK-ios.tar" ||
      curl -fL --retry 3 -o "$archive" "$base/MoltenVK-all.tar"
    sum=$(shasum -a 256 "$archive" | cut -d' ' -f1)
    if [ -n "${MOLTENVK_SHA256:-}" ] && [ "$sum" != "$MOLTENVK_SHA256" ]; then
      echo "MoltenVK archive checksum mismatch: got $sum, expected $MOLTENVK_SHA256" >&2
      rm -f "$archive"
      exit 1
    fi
    echo "   SHA-256 $sum (set MOLTENVK_SHA256 to verify future downloads)"
    tar -xf "$archive" -C "$MVK_DIR"
    rm -f "$archive"
    MVK_FRAMEWORK=$(find "$MVK_DIR" -path "*dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework" \
                      -maxdepth 8 -type d | head -1 || true)
  fi
fi
test -d "$MVK_FRAMEWORK" || {
  echo "No ios-arm64 MoltenVK.framework found (set MOLTENVK_FRAMEWORK to one)." >&2
  exit 1
}
echo "== MoltenVK: $MVK_FRAMEWORK"

# --- SDK + rex_smoke for iOS ---------------------------------------------------------------------
BUILD_DIR="$SDK/out/build/ios-arm64"
cmake -S "$SDK" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/toolchains/ios-arm64.cmake" \
  -DCMAKE_BUILD_TYPE="$CONFIG" \
  -DCMAKE_INSTALL_PREFIX="$SDK/out/install/ios-arm64" \
  -DREXGLUE_BUILD_TESTS=ON -DREXGLUE_ENABLE_FIDELITYFX=OFF -DREXGLUE_ENABLE_PERF_COUNTERS=OFF \
  -DREXGLUE_ENABLE_SANITIZERS=OFF -DREXGLUE_ENABLE_TRACY=OFF -DREXGLUE_FFMPEG_SHARED=OFF \
  -DREXGLUE_PROFILE_GUEST_FUNCTIONS=OFF -DREXGLUE_USE_VULKAN=ON \
  -DREXGLUE_IOS_MOLTENVK_FRAMEWORK="$MVK_FRAMEWORK"
ninja_args=(-j "$BUILD_JOBS")
[ "${KEEP_GOING:-0}" = "1" ] && ninja_args+=(-k 0)
cmake --build "$BUILD_DIR" --target rex_smoke -- "${ninja_args[@]}"

APP=$(find "$BUILD_DIR" -name "rex_smoke.app" -type d -maxdepth 5 | head -1)
test -d "$APP" || { echo "rex_smoke.app was not produced" >&2; exit 1; }

# --- Sign (ad-hoc, with the entitlements) and package --------------------------------------------
# A signing service re-signs with its own certificate; the ad-hoc signature carries the entitlement
# requests so they are visible to it. Frameworks are signed before the app.
codesign --force --sign - --timestamp=none "$APP/Frameworks/MoltenVK.framework"
codesign --force --sign - --timestamp=none --entitlements "$SDK/cmake/ios/app.entitlements" "$APP"

OUT="$ROOT/out/ios"
rm -rf "$OUT/Payload"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
( cd "$OUT" && rm -f ReXSmoke.ipa && zip -qry ReXSmoke.ipa Payload )
rm -rf "$OUT/Payload"
echo
echo "Built $OUT/ReXSmoke.ipa"
echo "Sign it with your signing service and install it. Logs go to the app's Documents folder"
echo "(Files app > On My iPad > ReX Smoke)."
