#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SDK="$ROOT/../tools/rexglue"
if [ "$(uname -s)" = "Darwin" ]; then
  REXGLUE_BIN="$SDK/out/macos-arm64/RelWithDebInfo/rexglue"  # tools/setup-macos.sh
else
  REXGLUE_BIN="$SDK/out/linux-amd64/RelWithDebInfo/rexglue"
fi
XEX="$ROOT/game/default.xex"
LOG="$ROOT/logs/codegen-$(date +%Y%m%d-%H%M%S).log"

test -x "$REXGLUE_BIN" || { echo "Run ./tools/setup.sh (Linux) or ./tools/setup-macos.sh (Mac) first." >&2; exit 1; }
test -f "$XEX" || { echo "Place or symlink your owned XEX at $XEX." >&2; exit 1; }
mkdir -p "$ROOT/logs"
"$REXGLUE_BIN" codegen "$ROOT/wwe13_config.toml" 2>&1 | tee "$LOG"
