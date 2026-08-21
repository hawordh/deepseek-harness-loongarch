# Agent Note: LoongArch64 原生依赖策略

Status: implemented

[English](2026-08-17-loongarch64-native-dependency-strategy.md) | 中文

## 问题

harness 需要以 Web 模式运行在 loongarch64（Debian）上，但多个 npm 原生依赖没有预编译的 loong64 二进制，普通的 `pnpm install` 之后整棵依赖树无法运行。最初的修复全部手工完成在 `node_modules` 内：编译好的 lightningcss 与 rolldown binding、node-gyp 构建的 sharp addon、手工创建的 `@img/sharp-linux-loong64` 平台包、对已安装 sharp 包 `dist` 的修改、根目录 workspace 符号链接，以及全局关闭 lefthook 构建。全新的克隆无法复现其中任何一项——它们要么位于被 gitignore 的目录里，要么位于下一次 `pnpm install` 就会重写的文件中。此外，HMR 因为进程缺少 `--expose-internals` 而拒绝启动。

## 决策

LoongArch64 的引导能力以 `scripts/loongarch/`（`setup.sh`、`verify.sh`、`run-dsh.sh`）、一个 lefthook 的 pnpm 补丁，以及 `README.md` 中的 LoongArch64 章节的形式入库：

- **sharp** 锁定在 `0.35.3`；其 addon 在已安装的包内用 node-gyp 重新编译，产物落在 `src/build/Release/sharp-linux-loong64-0.35.3.node`——加载器的首选查找路径，无需修改 `dist`，也无需伪造 `@img/sharp-linux-loong64` 包。libvips 8.18.3（sharp 的最低要求）用 meson 从源码编译进 `$VIPS_PREFIX`（默认 `$HOME/.local`）；`run-dsh.sh` 为其导出 `LD_LIBRARY_PATH`。
- **lightningcss** 1.32.0 与每个已安装的 rolldown 版本，均从各自锁定的上游 tag 源码编译（rust-toolchain 提升到 1.97.0 以获得 loongarch64 支持），并安装到解析器所期望的 pnpm store 布局中。
- **lefthook** 的 postinstall 在 loong64 上被补丁改为 no-op（`patches/lefthook@2.1.9.patch`），同时 `allowBuilds.lefthook` 保持 `true`，x64/arm64 的 hook 安装不受影响；`scripts/install-lefthook.mjs` 在 loong64 上跳过 hook 安装。
- `--expose-internals` 是 `dsh` 启动契约的一部分：根脚本直接携带该 flag，built-bin 验收测试也以该 flag 启动 `lib/bin.js`；因为 `vendor/hmr` 的构造器要求该参数、`NODE_OPTIONS` 无法携带它，且 loong64 没有 `node-addon-require-builtin` 的预编译包可以兜底。
- `setup.sh` 会重建缺失的 `node_modules/@deepseek-ai/dsh-client-ui-directory-picker-native` workspace 链接，并执行 `pnpm run build`，使 Web profile 所需的 built `lib/` 与 `apps/web/dist` 就位。
- `verify.sh` 对每个原生 binding、workspace 解析与 CLI 启动做冒烟验证。

## 曾考虑的替代方案

- **把预编译二进制入库。** 不予采纳：lightningcss、两个 rolldown binding 与 sharp 合计约 58MB，且都与本机的 glibc 与 libvips 绑定；源码编译脚本可以在任何 loong64 Debian 上复现同样的状态。
- **sharp 继续走 WASM 回退。** 不予采纳：sharp 0.35.3 不识别 `SHARP_FORCE_WASM`，本机验证通过的最终状态是原生 addon。
- **保持关闭 `allowBuilds.lefthook`。** 不予采纳：这同样会抑制 x64/arm64 上本应启用的 lefthook 构建；按架构生效的补丁把 no-op 限定在 loong64。

## 后果

- 全新的 loong64 机器只需运行一条命令（`./scripts/loongarch/setup.sh`），不再需要手工编译与建立符号链接的序列；首次运行的原生编译需要几十分钟到一小时。
- loong64 机器没有 lefthook git hooks（没有预编译二进制）；CI 与 x64/arm64 贡献者不受影响。
- sharp 运行时需要 `LD_LIBRARY_PATH`（或 `run-dsh.sh` 包装脚本）来找到用户编译的 libvips。
- 后续新增没有 loong64 预编译的原生依赖（例如 swc、未来的 rolldown 版本）需要同样的源码编译处理；运行手册记录了该模式。
