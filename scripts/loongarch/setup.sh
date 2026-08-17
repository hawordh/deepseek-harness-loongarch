#!/usr/bin/env bash
#
# LoongArch64 bootstrap for deepseek-harness.
#
# Turns a fresh clone on loongarch64 + Debian into a runnable tree:
#   1. apt build prerequisites (codec dev packages for libvips, meson, node-gyp deps)
#   2. pnpm install (lefthook postinstall is patched to a no-op on loong64)
#   3. libvips 8.18.3 from source into $VIPS_PREFIX (sharp 0.35.3 requires >= 8.18.3)
#   4. sharp native addon via node-gyp inside the installed sharp package
#   5. lightningcss 1.32.0 native addon from source
#   6. rolldown native bindings from source (one per installed rolldown version)
#   7. missing pnpm workspace links (documented LoongArch pnpm quirk)
#   8. pnpm run build, then verification
#
# Each step is idempotent: rerunning continues where it left off. Use
# --skip-<step> to skip a step explicitly. See README.md's LoongArch64 section
# for prerequisites and troubleshooting.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ARCH="$(node -p 'process.arch' 2>/dev/null || true)"
if [ "$ARCH" != "loong64" ]; then
  echo "error: setup.sh targets loong64 (loongarch64); current node arch: ${ARCH:-unknown}" >&2
  exit 1
fi

WORK="${WORK:-$ROOT/.loongarch-work}"
VIPS_PREFIX="${VIPS_PREFIX:-$HOME/.local}"
VIPS_VERSION="${VIPS_VERSION:-8.18.3}"
LIGHTNINGCSS_VERSION="${LIGHTNINGCSS_VERSION:-1.32.0}"

skip_apt=0
skip_install=0
skip_libvips=0
skip_sharp=0
skip_lightningcss=0
skip_rolldown=0
skip_build=0
skip_verify=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "options:"
  echo "  --skip-apt          skip apt-get install of build prerequisites"
  echo "  --skip-install      skip \`pnpm install\` (already-installed tree)"
  echo "  --skip-libvips      skip the libvips source build (must provide your own >= $VIPS_VERSION)"
  echo "  --skip-sharp        skip the sharp node-gyp build"
  echo "  --skip-lightningcss skip the lightningcss source build"
  echo "  --skip-rolldown     skip the rolldown binding builds (only needed for tsdown builds)"
  echo "  --skip-build        skip \`pnpm run build\`"
  echo "  --skip-verify       skip the final verification"
  echo "  -h, --help          print this help"
}

for arg in "$@"; do
  case "$arg" in
    --skip-apt) skip_apt=1 ;;
    --skip-install) skip_install=1 ;;
    --skip-libvips) skip_libvips=1 ;;
    --skip-sharp) skip_sharp=1 ;;
    --skip-lightningcss) skip_lightningcss=1 ;;
    --skip-rolldown) skip_rolldown=1 ;;
    --skip-build) skip_build=1 ;;
    --skip-verify) skip_verify=1 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

log() { printf '\n\033[1;34m[loongarch]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[loongarch warning]\033[0m %s\n' "$*" >&2; }

version_ge() {
  local a=() b=() i
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  for i in 0 1 2; do
    [ "${a[i]:-0}" -gt "${b[i]:-0}" ] && return 0
    [ "${a[i]:-0}" -lt "${b[i]:-0}" ] && return 1
  done
  return 0
}

vips_pkg_config() {
  PKG_CONFIG_PATH="$VIPS_PREFIX/lib/loongarch64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" pkg-config --modversion vips-cpp 2>/dev/null || true
}

