# termux-bridge —— DSH ⇄ Termux 桥接插件

把手机上的 **Termux** 接成 DSH 的一条执行通道：模型可以在插件注册的 termux_* 工具里
跑 pkg install、访问 ~/storage、用 Termux 完整的 Linux 工具链。

**但它不是「必须先连 Termux 才能干活」** —— 插件有两个执行面，默认 auto 自动选：

| 执行面 | 何时生效 | 命令在哪跑 | 能干什么 |
|---|---|---|---|
| termux | 有 agent 连接（或 backend 显式写 termux） | Termux 的来宾环境 | pkg install、~/storage、Termux 的 uid |
| local  | 没有 agent 连接（或 backend 显式写 local） | DSH 客人自己的 Debian 13 | bash / gcc / make / node / pnpm / python3 / git / ffmpeg / sqlite3，apt 走 dshbox 的 fakeroot wrapper |

所以「不想把 Termux 挂后台」时照样能执行命令、装包、编译；「想用 Termux 的环境」时
在 Termux 里跑一次启动脚本，auto 就会自动切过去。

- 包名: @local/termux-bridge
- 版本: 1.1.1
- 许可证: GPL-3.0-only（见 LICENSE / NOTICE）
- 归属: DSHBox（本仓库自研，不含第三方源码）
- 变更历史: 见 [CHANGELOG.md](CHANGELOG.md)

---

## 1. 为什么需要桥接，以及为什么需要 local 兜底

DSH 跑在 App 的 **PRoot 客人**里。这个客人：

| 能力 | 状况 |
|---|---|
| 有没有 am / su / 直接调 Android 服务 | 没有（su 文件存在但对 untrusted_app 不可读；cmd activity 被 SecurityException 拒） |
| 和 Termux 有没有共享文件系统 | 没有（不是同一个 /data 视图；Termux 的 rootfs 在客人里根本不存在） |
| 和 Termux 有没有共享网络命名空间 | **有**（同一个 loopback，客人内 127.0.0.1:3080 就是宿主 Web GUI） |
| 客人自己有没有可用的 Linux 工具链 | **有**（Debian 13 trixie aarch64，见上表 local 列） |

前两条决定了「主动把 Termux 进程拉起来」不可能，所以桥接方向只能是 Termux 连回来：

    [DSH 客人] 监听 127.0.0.1:8791  ←—— 主动连回来 ——  [Termux 里的 bash agent]
         ↑                                                    ↓
     6 个 termux_* 工具                                 pkg / apt / ~/storage / git …

第四条决定了 **local 执行面**：客人本身就是一台能用的 Linux，只是此前插件只认 agent，
没连上就整条命令报 E_NO_AGENT。加上 local 之后，「不需要后台运行 Termux」这个诉求
才真正成立 —— 不是绕过 Termux，而是把一直在那儿、只是没被用起来的客人环境接上。

