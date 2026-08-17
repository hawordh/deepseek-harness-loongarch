#!/usr/bin/env bash
#
# `dsh` wrapper for loong64: exports LD_LIBRARY_PATH so the sharp addon can
# find the locally built libvips, then execs the normal pnpm dsh command.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

VIPS_PREFIX="${VIPS_PREFIX:-$HOME/.local}"
export LD_LIBRARY_PATH="$VIPS_PREFIX/lib/loongarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

exec pnpm dsh "$@"