ensure_rust() {
  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found; install rustup (https://rustup.rs) with the loongarch64-unknown-linux-gnu target" >&2
    exit 1
  fi
  if ! rustup target list --installed 2>/dev/null | rg -q '^loongarch64-unknown-linux-gnu$'; then
    rustup target add loongarch64-unknown-linux-gnu
  fi
}

apt_install() {
  local required=(
    build-essential pkg-config git curl python3 meson ninja-build
    libglib2.0-dev libjpeg-dev libpng-dev libwebp-dev libexif-dev libexpat1-dev zlib1g-dev
    libfftw3-dev libarchive-dev libcfitsio-dev libimagequant-dev libcgif-dev
    libcairo2-dev libpango1.0-dev libfontconfig1-dev libfreetype-dev libharfbuzz-dev
    liblcms2-dev libtiff-dev libgdk-pixbuf-2.0-dev
  )
  # Optional codecs: their absence only reduces libvips format coverage.
  local optional=(
    libheif-dev libopenexr-dev librsvg2-dev libhdf5-dev libdav1d-dev
    libaom-dev libde265-dev libx265-dev libjxl-dev libpoppler-dev libopenslide-dev
    libopenjp2-7-dev libbrotli-dev libbz2-dev liblz4-dev liblzma-dev libzstd-dev
    libxml2-dev libmatio-dev libcurl4-gnutls-dev
  )
  local apt=("${required[@]}")
  for pkg in "${optional[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1 || apt-cache show "$pkg" >/dev/null 2>&1; then
      apt+=("$pkg")
    fi
  done
  if [ "$(id -u)" -eq 0 ]; then
    apt-get update
    apt-get install -y "${apt[@]}"
  else
    sudo apt-get update
    sudo apt-get install -y "${apt[@]}"
  fi
}

build_libvips() {
  local current
  current="$(vips_pkg_config)"
  if [ -n "$current" ] && version_ge "$current" "$VIPS_VERSION"; then
    log "libvips $current found (>= $VIPS_VERSION); skipping source build"
    return 0
  fi
  local src="$WORK/libvips-$VIPS_VERSION"
  if [ ! -d "$src/.git" ] || [ ! -f "$src/meson.build" ]; then
    rm -rf "$src"
    log "cloning libvips v$VIPS_VERSION"
    git clone --depth 1 --branch "v$VIPS_VERSION" https://github.com/libvips/libvips.git "$src"
  fi
  log "building libvips $VIPS_VERSION into $VIPS_PREFIX (this takes a while)"
  meson setup "$src/build" "$src" \
    --prefix="$VIPS_PREFIX" \
    -Dbuildtype=release \
    -Dcplusplus=true \
    -Ddocs=false \
    -Dexamples=false \
    -Dman-pages=false \
    -Dtest=false
  ninja -C "$src/build"
  ninja -C "$src/build" install
  if ! version_ge "$(vips_pkg_config)" "$VIPS_VERSION"; then
    echo "error: pkg-config still cannot find vips-cpp >= $VIPS_VERSION after install" >&2
    exit 1
  fi
}

sharp_root() {
  local dir
  dir="$(find node_modules/.pnpm -maxdepth 1 -type d -name 'sharp@0.35.3*' 2>/dev/null | head -n1 || true)"
  if [ -n "$dir" ] && [ -d "$dir/node_modules/sharp" ]; then
    printf '%s' "$dir/node_modules/sharp"
  fi
}

build_sharp() {
  local root addon
  root="$(sharp_root)"
  if [ -z "$root" ]; then
    echo "error: sharp@0.35.3 not installed; run \`pnpm install\` first" >&2
    exit 1
  fi
  addon="$root/src/build/Release/sharp-linux-loong64-0.35.3.node"
  if [ -f "$addon" ]; then
    log "sharp addon already present: $addon"
    return 0
  fi
  export PKG_CONFIG_PATH="$VIPS_PREFIX/lib/loongarch64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LD_LIBRARY_PATH="$VIPS_PREFIX/lib/loongarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  local node_gyp
  node_gyp="$(npm root -g 2>/dev/null || true)/npm/node_modules/node-gyp/bin/node-gyp.js"
  [ -f "$node_gyp" ] || node_gyp="$(command -v node-gyp || true)"
  if [ -z "$node_gyp" ]; then
    echo "error: node-gyp not found (bundled with npm, or install the Debian node-gyp package)" >&2
    exit 1
  fi
  log "building sharp addon with node-gyp (against libvips $VIPS_VERSION)"
  (cd "$root" && node "$node_gyp" rebuild --directory=src)
  if [ ! -f "$addon" ]; then
    echo "error: sharp build did not produce $addon" >&2
    exit 1
  fi
}

build_lightningcss() {
  local target="node_modules/lightningcss/lightningcss.linux-loong64-gnu.node"
  if [ -f "$target" ]; then
    log "lightningcss addon already present: $target"
    return 0
  fi
  local src="$WORK/lightningcss-$LIGHTNINGCSS_VERSION"
  if [ ! -d "$src/.git" ] || [ ! -f "$src/package.json" ]; then
    rm -rf "$src"
    log "cloning lightningcss v$LIGHTNINGCSS_VERSION"
    git clone --depth 1 --branch "v$LIGHTNINGCSS_VERSION" https://github.com/parcel-bundler/lightningcss.git "$src"
  fi
  # The release pins a rust-toolchain that predates stable loongarch64 support.
  sed -i -E 's/^channel = "1\.[0-9][0-9]\.[0-9]"$/channel = "1.97.0"/' "$src/rust-toolchain.toml"
  log "installing lightningcss build dependencies"
  (cd "$src" && npm install --no-audit --no-fund)
  log "building lightningcss (cargo release; this takes a while)"
  (cd "$src" && npm run build -- --release)
  if [ ! -f "$src/lightningcss.linux-loong64-gnu.node" ]; then
    echo "error: lightningcss build did not produce lightningcss.linux-loong64-gnu.node" >&2
    exit 1
  fi
  install -m 0755 "$src/lightningcss.linux-loong64-gnu.node" "$target"
  log "installed lightningcss addon"
}

build_rolldown() {
  local dirs
  dirs="$(find node_modules/.pnpm -maxdepth 1 -type d -name 'rolldown@[0-9]*' 2>/dev/null | sort -uV)"
  if [ -z "$dirs" ]; then
    log "no rolldown packages installed; skipping rolldown bindings"
    return 0
  fi
  for dir in $dirs; do
    local version
    version="$(basename "$dir" | sed -E 's/^rolldown@([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    local installed="$dir/node_modules/rolldown"
    local binding="$installed/dist/shared/rolldown-binding.linux-loong64-gnu.node"
    if [ -f "$binding" ]; then
      log "rolldown $version binding already present"
      continue
    fi
    local src="$WORK/rolldown-${version}"
    if [ ! -d "$src/.git" ] || [ ! -f "$src/Cargo.toml" ]; then
      rm -rf "$src"
      log "cloning rolldown v$version"
      git clone --depth 1 --branch "v$version" https://github.com/rolldown/rolldown.git "$src"
    fi
    sed -i -E 's/^channel = "1\.[0-9][0-9]\.[0-9]"$/channel = "1.97.0"/' "$src/rust-toolchain.toml"
    log "installing rolldown workspace dependencies (pnpm install; this takes a while)"
    (cd "$src" && pnpm install --frozen-lockfile)
    log "building rolldown $version binding (cargo release; this takes a while)"
    (cd "$src/packages/rolldown" && pnpm build-binding:release)
    local built="$src/packages/rolldown/src/rolldown-binding.linux-loong64-gnu.node"
    if [ ! -f "$built" ]; then
      echo "error: rolldown build did not produce $built" >&2
      exit 1
    fi
    install -m 0755 "$built" "$binding"
    install -m 0755 "$built" "$installed/dist/rolldown-binding.linux-loong64-gnu.node" || true
    log "installed rolldown $version binding"
  done
}

fix_workspace_links() {
  local scoped="node_modules/@deepseek-ai"
  mkdir -p "$scoped"
  local link="$scoped/dsh-client-ui-directory-picker-native"
  if [ -L "$link" ] && [ -e "$link" ]; then
    log "workspace link ok: $link"
  else
    rm -f "$link"
    ln -s ../../packages/client/ui-directory-picker-native "$link"
    log "created workspace link: $link"
  fi
}

main() {
  log "loong64 bootstrap for deepseek-harness ($ROOT)"
  ensure_rust
  if [ "$skip_apt" -eq 0 ]; then
    log "installing apt build prerequisites (sudo may prompt)"
    apt_install
  fi
  if [ "$skip_install" -eq 0 ]; then
    log "pnpm install"
    pnpm install --frozen-lockfile
  fi
  if [ "$skip_libvips" -eq 0 ]; then
    build_libvips
  fi
  if [ "$skip_sharp" -eq 0 ]; then
    build_sharp
  fi
  if [ "$skip_lightningcss" -eq 0 ]; then
    build_lightningcss
  fi
  if [ "$skip_rolldown" -eq 0 ]; then
    build_rolldown
  fi
  fix_workspace_links
  if [ "$skip_build" -eq 0 ]; then
    log "building workspace (tsc + tsdown + web)"
    pnpm run build
  fi
  if [ "$skip_verify" -eq 0 ]; then
    "$ROOT/scripts/loongarch/verify.sh"
  fi
  cat <<EOF

[loongarch] setup complete.
Run the web UI with:
    ./scripts/loongarch/run-dsh.sh web

If you see \`libvips-cpp.so.42: cannot open shared object file\` errors, make sure
LD_LIBRARY_PATH contains $VIPS_PREFIX/lib/loongarch64-linux-gnu
(run-dsh.sh sets it automatically; add the same export to your shell rc for
plain \`pnpm dsh\` invocations).
EOF
}

main
