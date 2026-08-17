# Agent Note: LoongArch64 native dependency strategy

Status: implemented

English | [中文](2026-08-17-loongarch64-native-dependency-strategy.zh.md)

## Problem

The harness runs on loongarch64 (Debian) in Web mode, but several npm native dependencies ship no prebuilt loong64 binaries, so a plain `pnpm install` leaves the tree un-runnable. The original fixes were applied by hand inside `node_modules`: compiled lightningcss and rolldown bindings, a node-gyp-built sharp addon, a hand-created `@img/sharp-linux-loong64` platform package, edits to the installed sharp `dist`, a root-level workspace symlink, and a global lefthook build toggle. A fresh clone could not reproduce any of it — everything lived in gitignored directories or in files the next `pnpm install` rewrites. HMR also refused to start because the process lacked `--expose-internals`.

## Decision

LoongArch64 bootstrap lives in the repo as `scripts/loongarch/` (`setup.sh`, `verify.sh`, `run-dsh.sh`), a pnpm patch for lefthook, and the runbook at `deepseek_harness_build.md`:

- **sharp** stays pinned at `0.35.3`; its addon is rebuilt with node-gyp inside the installed package so it lands at `src/build/Release/sharp-linux-loong64-0.35.3.node`, the loader's first lookup path — no patched `dist` and no fabricated `@img/sharp-linux-loong64` package. libvips 8.18.3 (sharp's minimum) is built from source with meson into `$VIPS_PREFIX` (default `$HOME/.local`); `run-dsh.sh` exports `LD_LIBRARY_PATH` for it.
- **lightningcss** 1.32.0 and each installed rolldown version are compiled from their pinned upstream tags (rust-toolchain bumped to 1.97.0 for loongarch64 support) and installed into the pnpm store layout the resolvers expect.
- **lefthook**'s postinstall is patched to a no-op on loong64 (`patches/lefthook@2.1.9.patch`) while `allowBuilds.lefthook` stays `true`, so x64/arm64 hook installs are unchanged; `scripts/install-lefthook.mjs` skips hook setup on loong64.
- `--expose-internals` is part of the `dsh` launch contract: the root script carries the flag, and the built-bin acceptance suites launch `lib/bin.js` with it, because `vendor/hmr`'s constructor requires it, `NODE_OPTIONS` cannot carry it, and loong64 has no `node-addon-require-builtin` prebuild to fall back on.
- `setup.sh` recreates the missing `node_modules/@deepseek-ai/dsh-client-ui-directory-picker-native` workspace link and runs `pnpm run build` so the web profile's built `lib/` and `apps/web/dist` exist.
- `verify.sh` smoke-tests every native binding, workspace resolution, and CLI boot.

## Alternatives considered

- **Vendor the prebuilt binaries.** Rejected: roughly 58MB across lightningcss, two rolldown bindings, and sharp, all tied to this machine's glibc and libvips; a source-build script reproduces the same state on any loong64 Debian.
- **Keep the WASM fallback for sharp.** Rejected: `SHARP_FORCE_WASM` is not honored by sharp 0.35.3, and the verified working state on this machine is the native addon.
- **Leave `allowBuilds.lefthook` disabled.** Rejected: it also suppresses lefthook builds on x64/arm64, where the hooks are wanted; a per-architecture patch confines the no-op to loong64.

## Consequences

- A fresh loong64 machine runs one command (`./scripts/loongarch/setup.sh`) instead of the manual compile-and-symlink sequence; the first run takes tens of minutes to an hour of native builds.
- loong64 machines have no lefthook git hooks (no prebuilt binary); CI and x64/arm64 contributors are unaffected.
- sharp requires `LD_LIBRARY_PATH` (or the `run-dsh.sh` wrapper) at runtime for the user-built libvips.
- New native dependencies without loong64 prebuilds (for example swc, future rolldown versions) need the same compile-from-source treatment; the runbook documents the pattern.