要连 Termux 时，用户在 Termux 里起一次 agent（可 nohup 常驻，起过一次就不用再管）：

    bash <(curl -s http://127.0.0.1:8791/agent)

---

## 2. 安装

    # 在 DSH 客人里
    bash install.sh                                 # 自动探测 profile（$DSH_HOME/profiles/web 等）
    bash install.sh /path/to/.dsh/profiles/web      # 或显式指定
    bash uninstall.sh                               # 卸载

装完**重启 dsh**。工具列表里会多出 6 个 termux_* 工具。

install.sh 的事务顺序（照抄 mobile-pilot 的骨架）：

1. 预检：python3 在不在、必需文件齐不齐、profile 的 dsh.profile.bundles 是不是 list；
2. 复制到阶段目录 node_modules/@local/.termux-bridge-stage.<pid>，在阶段目录上跑
   node --check（四个 JS）与 bash -n（agent 脚本）以及文件清单核对；
3. 旧包整体挪进备份位 → 新包改名上位 → 发布后复检清单；
4. 往 dsh.profile.bundles 追加 @local/termux-bridge（临时文件 + 原子改名）；
5. 写 .termux-bridge-install.json 所有权清单。

任一步失败：首装则撤半包 + 摘 bundle 条目；升级则把旧包放回原位（旧版保持可用）。
**这条链路不是原子操作，重装/升级前先停 dsh。**

---

## 3. 工具

| 工具 | 作用 |
|---|---|
| termux_status | 监听状态、端口、已连 agent、累计任务数、最近错误、**下一个命令走哪个执行面**、客人工具链探测。排障第一步。 |
| termux_bootstrap | 生成 Termux 侧启动命令、URL 与脚本正文（inline:false 可只要命令）。不跑也能执行命令。 |
| termux_exec | 执行一段 bash 脚本正文。支持 cwd / backend / timeoutMs / maxBytes。 |
| termux_run | 以 argv 数组执行命令（不经过 shell 二次解析，最安全）。 |
| termux_push | 把文本写到目标路径（覆盖写，目录不存在自动建）。 |
| termux_pull | 读目标文件（默认最多 8 MiB）。 |

所有工具的输出都是结构化对象，字段固定：
ok / code / text / exitCode / elapsedMs / truncated / timedOut（+ 各自扩展字段，
exec / run / push / pull 另有 backend 表示实际执行面）。
**机器判读读字段，不要解析 text。**

### backend 参数（exec / run / push / pull）

| 值 | 行为 |
|---|---|
| 留空或 auto（默认） | 有 agent 连接 → termux；没有 → local。这是日常最省心的用法。 |
| termux | 强制走 Termux。**没有 agent 时直接报 E_NO_AGENT，不降级** —— 这时候你要的是 Termux 的 uid / ~/storage / pkg，偷偷换成客人本地跑会得出错误结论。 |
| local | 强制走客人本地 Debian，即使有 agent 连接。 |

一个容易忽略的细节：两个执行面看到的**文件系统不一样**。同一个路径 /tmp/x 在 local 里是
客人的 /tmp，在 termux 里是 Termux 的 /tmp；~/ 也是各自的。跨面读文件要用对应 backend 的
push / pull，不要以为写一次两边都能看见。

错误码：E_NO_AGENT（强制 termux 但没连上）、E_AGENT_BUSY（队列满/agent 忙）、
E_AGENT_TIMEOUT（等回包超时，远端可能仍在跑）、E_AGENT_GONE（连接中断，结果未知）、
E_TIMEOUT（命令被 timeoutMs 强杀，timedOut=true）、E_INVALID_ARGUMENT（backend 写错）。

### 超时语义（容易踩）

两个执行面用同一套语义，但机制不同：

- agent 侧：用 runner.sh 把「命令自己的退出码」写进文件，再让 timeout 包着 runner 跑。
  文件里有值 → 命令真的退出过（**哪怕它自己 exit 124**）；文件没写成 → 是被 timeout 杀的。
- local 侧：Node 侧计时器到点直接 SIGKILL 整个进程组（detached 起，防孙进程漏网），
  然后统一归到 exitCode=124 / timedOut=true。

只看 $? 会把「命令自己 exit 124」和「被超时杀掉」混成一件事，这是本插件刻意绕开的坑。

---

## 4. 协议（自定义行帧，纯 bash 可实现）

一行一帧，空格分列；**所有可能含空格的字段一律 base64，空值写 -**。

    HELLO  <ver> <token_b64> <name_b64>
    WELCOME <ver> <host_b64>              |  DENY <code> <text_b64>
    EXEC   <id> <timeout_ms> <cwd_b64|-> <script_b64> <max_bytes>
    PUT    <id> <w|a> <path_b64> <data_b64>
    GET    <id> <path_b64> <max_bytes>
    RESULT <id> <exit> <elapsed_ms> <trunc 0|1> <stdout_b64|-> <stderr_b64|-> <timed_out 0|1>
    DATA   <id> <exit> <data_b64|-> <stderr_b64|-> <trunc 0|1>
    PING   <id>  ->  PONG <id>

约束：PROTO_VERSION=1、MAX_LINE_BYTES=1 MiB、MAX_SCRIPT_BYTES=256 KiB。

同端口还兼一个极简 HTTP 面（按首行 GET/HEAD 分流），只回 /agent 与 /agent.sh
（渲染好占位符的 agent 脚本），其余一律 404 —— 这就是 curl 那一行能拿到脚本的原因。

local 执行面不走这个协议：它是进程内调用 lib/local.js，直接 spawn bash。

---

## 5. 设计取舍

- **两个执行面一套字段**：local.runScript 刻意复刻 agent 侧的同名字段（exitCode 97 =
  cwd 不存在、timedOut 判定、truncated 语义），所以上层工具不用为两边写两套分支。
- **auto 降级是为了「能用」，显式 termux 不降级是为了「不错」**。
- **独立监听**，不改 webserver：webserver 是 host 的 required row，弄坏它整个 Host 起不来。
- **端口被占只降级**（+1..+9 顺延，再不行记 lastError），绝不抛异常：插件加载失败会让用户
  完全看不到原因，是最坏的表现形式。
- **串行派活**：一个 agent 同时只跑一条命令，排队上限 32。并跑会让 cwd / 资源竞争变得不可解释。
- **agent 零依赖**：只要求 bash + base64 + date + mktemp（Termux 基础包自带）。不装 nc/socat/jq/python。
- **local 超时打进程组**：detached:true + process.kill(-pid)，否则 bash 起了孙进程超时后会漏。
- **输出上限**：stdout 默认回 64 KiB（maxBytes 可到 1 MiB），stderr 最多 64 KiB；超了置 truncated。
  要更多内容就让执行面先重定向到文件，再用 pull 读。
- **令牌**：token 配置留空则每次启动随机生成。换令牌后必须重新取 agent 脚本，否则握手 DENY。

---

## 6. 配置（cordis.patch.yml 或 profile 配置）

| 键 | 默认 | 说明 |
|---|---|---|
| host | 127.0.0.1 | 监听地址，只建议 loopback |
| port | 8791 | 被占用自动顺延最多 9 个 |
| token | '' | 共享令牌，空 = 每次启动随机 |
| maxAgents | 8 | 同时连接的 agent 上限 |
| timeoutMs | 30000 | termux_exec / termux_run 的默认超时 |

---

## 7. 排障

| 现象 | 查这里 |
|---|---|
| 工具一条都不出现 | dsh 没重启；或 node_modules/@local/termux-bridge 不在；启动日志里找 termux-bridge: 前缀 |
| termux_status 说未启动 | 端口全被占（看 lastError）；换成空闲端口重装 |
| 命令报 E_NO_AGENT | 你把 backend 显式写成了 termux 但没连 agent。要么去掉 backend（auto 会走本地），要么在 Termux 里跑启动脚本 |
| 命令在客人本地跑了但你要 Termux | termux_status 看 activeBackend；需要 Termux 就起 agent，或显式 backend: "termux" |
| 一直 E_AGENT_TIMEOUT | Termux 里 agent 卡住或令牌不匹配；重新取脚本 |
| 命令回 E_TIMEOUT | 命令真被 timeoutMs 杀了；调大 timeoutMs 或让远端 nohup 到后台 |
| 输出被截断 | 调大 maxBytes，或先重定向到文件再 pull |
| local 面找不到某命令 | 客人里没有装。apt 走 /root/projects/.dsh/dshbox/bin/apt（fakeroot wrapper），装前先换中科大源 |

agent 侧有 --quiet 参数可关掉 stderr 日志。

---

## 8. 测试

    node --test test/bridge.test.cjs     # 16 条：协议 / 执行 / push-pull / 超时语义 / HTTP 面
    node test/smoke.cjs                  # 冒烟：真加载 profile 里的包，两个执行面各跑一遍

注意 node --test 跑完可能不退出（定时器未 unref），后台跑再 tail 日志，别前台等。

bridge.test.cjs 覆盖：握手执行、非零退出码透传、多行/heredoc、cwd、cwd 不存在（exit 97）、
argv 空格与 $(echo pwn) 不被二次展开、输出截断、超时强杀、命令自己 exit 124 不算超时、
掉线报错、多片 push/pull 往返、远端建目录、pull 缺失文件、无 agent、错令牌、HTTP 路由。

smoke.cjs 覆盖：无 agent 时 auto 落 local、local 执行/退出码/超时/cwd 缺失/push-pull、
强制 termux 无 agent 报 E_NO_AGENT、非法 backend 报 E_INVALID_ARGUMENT、
起 agent 后 auto 切 termux、termux 侧执行与 push-pull、有 agent 时强制 local 仍生效。
