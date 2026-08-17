#!/usr/bin/env bash
#
# Smoke-check every LoongArch64-specific fix in a configured tree. Exits
# non-zero on the first failure. Used by setup.sh; safe to run on its own.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [ "$(node -p 'process.arch' 2>/dev/null || true)" != "loong64" ]; then
  echo "error: verify.sh targets loong64; current arch: $(node -p 'process.arch' 2>/dev/null || echo unknown)" >&2
  exit 1
fi

VIPS_PREFIX="${VIPS_PREFIX:-$HOME/.local}"
export LD_LIBRARY_PATH="$VIPS_PREFIX/lib/loongarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '\033[32mok\033[0m  %s\n' "$label"
  else
    printf '\033[31mFAIL\033[0m  %s\n' "$label" >&2
    exit 1
  fi
}

check "sharp native addon loads (libvips $(PKG_CONFIG_PATH="$VIPS_PREFIX/lib/loongarch64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" pkg-config --modversion vips-cpp 2>/dev/null || echo '?'))" \
  bash -c "cd packages/attachment/attachment-local && node -e \"const s = require('sharp'); if (!s.versions.sharp) process.exit(1)\""

check "lightningcss addon loads" \
  node -e "const { createRequire } = require('node:module'); const r = createRequire(process.cwd() + '/x.js'); const l = r('lightningcss'); if (typeof l.transform !== 'function') process.exit(1)"

for dir in $(find node_modules/.pnpm -maxdepth 1 -type d -name 'rolldown@[0-9]*' 2>/dev/null | sort -uV); do
  version="$(basename "$dir" | sed -E 's/^rolldown@([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
  check "rolldown $version binding loads" \
    bash -c "cd '$dir/node_modules/rolldown' && node --input-type=module -e \"const m = await import('rolldown'); if (!m.VERSION) process.exit(1)\""
done

check "workspace package @deepseek-ai/dsh-client-ui-directory-picker-native resolves" \
  node --import tsx/esm -e "await import('@deepseek-ai/dsh-client-ui-directory-picker-native')"

check "dsh CLI boots with --expose-internals" \
  node --expose-internals --import tsx/esm apps/cli/src/bin.ts --version

echo
echo "verification passed; start the web UI with ./scripts/loongarch/run-dsh.sh web"
