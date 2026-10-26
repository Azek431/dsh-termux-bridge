# dsh-termux-bridge —— DSH ⇄ Termux 桥接插件

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)


把手机上的 **Termux** 接成 DSH 的一条执行通道：模型可以在插件注册的 termux_* 工具里
跑 pkg install、访问 ~/storage、用 Termux 完整的 Linux 工具链。

**但它不是「必须先连 Termux 才能干活」** —— 插件有两个执行面，默认 auto 自动选：

| 执行面 | 何时生效 | 命令在哪跑 | 能干什么 |
|---|---|---|---|
| termux | 有 agent 连接（或 backend 显式写 termux） | Termux 的来宾环境 | pkg install、~/storage、Termux 的 uid |
| local  | 没有 agent 连接（或 backend 显式写 local） | DSH 客人自己的 Debian 13 | bash / gcc / make / node / pnpm / python3 / git / ffmpeg / sqlite3，apt 走 dshbox 的 fakeroot wrapper |

所以「不想把 Termux 挂后台」时照样能执行命令、装包、编译；「想用 Termux 的环境」时
在 Termux 里跑一次启动脚本，auto 就会自动切过去。

- 包名: @local/dsh-termux-bridge
- 版本: 1.2.9
- 作者: **Azek431（艾泽衡）** — Telegram 频道 [@AzekMain](https://t.me/AzekMain) · Azek431@163.com
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

### 2.1 装法：vendor 目录 + link: 依赖（1.2.7 起）

1.2.6 及之前，install.sh 是**手工把包目录拷进 `node_modules/@local/`、但不在 `package.json`
里声明它**。这种"幽灵依赖"会被任何一次 `pnpm install` / `pnpm add` / `pnpm prune`
（包括在 GUI 里装别的插件）当垃圾静默剪掉 —— 目录没了、bundles 还记着它，下次重启 dsh
插件就凭空消失，而且报错只说 bundle 解析不到，看不出是 pnpm 干的。

1.2.7 改成**有声明**的布局：

    <profile>/local-plugins/@local/dsh-termux-bridge      ← 包体（vendor 目录，真实目录）
    <profile>/node_modules/@local/dsh-termux-bridge       ← 软链 → ../../local-plugins/@local/dsh-termux-bridge
    <profile>/package.json  dependencies:
      "@local/dsh-termux-bridge": "link:./local-plugins/@local/dsh-termux-bridge"

链接型依赖不被 pnpm 重建，所以 `pnpm install` / `pnpm add` / `--frozen-lockfile` 之后软链都原样存活。
相对路径让它不依赖共享存储是否挂载，也不依赖绝对路径。

install.sh 的事务顺序：

1. 预检：python3 在不在、必需文件齐不齐、profile 的 dsh.profile.bundles 是不是 list；
2. 复制到阶段目录 local-plugins/@local/.dsh-termux-bridge-stage.<pid>，在阶段目录上跑
   node --check（四个 JS）与 bash -n（agent 脚本）以及文件清单核对；
3. 旧包整体挪进备份位 → 新包改名上位 → 建 node_modules 软链 → 发布后复检清单；
4. 往 dsh.profile.bundles 追加 @local/dsh-termux-bridge（临时文件 + 原子改名）；
5. 在 dependencies 里声明 link: 依赖（记下原值，供失败时还原）；
6. 更新 pnpm-lock.yaml。**用 `pnpm install --lockfile-only --offline`：链接型依赖不访问
   registry，所以整个安装过程不需要网络**；
7. 写 .dsh-termux-bridge-install.json 所有权清单（含 `layout: "vendor-link"`）。

任一步失败都完整回滚：包体移回、软链按原样重建（旧版是软链就重建软链、是实体目录就移回备份）、
依赖声明还原、lockfile 覆盖回旧版；**首装失败还会把本次登记的 bundle 条目一并摘掉**，
profile 回到安装前的状态。判据是装之前有没有旧版（`HAD_PREV`），不是"备份位还在不在"。

**这条链路不是原子操作，重装/升级前先停 dsh。**

### 2.2 从 1.2.6 及更早版本升级

直接跑 `bash install.sh` 即可，无需先卸载。安装器会检测到 node_modules 里是**实体目录**
（旧装法），把它挪进 `nmbackup.<pid>` 备份位，再按新布局装；失败会自动移回去。

卸载也认得两种布局：`uninstall.sh` 会四处一起收 —— bundle 条目 → dependencies 里的 `link:`
声明 → node_modules 软链（或旧实体目录）→ vendor 包体，最后重算 lockfile，不留悬空声明。

### 2.3 自检脚本（可选）

`scripts/ensure-installed.sh` 仍然可用，但现在它主要是给**同机的其它插件**
（`dsh-mobile-adapt` / `mobile-pilot` / `browser-use`）做幽灵依赖自检 ——
本插件 1.2.7 起已有正式依赖声明，不再需要它兜底。

    bash scripts/ensure-installed.sh --check   # 只自检，缺失则退出码 1
    bash scripts/ensure-installed.sh           # 自检 + 重跑对应安装器补回来

### 2.4 ⚠️ 跑 pnpm install 会顺手删掉同机的旧装法插件

**这是实测踩到过的坑，不是理论风险。** 本插件 1.2.7 起有正式依赖声明，`pnpm install` 动不了它；
但同机的 `@local/dsh-mobile-adapt`、`@local/mobile-pilot`、`@local/browser-use` 仍是**旧装法**
（把包目录直接放进 `node_modules/@local/`，`package.json` 里只有 bundle 条目、没有 `dependencies` 声明）。
`pnpm` 一跑就把它们当幽灵依赖清掉：

    $ pnpm install --frozen-lockfile      # 在 profile 目录里
    $ ls node_modules/@local/
    dsh-termux-bridge                     # ← 另外三个没了
    $ dsh --profile web --dump-config
    dsh: skipping profile bundle "@local/dsh-mobile-adapt": cannot resolve ...

**症状的隐蔽之处**：正在运行的 dsh 进程早已把插件加载进内存，所以 `phone_*` 等工具当场还能用；
**只有下一次重启才会集体消失**，而且报错只说"解析不到 bundle"，看不出是 pnpm 干的。

恢复办法（各自重跑安装器）：

    bash /root/projects/.dsh/dshbox/dshbox-plugins/mobile-pilot/install.sh
    bash /root/projects/.dsh/dshbox/dshbox-plugins/mobile-adapt/install.sh
    bash /root/projects/.dsh/dshbox/dshbox-plugins/browser-use/install.sh /root/projects/.dsh/profiles/web

注意 `browser-use` 的安装器**必须带 profile 目录参数**（其它两个不用），少了会报
`Browser adapter: profile directory is unavailable`。

验收集：

    dsh --profile web --dump-config | grep -E '^# == @local/'

应当列出四个：`dsh-mobile-adapt` / `mobile-pilot` / `browser-use` / `dsh-termux-bridge`。

另外注意 `dsh` 不在客人 shell 的默认 PATH 里，要么用
`/root/projects/.dsh/dshbox/bin/dsh`，要么先把该目录加进 PATH —— 否则
`dsh ... | grep ...` 会静默返回空（`command not found` 被管道吞掉），很容易被误判成"插件没被加载"。
---

## 3. 工具

| 工具 | 作用 |
|---|---|
| termux_status | 监听状态、端口、已连 agent、累计任务数、最近错误、**下一个命令走哪个执行面**、客人工具链探测。排障第一步。 |
| termux_bootstrap | 生成 Termux 侧启动命令、URL 与脚本正文（inline:false 可只要命令）。不跑也能执行命令。 |
| termux_exec | 执行一段 bash 脚本正文。支持 cwd / backend / timeoutMs / maxBytes。 |
| termux_run | 以 argv 数组执行命令（不经过 shell 二次解析，最安全）。 |
| termux_push | 把内容写到目标路径（覆盖写，目录不存在自动建）。默认按 UTF-8 写文本，`encoding: base64` 可写任意二进制。 |
| termux_pull | 读目标文件（默认最多 8 MiB）。文本原样回 UTF-8，二进制按 base64 回并显式标记。 |

所有工具的输出都是结构化对象，字段固定：
ok / code / text / exitCode / elapsedMs / truncated / timedOut（+ 各自扩展字段，
exec / run / push / pull 另有 backend 表示实际执行面；pull 另有 encoding / binary / bytes）。
**机器判读读字段，不要解析 text。**

### 二进制文件（pull / push，1.2.8 起）

termux_pull 的 content 有两种编码，靠 encoding 字段区分：

| encoding | binary | content 是什么 | bytes |
|---|---|---|---|
| utf8 | false | 文件原文（UTF-8） | 真实字节数 |
| base64 | true | 原始字节的 base64 | 真实字节数（**不是** content 的长度） |

判定规则：**不含 NUL 字节、且是合法 UTF-8** 才算文本，否则一律按 base64 回传并置 binary=true。
截断正好切在多字节字符中间时，会从尾部最多回退 3 个字节找合法边界，不会把纯文本误判成二进制。

这条判定是 1.2.8 修的 bug：此前 DATA 帧走 decField()，它内部是
Buffer.from(field,"base64").toString("utf8")，非法字节被**静默替换成 U+FFFD**——
2048 字节的文件读出来只有 1945 个字符，长度对不上，ok 却依然是 true。
所以 bytes 与 encoding 是两个独立事实：**判断大小只看 bytes，解释 content 先看 encoding**。
二进制内容不要直接当文本读。

写回去用 termux_push 的 encoding: 'base64'，与 pull 的出口正好对齐，可以往返。

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
E_TIMEOUT（命令被 timeoutMs 强杀，timedOut=true）、E_BAD_CWD（工作目录不存在，命令没有执行）、
E_INVALID_ARGUMENT（backend 写错 / encoding 不支持）。

### cwd 不存在：E_BAD_CWD 与退出码 97 的歧义

cwd 指向不存在的目录时，命令**根本不会执行**，直接返回 `E_BAD_CWD`。
这个错误码是 1.2.8 新加的，此前只有 `EXIT_97`。

97 这个数字是**本插件自己选的**约定，不是 shell 的通用约定 —— 所以用户脚本
完全可能自己 `exit 97`，此时看退出码就分不清「路径写错了」和「命令真的返回了 97」。
1.2.8 的处理是把来源显式标出来：

| 情况 | code | 说明 |
|---|---|---|
| cwd 不存在（新 agent） | E_BAD_CWD | agent 在 RESULT 末字段带 `hint=cwd`，来源确定 |
| cwd 不存在（老 agent） | EXIT_97 | 老 agent 不发 hint 字段，只能退回看退出码 |
| 命令自己 `exit 97` | EXIT_97 | hint 为空；text 里会点明「97 也可能是命令自己返回的」 |

**所以拿到 EXIT_97 时不要一口咬定是路径问题**，先看 text 末尾那句话，或确认 cwd 真的存在。
新老 agent 混装是正常状态（agent 是用户手动起的），两种来源都得容忍。

### 超时语义（容易踩）

两个执行面用同一套语义，但机制不同：

- agent 侧（1.2.9 起）：`timeout --preserve-status` **直接**跑用户脚本。`--preserve-status`
  会原样报出被跑命令的退出码，于是「脚本自己 exit 124」与「被 timeout 杀掉」本来就能从 `$?` 分开
  （实测：自己 exit 124 → 124；被 timeout 杀 → 128+信号 = 143/137）。剩下唯一的歧义是脚本自己
  `kill -TERM` 自己也是 143，所以再加一道判据：**`code > 128` 且实际用时已经跑到时限附近**
  才归一成 exitCode=124 / timedOut=true，保证上层语义稳定。
  没有 `--preserve-status` 的 `timeout`（BSD / macOS）自动降级到旧路径，只是超时码要额外归一。
- local 侧：Node 侧计时器到点直接 SIGKILL 整个进程组（detached 起，防孙进程漏网），
  然后统一归到 exitCode=124 / timedOut=true。

只看 $? 会把「命令自己 exit 124」和「被超时杀掉」混成一件事，这是本插件刻意绕开的坑。
1.2.9 之前 agent 侧是靠一个 runner.sh 把 `$?` 写进文件来区分的（三层 fork）；现在这层已经去掉，
判据改由 `--preserve-status` 提供。

---

## 4. 协议（自定义行帧，纯 bash 可实现）

一行一帧，空格分列；**所有可能含空格的字段一律 base64，空值写 -**。
`EXECRAW` / `PUTRAW` 是唯一的例外：帧头行之后紧跟裸字节，不是纯行帧（见本节末尾）。

    HELLO  <ver> <token_b64> <name_b64> <caps>
    WELCOME <ver> <host_b64>              |  DENY <code> <text_b64>
    EXEC   <id> <timeout_ms> <cwd_b64|-> <script_b64> <max_bytes>
    EXECRAW <id> <timeout_ms> <cwd_b64|-> <nbytes> <max_bytes>
    PUT    <id> <w|a> <path_b64> <data_b64>
    PUTRAW <id> <w|a> <path_b64> <nbytes>
    GET    <id> <path_b64> <max_bytes>
    RESULT <id> <exit> <elapsed_ms> <trunc 0|1> <stdout_b64|-> <stderr_b64|-> <timed_out 0|1> <hint|->
    DATA   <id> <exit> <data_b64|-> <stderr_b64|-> <trunc 0|1>
    PING   <id>  ->  PONG <id>

约束：PROTO_VERSION=1、MAX_LINE_BYTES=16 MiB、MAX_SCRIPT_BYTES=256 KiB、RAW_CHUNK_BYTES=4 MiB。

RESULT 的第 8 字段 `hint` 是 1.2.8 新加的**裸 ASCII 语义标记**（不是 base64，普通路径写 `-`，
cwd 不存在写 `cwd`）。它解决的是「97 是谁给的」这个问题，详见第 3 节的「cwd 不存在」小节。老 agent 不发这个字段，
解析时按空串处理即可 —— 这也是为什么上层必须容忍缺失。

MAX_LINE_BYTES 必须是**载荷上限的 1.33 倍以上**：base64 会膨胀 4/3。这曾经是个真 bug ——
帧上限和输出上限都设成 1 MiB，于是 maxBytes=1 MiB 时数据帧变成约 1.4 MiB > 1 MiB，
接收端直接 destroy，调用方看到的是莫名其妙的 E_AGENT_GONE。协议层上限必须显式大于载荷上限。

**裸字节帧（`PUTRAW` 1.2.8 / `EXECRAW` 1.2.9）** 与上面的行帧不是一个形状：帧头行以 `\n` 收尾，
后面**紧跟 nbytes 个原始字节，没有任何分隔符**。agent 读完帧头那一行就直接 `head -c <nbytes> <&3`
（`EXECRAW` 用 bash 内建 `read -N`，省掉两次 fork）落盘，不经过 base64。

为什么值得为它多一套帧：**bash 的 `read -u 3` 从 socket 读「一行」是逐字节 `read(2)`** ——
1 MiB 的 PUT 行要 7206ms，同样大小的裸字节 `head -c` 只要 34ms。脚本正文走 base64 时同理，
除了逐字节读还要多 fork 两个 `base64 -d`。这不是编码慢，是「按行读」这件事本身慢。

这条通路**必须独占连接**：裸字节流里只要混进一个 `PING` 行，垃圾就会被原样写进文件。
所以它依赖两个硬前提 —— 桥接侧严格串行派活，以及心跳跳过忙 agent。

能力协商：agent 在 `HELLO` 第 4 字段声明 `raw`（`PUTRAW`）与 `rawx`（`EXECRAW`）。
老 agent 不声明，桥接侧自动回退到 `PUT` / `EXEC` 的 base64 帧 —— **功能完全等价，只是慢**，
不会因为版本不同而报错。`RAW_CHUNK_BYTES = 4 MiB`，不受 `MAX_LINE_BYTES` 约束：
裸字节不是一行，不吃「一行一次 read」的惩罚，1 MiB 与 4 MiB 的文件都各只要一帧。

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
- **去掉 runner 层，换 `--preserve-status`**（1.2.9）：原来的链路是
  `timeout → bash runner.sh → bash 用户脚本`，三层 fork，中间那层只干一件事 —— 把 `$?` 写进文件，
  好让「自己 exit 124」和「被超时杀」分得开。`timeout --preserve-status` 会原样报出被跑命令的退出码，
  这件事它自己就做了。代价是 `--preserve-status` 是 GNU 扩展，**BSD / macOS 的 timeout 没有** ——
  所以探测一次，失败就退回旧的三层路径。宁可慢几毫秒，也不要在别家 timeout 上直接报错退出。
  这笔账值得算：PRoot 下每次 fork 8~10ms，砍掉一层就是每条命令省下的固定开销的大头。
- **`3>&-`：把协议套接字关在用户脚本之外**（1.2.9）。dsbox 里 agent 的 fd 3 就是协议流，
  用户脚本一句 `echo x >&3` 就能往协议里插半行垃圾，把下一帧的帧头拆散，
  整条连接从此错位且**不自愈**。这个故障最坏的地方是它不报错 —— 表现为后面某条命令莫名超时。
  关掉之后用户再写 3 号只会拿到 `Bad file descriptor`，错误留在用户自己的脚本里。
- **不在字符串上做全串手术**（1.2.9）。截断判定原本要对 1.4 MB 的 base64 串取 `${ob%%=*}`，
  那是 O(n²)，实测 75 秒不返回。改成先看 `${#ob}` 够不够到截断边界（bash 内建，不 fork），
  够到才 `wc -c` 问一次真实大小。**小输出（99% 的情况）连分支都不进**，
  大输出也只多一次 fork —— 复杂度从「输出长度的平方」退回「常数」。
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
| 工具一条都不出现 | dsh 没重启；或 node_modules/@local/dsh-termux-bridge 不在；启动日志里找 dsh-termux-bridge: 前缀 |
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

    node --test test/bridge.test.cjs     # 31 条：协议 / 执行 / push-pull / 二进制编码 / 裸字节帧 / fd 3 隔离 / 超时语义 / 大输出 / agent 生命周期 / HTTP 面
    node test/smoke.cjs                  # 冒烟：真加载 profile 里的包，两个执行面各跑一遍

套件约 14 秒跑完并**干净退出**（1.2.6 修掉了此前"20 条全过但进程永不退出"的管道泄漏，见下）。

bridge.test.cjs 覆盖：握手执行、非零退出码透传、多行/heredoc、cwd、cwd 不存在（exit 97）、
argv 空格与 $(echo pwn) 不被二次展开、输出截断、超时强杀、命令自己 exit 124 不算超时、
掉线报错、多片 push/pull 往返、远端建目录、pull 缺失文件、无 agent、错令牌、HTTP 路由、
**大输出（1 MiB）不被帧上限撕掉连接**、**pull 大文件不被帧上限撕掉连接**（后两条是 1.1.1 的回归）、
**令牌错时 agent 自己退出而不是无限重连**、**同名 agent 只保留一条且 3 秒内不乒乓**（后两条 1.2.1）、
**用户脚本写 fd 3 不污染协议流**、**用户脚本读 fd 3 吃不到下一帧**（后两条是 1.2.9 的回归：
`3>&-` 必须真的把套接字关在子进程之外，而不是静默丢弃 —— 两条用例都同时断言
「拿到 Bad file descriptor」和「桥上还能正常跑下一条命令」，缺任何一半都测不出真问题）。

两条与"环境隔离"有关的约定，改测试时别弄丢：

- **端口与令牌必须随机**。原来固定 18791 + 固定 `smoketoken`，上一轮跑崩残留的孤儿
  agent 带着同一个令牌会自动接进下一轮，把"起手 0 个 agent"断言打成假的。
- **spawn 出来的 agent 必须带 `DSH_BRIDGE_MAX_FAIL=1`**，让它连不上就自杀，
  否则测试进程被 kill 之后它还在后台重连，几小时后还能污染别的用例。
- **收尾必须按进程组杀，不能只 kill 单个 pid**。`spawn` 时带 `detached: true`，
  `t.after` 里调 `killTree(child)`——它发 `process.kill(-child.pid, 'SIGKILL')`
  （负号 = 整个进程组，连同 agent 自己 fork 出的 `timeout` 等子进程），并 `await`
  它的 `exit`，最后 `destroy()` 掉 stdout/stderr 管道。1.2.5 之前只 `child.kill('SIGKILL')`，
  agent 变成 PPID=1 的孤儿并**继续握着这两个管道的写端**，Node 事件循环永远不空：
  表现为 `tests 21 / pass 20 / cancelled 1`、duration 卡满 timeout 才被杀（EXIT=124），
  而文件里其实只有 20 个 `test()`，"第 21 个"是整个进程没退出。

smoke.cjs 覆盖：无 agent 时 auto 落 local、local 执行/退出码/超时/cwd 缺失/push-pull、
强制 termux 无 agent 报 E_NO_AGENT、非法 backend 报 E_INVALID_ARGUMENT、
起 agent 后 auto 切 termux、termux 侧执行与 push-pull、有 agent 时强制 local 仍生效。

---

## 9. 发布到 GitHub

**为什么这一步必须在 Termux 里做，不能在 DSH 里做**

DSH 跑在 proot 客人里，它的 `$HOME` 是客人的 `/root`，与 Termux 的
`/data/data/com.termux/files/home` 是两个互不相通的根文件系统（详见第 1 节）。
`gh auth login` 把凭据写在 `~/.config/gh/hosts.yml`，所以：

- 在 **Termux** 里登录 → 凭据在 Termux 侧，客人里的 `gh auth status` 依然显示未登录；
- 在 **DSH** 里登录 → 凭据在客人里，重启或换设备就没了，把 token 写进容器也不卫生。

所以仓库源码放在 Android 共享存储
（`/storage/emulated/0/编程/DeepSeek-Hermes/插件/dsh-termux-bridge`），
**两边看到的是同一个目录**，在 Termux 里直接推即可，不需要拷贝。

**当前状态：已发布 → <https://github.com/Azek431/dsh-termux-bridge>**

本仓库的首次发布实际走的是下面的「零交互 token 路径」：在 DSH 客人里用 GitHub
Device Flow 拿到 token（`POST /login/device/code` → 用户在任意浏览器点 Authorize →
轮询 `POST /login/oauth/access_token`），再交给 `scripts/push-with-token.sh` 建仓推送。
全程没有依赖 Termux 侧的 `gh` 登录态 —— 因为客人根本读不到 Termux 的 `~/.config/gh`
（两个 `$HOME` 不相通）。

**一条命令**

```bash
# 在 Termux 里
pkg install git gh          # 只需一次
gh auth login               # 只需一次：GitHub.com → HTTPS → 浏览器授权
gh auth setup-git           # 只需一次：否则 git push 报 could not read Username
cd /storage/emulated/0/编程/DeepSeek-Hermes/插件/dsh-termux-bridge
bash scripts/push-to-github.sh
```

> **`gh auth login` 那一步卡住不动？** 别反复重试，先跳到本节后面的
> 「如果清了代理还是卡住」——那条路用 `scripts/push-with-token.sh`，
> 只要一个 token，零交互、不需要 gh。

`scripts/push-to-github.sh` 会做：

1. 检查 `git` / `gh` 是否安装、`gh` 是否已登录（未登录直接给出下一步命令）；
2. 跑一次 `gh auth setup-git` 把 gh 装成 git 的 credential helper —— **`gh auth login` 并不会做这件事**，
   少了它 `git push` 会死在 `could not read Username for 'https://github.com'`；
3. 把仓库目录加进 `git safe.directory` —— 共享存储是 fuse，属主（10246）和 Termux uid 不一致，
   不加这一条 git 会报 `detected dubious ownership` 并拒绝工作；
4. owner 不传时用 `gh api user --jq .login` 推断，仓库名取目录名；
5. 仓库不存在就 `gh repo create --source=. --remote=origin`（**建仓与推送分开**，
   推送失败时才能准确提示是凭据问题而不是建仓问题），已存在则跳过；
6. `git push -u origin main`，失败时直接打印 `gh auth setup-git` / `gh auth refresh -s repo` 两条修法；
7. 补 description、homepage 与 topics（`dsh-plugin` / `dsh` / `deepseek-harness` /
   `termux` / `android` / `proot` / `bridge` / `remote-exec`）——
   官方可发现性靠 GitHub topic `dsh-plugin` 加 `package.json` 的 keywords。

参数：

```bash
bash scripts/push-to-github.sh                       # 全自动
bash scripts/push-to-github.sh Azek431               # 指定 owner
bash scripts/push-to-github.sh Azek431 dsh-termux-bridge --private
```

**`gh auth login` 卡住不动？先查死代理**

设备上常见"apt 里配了 `127.0.0.1:2080`、但代理程序没起来"。这种**死代理**会让 `gh` / `git` 在联网那一步
**无声挂住**——不报错，只是不动，最难查。典型现场：`gh auth login` 选完
"+Authenticate Git with your GitHub credentials? Yes" 之后就再也不动了（它正卡在拉 device code 那一步）。

`push-to-github.sh` 现在会先探一遍代理端口，探到死端口直接停下并打印修法。手动排查：

```bash
# 1) 看有没有代理变量
env | grep -i proxy
# 2) 探端口活没活（2080/7890/10809 是你可能用的那几个）
for p in 2080 7890 7891 10809; do timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/$p" 2>/dev/null && echo "$p OPEN" || echo "$p closed"; done
# 3) 直连 GitHub 本身通不通
curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 https://github.com
```

若第 3 步返回 `200` 而 `gh` 卡住，就是代理的锅。修法：

```bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
git config --global --unset http.proxy     # 若有
export GIT_TERMINAL_PROMPT=1               # 让 git 需要凭据时直接问，而不是干等
gh auth login
```

注：`gh auth setup-git` 之后 git 用 gh 的凭据，`GIT_TERMINAL_PROMPT` 主要影响没用 helper 时的兜底行为。

**如果清了代理还是卡住 —— 那就不是网络问题，是交互问题**

实测（同一台设备，2026-10-26）：直连 GitHub **完全正常** —— 
`POST https://github.com/login/device/code` 返回 HTTP/2 200、`user_code` 正常生成、
`expires_in 899 / interval 5`；`curl https://github.com` 也是 200。
但 `gh auth login` 照样会停在交互层：它把 device code 打出来之后，要求你在**同一个 TTY**里
按回车、切到前台开浏览器、再切回来接着读；Termux 里这条路径很容易莫名僵住
（尤其配合物理键盘/剪贴板/前台切换时）。

**所以判断口诀是**：代理变量清空、端口全 closed、`curl https://github.com` 返回 200，
但 `gh auth login` 依然不动 ⇒ 别再挖网络了，直接换掉交互 —— 用下面的 token 路径。

**零交互路径：`scripts/push-with-token.sh`**

只依赖 `curl` + `git`，**连 `gh` 都不需要**，不读 TTY、不问任何问题：

```
# 1) 建 token：https://github.com/settings/tokens
#    Fine-grained → All repositories → Contents: Read and write + Administration: Read and write
#    或经典 token → 勾 repo
# 2) 推（推荐从 stdin 喂，token 不进 shell history）
cd /storage/emulated/0/编程/DeepSeek-Hermes/插件/dsh-termux-bridge
echo "<你的token>" | bash scripts/push-with-token.sh

# 也可以：GH_TOKEN=xxx bash scripts/push-with-token.sh [owner] [name] [--private]
```

它做的事：

1. `GET /user` 校验 token 并认出 login（不传 owner 时就用它）；
2. `GET /repos/{o}/{r}` 探仓库是否已存在，不存在才 `POST /user/repos` 创建（description / homepage 一次写好）；
3. `git push` 时用**一次性 credential helper** 从环境传 token —— **不写进 `.git/config`、
   也不把 token 拼进 remote URL**，所以 `git remote -v`、`ps`、`.git/config` 里都看不到它；
4. `PUT /repos/{o}/{r}/topics` 逐个补 8 个 topic。

> 附带一条给自动化脚本的坑：device flow 的正确端点是 
> `POST https://github.com/login/device/code`，写成 `/login/oauth/device/code` 会返回 **422**。
> 拿到 `user_code` 后轮询 `POST https://github.com/login/oauth/access_token`
> （`grant_type=urn:ietf:params:oauth:grant-type:device_code`），
> `authorization_pending` 是正常中间态，`slow_down` 就把间隔 +5 秒。

**共享存储上 git 的两个坑**

| 现象 | 原因 | 处理 |
|---|---|---|
| `fatal: detected dubious ownership in repository` | fuse 上目录属主 10246，Termux uid 不同 | `git config --global --add safe.directory '*'`（脚本已代做） |
| `chmod +x` 后 git 里仍是 100644 | fuse 不支持 chmod，权限位不进 index | `git update-index --chmod=+x <file>`，本仓库已对 5 个脚本如此处理 |

> DSH 侧也装了 `gh`（`/usr/local/bin/gh` 2.46.0，从 Debian deb 里抽出的静态二进制，
> 因为客人里 `dpkg` 需要 root 而装不上），它只用于**只读查询**（`gh repo view`、`gh api`），
> 不用于推送 —— 客人里没有、也不该持有凭据。

---

## 10. 作者

**Azek431（艾泽衡）**

- Telegram 频道：[@AzekMain](https://t.me/AzekMain)
- 邮箱：Azek431@163.com

本项目由作者在 Android（DSHBox / PRoot 客人）环境下实测开发，
所有 "能不能用" 的结论都有对应实测记录，见配套文档库：

| 文档 | 内容 |
|---|---|
| 04-研究报告/termux-bridge-全面实测报告.md | 环境、工具链、两执行面 31 项实测数据 + 20 条自动化用例 |
| 03-技术笔记/DSH插件命名规范.md | 仓库名=包名=dsh-<能力>；改名 6 步清单；「不该跟着改」清单 |
| 03-技术笔记/termux-bridge-机制与踩坑.md 第 10 节 | agent 生命周期三坑：DENY 分类、退避上限、同名去重为什么要发 BYE |
| 04-研究报告/termux-bridge-经验总汇总.md | 否证优先的方法论、架构决策理由、6 个坑、排障手册 |
| 03-技术笔记/termux-bridge-机制与踩坑.md | 反向连接为何必须、协议选型、各坑的排错特征 |

欢迎在 Telegram 频道反馈问题。

## 11. 许可证

GPL-3.0-only，见 [LICENSE](LICENSE) 与 [plugin/NOTICE](plugin/NOTICE)。

本仓库为原创实现，不含第三方源码。运行时只依赖 Node.js 内置模块
（`net` / `crypto` / `child_process` / `fs` / `os` / `path` / `events`），
Termux 侧 agent 只依赖 bash 内建 + `base64` / `date` / `mktemp`。