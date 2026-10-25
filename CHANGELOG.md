# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.1] —— 2026-10-25

### 修复

- **大输出撕连接**：`MAX_LINE_BYTES`（帧上限）与 `MAX_OUTPUT_BYTES`（载荷上限）都是 1 MiB，
  而载荷经 base64 会膨胀到 `ceil(1048576/3)*4 = 1398104` 字节，超出帧上限后接收端直接
  `socket.destroy()`，调用方拿不到回包，被兜成 `E_AGENT_GONE` —— 症状像 "agent 崩了"，
  实际 agent 正常。定位阈值 786432 = 1 MiB × 3/4。
  修法：帧上限提到 16 MiB，新增 `MAX_PAYLOAD_BYTES = Math.floor((MAX_LINE_BYTES - 256) / 4) * 3`，
  由帧上限反推；`bridge.js` 增加 `clampPayload()` 统一夹紧 `exec` 与 `pull` 两处调用。
  补 2 条回归用例。

### 变更

- 测试从 16 条增至 18 条。

## [1.1.0] —— 2026-10-25

### 新增

- **local 执行面**（`plugin/lib/local.js`）：没有 agent 连接时，`backend=auto` 自动降级到
  DSH 客人自身的 Debian 环境执行。这意味着**不必后台挂着 Termux 也能执行命令**。
  依赖客人自带的 bash / node / pnpm / python3 / git / gcc / make / ffmpeg（apt 走 dshbox 的
  fakeroot wrapper 可装包）。
- 四个执行工具（`termux_exec` / `termux_run` / `termux_push` / `termux_pull`）新增 `backend`
  参数：`auto`（默认）| `termux` | `local`。
- `termux_status` 新增 `activeBackend` / `localReady` / `localTools` / `localCwd`。
- `plugin/scripts/termux-attach.sh`：用户侧一键挂载脚本（不内置令牌，每次现拉 `/agent`）。

### 变更

- 显式 `backend=termux` **不降级**：用户显式要 Termux 时，说明他要的是 Termux 的 uid /
  `~/storage` / pkg，偷偷换本地跑会得出错误结论。`auto` 才降级。

## [1.0.0] —— 2026-10-25

### 新增

- 初始版本：反向 TCP 桥接（客人监听 `127.0.0.1:8791`，Termux 侧零依赖 bash agent 连回）。
- 行帧协议（空格分列 + base64，空值写 `-`）。
- 6 个工具：`termux_status` / `termux_bootstrap` / `termux_exec` / `termux_run` /
  `termux_push` / `termux_pull`。
- 超时语义：agent 侧用 `runner.sh` 落退出码文件区分 "自己 exit 124" 与 "被 timeout 杀掉"。
- 事务式 `install.sh` / `uninstall.sh`（阶段目录 → 校验 → 备份 → 替换 → 注册 bundle → 回滚）。
- 14 条 `node:test` 用例 + 冒烟脚本。
