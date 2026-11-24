#!/usr/bin/env bash
# tools/build-ppc-binutils-macos.sh: build powerpc-none-elf binutils with Xbox 360 VMX128 support
# for macOS (Apple silicon), for the ReXGlue PowerPC instruction tests (ppc_tests).
#
# The tests assemble with -mvmx128, which upstream binutils does not have. This builds GNU
# binutils 2.24 with Xenia's VMX128 patch (tools/ppc-binutils/binutils-2.24-vmx128.patch, from
# xenia-project/xenia third_party/binutils), the same assembler the SDK ships for Linux and
# Windows. Binutils 2.24 predates Apple silicon and Xcode's newer C defaults, so the build triple
# is given explicitly and the old C is compiled as gnu89 with the now-default errors relaxed.
#
# Usage: tools/build-ppc-binutils-macos.sh [PREFIX]   (default: ../tools/ppc-binutils-vmx128)
# Then:  REXGLUE_TESTS=1 PPC_BINUTILS_DIR=PREFIX/bin ./tools/setup-macos.sh
#
# Needs: Xcode (or its Command Line Tools), curl, make, patch.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PREFIX=${1:-"$ROOT/../tools/ppc-binutils-vmx128"}
VERSION=2.24
SHA256=4930b2886309112c00a279483eaef2f0f8e1b1b62010e0239c16b22af7c346d4
PATCH="$ROOT/tools/ppc-binutils/binutils-$VERSION-vmx128.patch"
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script is for macOS. On Linux and Windows the SDK ships these tools." >&2
  exit 1
fi
mkdir -p "$PREFIX"
PREFIX=$(cd "$PREFIX" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppc-binutils.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "== Downloading GNU binutils $VERSION"
curl -fsSLO "https://ftpmirror.gnu.org/binutils/binutils-$VERSION.tar.gz"
echo "$SHA256  binutils-$VERSION.tar.gz" | shasum -a 256 -c -
tar xzf "binutils-$VERSION.tar.gz"

echo "== Applying the VMX128 patch"
(cd "binutils-$VERSION" && patch -p0 < "$PATCH")

echo "== Building (target powerpc-none-elf, prefix $PREFIX)"
mkdir build && cd build
TRIPLE="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin"
CFLAGS="-O2 -std=gnu89 -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int \
-Wno-int-conversion -Wno-incompatible-pointer-types -Wno-deprecated-non-prototype" \
  "../binutils-$VERSION/configure" --build="$TRIPLE" --host="$TRIPLE" \
  --target=powerpc-none-elf --prefix="$PREFIX" --disable-nls --disable-werror --disable-gdb \
  --disable-gprof --disable-sim --disable-dependency-tracking --with-system-zlib MAKEINFO=true \
  > configure.log 2>&1 || { tail -40 configure.log >&2; exit 1; }
make -j"$JOBS" MAKEINFO=true all-gas all-ld all-binutils > make.log 2>&1 ||
  { grep -E "error|\*\*\*" make.log | tail -40 >&2; exit 1; }
make MAKEINFO=true install-gas install-ld install-binutils > install.log 2>&1 ||
  { tail -40 install.log >&2; exit 1; }

"$PREFIX/bin/powerpc-none-elf-as" --help 2>&1 | grep -q -- -mvmx128 ||
  { echo "Built assembler has no -mvmx128" >&2; exit 1; }
echo "PowerPC binutils with VMX128 installed: $PREFIX/bin"
