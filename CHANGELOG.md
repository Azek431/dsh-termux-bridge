# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.2.3] —— 2026-10-26

### 新增

- `scripts/push-to-github.sh`：一键发布到 GitHub。DSH 跑在 proot 客人里，看不到 Termux 的
  `~/.config/gh/oauth_token`，客人里的 `gh` 永远是未登录状态；仓库源码在 Android 共享存储上，
  Termux 与客人看到同一个目录，所以在 Termux 里跑这个脚本即可建仓并推送。脚本负责：
  前置检查（git/gh/登录态）、`gh auth setup-git`、补 `git safe.directory`、推断 owner、
  `gh repo create`、`git push`、补 description/homepage/topics（`dsh-plugin` 等 8 个）。

### 修复

- 试运行（stub 掉 `gh`/`git push` 的完整演练）抓到两个真问题并已修：
  1. **`gh auth login` 不会把 gh 装成 git 的 credential helper**，缺 `gh auth setup-git` 时
     `gh repo create --push` 与 `git push` 都死在 `could not read Username for 'https://github.com'`；
  2. 建仓与推送原来耦合在 `gh repo create --push` 一条命令里，推送失败时无法区分是建仓失败还是
     凭据失败。现拆成 create → push 两步，push 失败直接打印 `gh auth setup-git` 与
     `gh auth refresh -s repo` 两条修法。

### 文档

- README 新增第 9 节「发布到 GitHub」：为什么这一步必须在 Termux 里做、一条命令、脚本做的七件事、
  共享存储上 git 的两个坑（dubious ownership / chmod 不生效导致权限位不进 index）。
- 原「作者」「许可证」两节顺延为第 10、11 节。

## [1.2.2] —— 2026-10-26

### 新增

- `scripts/ensure-installed.sh`：本地插件自愈守卫。DSH profile 用 pnpm 管依赖，而 @local
  插件是手工装配进去的、不在 `dependencies` 里，任何一次 `pnpm install` / GUI 里装别的插件
  都会把它当幽灵依赖删掉（目录没了、bundles 还记着它 → 下次重启 dsh 插件静默消失）。
  脚本检测 `node_modules/@local/<pkg>/package.json` 是否存在，缺失就重跑对应安装器。
  支持 `--check` 只自检（缺失时退出码 1），覆盖 dsh-termux-bridge / dsh-mobile-adapt /
  mobile-pilot / browser-use 四个包。

### 文档

- README 新增 2.1 节「装完之后请跑一次自检」，说明幽灵依赖的成因与 `--check` 用法。
- 文档库新增 INC-0009（pnpm 把本地插件当幽灵依赖清掉），记录了两次中招时间点与
  `.plugin-manager/logs/*/pnpm.log` 里 `Packages: +2 -52` 这个关键证据。

## [1.2.1] —— 2026-10-26

### 修复（都是 agent 侧的生命周期缺陷，跟协议无关）

- **令牌错时 agent 变成无限重连的僵尸进程**。老实现对**所有** `DENY` 都是 `break` 后
  立刻重连，而 `E_BAD_TOKEN` / `E_PROTO_MISMATCH` 这类拒绝重连一万次也不会变好 ——
  结果是每 3 秒一次的重连循环，进程永远留在后台，谁都看不见。
  症状：跑几轮测试后 `ps` 里躺着四五个 `bash .../agent.sh`，最老的一个已经挂了 2h41m。
  修法：`DENY` 按 code 分流 —— 令牌错/协议不匹配 = `FATAL=1` 直接退出；其它
  （`E_TOO_MANY_AGENTS` 等可自愈的）退避 10 秒再试。
- **连不上时退避与上限**。原来是固定 `sleep 3` 无限重试。改成指数退避
  （3,6,12,24,30,30…，封顶 30 秒），并新增 `DSH_BRIDGE_MAX_FAIL`：设成 >0 时连续失败
  该次数就退出（默认 0 = 无限重试，保持「DSH 重启后 agent 自己接回去」的既有行为）。
  测试用它保证 agent 不会变成孤儿进程。
- **同名 agent 去重（服务端）**。同一个 Termux 起两份 agent，或上次运行的残留连接还在
  重连时，会白占 `maxAgents`，且 `#idleAgent()` 可能挑到那条半死的连接。新连接用同名
  注册时顶掉旧的。
  **这里踩了一个坑**：第一版直接 `socket.destroy()`，被顶掉的那个立刻重连、又反过来把
  新的顶掉 —— 两条连接乒乓对踢永不收敛，测试因此挂死 2 分钟。正解是先发 `BYE` 帧再断，
  agent 收到 `BYE` 视为致命并退出。

### 测试

- `test/smoke.cjs` 与 `test/bridge.test.cjs` 改用**随机端口 + 随机令牌**。原来冒烟用固定
  `18791` + 固定 `smoketoken`，上一轮跑崩残留的 agent 带着同一个令牌会自动接进下一轮，
  把「没有 agent」的断言打成假的 —— 这就是那次「冒烟测试莫名其妙失败、代码根本没改」
  的真正原因。
- 新增 2 条回归用例（令牌错时 agent 自己退出、同名 agent 只保留一条且 3 秒内不乒乓）。
  用例总数 18 → 20。

## [1.2.0] —— 2026-10-26

### 变更（破坏性：包名与仓库名）

- **包名 `@local/termux-bridge` → `@local/dsh-termux-bridge`，仓库名 `termux-bridge` → `dsh-termux-bridge`**。
  原因：DSH 官方插件约定包名与仓库名都取 `dsh-<能力>` 形态（见 dsh-plugin-guide 的
  `guide/release-engineering.zh-CN.md` 第 1 节「能扩展的布局与命名」），这样在 GitHub 上
  靠 topic `dsh-plugin` + package keywords 才可发现。旧名是 `@local/` 私有形态，不符合约定。
- 随之改动的内部标识：`dsh.profile.bundles` 条目、`cordis.patch.yml` 的 id/name、
  阶段目录与备份位前缀（`.dsh-termux-bridge-{stage,backup}.*`）、所有权清单
  `.dsh-termux-bridge-install.json`、日志前缀 `dsh-termux-bridge:`。
- **保持不变（有意为之）**：`plugin/agent/termux-bridge-agent.sh` 文件名、工具名
  `termux_*`、协议与端口。改名脚本名会让用户 Termux 侧已装好的 agent 失联，
  而工具名是模型看到的面，改名没有收益只有风险。

### 升级注意

- 这是重命名，不是原地升级：先跑旧 `uninstall.sh`（或手工从 profile 的
  `dsh.profile.bundles` 摘掉 `@local/termux-bridge` 并删
  `node_modules/@local/termux-bridge`），再跑新 `install.sh`。两个包同时注册会让
  `termux_*` 工具重复注册。装完重启 dsh。


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
