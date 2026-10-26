# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.2.9] —— 2026-10-27

把 `exec` 的**固定开销从约 98ms 压到约 14ms（7 倍）**，顺手堵掉一个协议污染风险，
并删掉一处会退化成 O(n²) 的字符串处理。这一版没有新功能 —— 全是「同样一件事，做得更干净」。

### 性能

- **去掉一层 fork**。原来的链路是 `timeout → bash runner.sh → bash 用户脚本`，三层。
  中间那层 runner 只干一件事：把「命令自己的退出码」写进文件，好让「脚本自己 exit 124」
  和「被 timeout 杀掉」分得开。改用 GNU `timeout --preserve-status` **直接跑用户脚本**，
  这件事它自己就做了。PRoot 下每次 fork 8~10ms，所以这是最大的一笔。
- **`--preserve-status` 的取舍与降级**。它让 timeout 原样报出被跑命令的退出码，
  于是两种 124 天然可分（实测：脚本自己 `exit 124` → 124；被 timeout 杀 → 143/137），
  不再需要 runner 把 `$?` 写进文件。代价是它是 GNU coreutils 的扩展，
  **BSD / macOS 的 timeout 没有** —— 启动时探测一次，失败就自动降级到旧路径，
  只是超时码需要额外归一。宁可慢几毫秒，也不要在别家 timeout 上直接报错退出。
- **超时归一**：`--preserve-status` 之后还剩一个歧义 —— 脚本自己 `kill -TERM` 自己也是 143，
  与被 timeout 杀同码。加一道判据：`code > 128` **且实际用时已经跑到 `secs*1000 - 150` 以上**
  才归一成 exitCode 124 + timedOut=1。被 timeout 杀的一定跑满时限附近，自己发信号的通常远早于此。
- **收尾编码按需 fork**。原来无论输出空不空都要跑 `wc -c`、`base64`、`head+base64` 四个外部命令
  （约 36ms）。现在用 bash 内建 `[ -s ]` 先判空：**空输出 0 次 fork**，有 stdout 无 stderr 时降到 19ms。
  PRoot 下绝大多数命令的 stderr 都是空的，这笔钱以前是白花的。
- **超长字符串的 O(n²) 去掉**。`${ob%%=*}` 对 1.4MB 的 base64 串是 O(n²)，
  **实测 75 秒不返回** —— 表现出来像是命令超时，其实是桥接自己在算。
  改成「先用 `${#ob}` 判断有没有够到截断边界，够到才 fork 一次 `wc -c` 问真实大小」——
  小输出（99% 的情况）连分支都不进，大输出也只多一次 fork。**复杂度从输出长度的平方退回常数。**
- **回包写次数决定 40ms —— Nagle 与延迟 ACK**。把 `do_exec` 的收尾从「捕获进变量再一次
  `printf`」改成「三段 `write` 流式发送」之后，1MiB 大输出的耗时确实从 79ms 降到 33ms，
  但**小命令反而从 15ms 涨到 64ms** —— 一个本该是纯收益的优化，把最常走的那条路拖到了 4 倍多。
  写了个假 agent 做决定性实验：回复内容**逐字节相同**，只改「拆成几次 write」。
  结果是 1 次 write = 0ms；2 次 = 40ms；3 次 = 40ms；3 次且 agent 侧 `setNoDelay(true)` = 0ms。
  **只要回包拆成 2 次以上 write，就固定多出 40ms**，正是 Linux 延迟 ACK 的 40ms 定时器。
  桥接侧已有的 `setNoDelay` 救不了这件事：Node 侧 socket 早就 `setNoDelay(true)`（bridge.js:206），
  但那管不到对端；bash 的 `/dev/tcp` 没有 `setsockopt`，**`TCP_NODELAY` 在 agent 侧根本设不了**。
  解法是 agent 侧按阈值分两路：小回包（默认 ≤64KiB）把 base64 装进变量、**一次 write 发完整行**；
  大回包仍走流式 —— 那时 40ms 被摊薄，而流式省下的 30~50ms 更值。阈值是文件头部常量 `SMALL_OUT`，
  可用环境变量 `DSH_BRIDGE_SMALL_OUT` 覆盖（基准脚本正是靠它做 A/B）。
  判据这里还有个坑：一开始用「文件多大」判断走哪条路，结果**截断场景白走三段写**
  （实际只发 64KiB，文件却是 4MiB），实测多付 36ms；改成按「实际要发多少字节」判断
  （`emit=$size`，截断时 `emit=$max`）后降到 37ms。最终小命令 13~27ms 回到全捕获水平，
  大输出保住流式优势，**两条路都不比另一种纯方案差**。

### 安全

- **`3>&-`：把协议套接字关在用户脚本之外**。dsbox 里 agent 的 fd 3 就是协议流，
  用户脚本一句 `echo x >&3` 就能把半行垃圾插进协议流，把下一帧帧头拆散 ——
  **整条连接从此错位，而且不自愈**。这个故障最坏的地方是它不报错：表现为后面某条命令莫名超时，
  排查时很难联想到是上一个脚本写了一句日志。现在跑用户脚本时一律 `3>&-`，
  用户再写 3 号只会拿到 `Bad file descriptor`，错误留在自己的脚本里，伤不到桥。

### 其他

- **`isValidUtf8` 改用 Node 内建 `require('buffer').isUtf8`**（保留老 Node 的往返编码回退）。
  实测 1 MiB ASCII：往返编解码法 1.25ms → 0.012ms（约 100 倍）；1 MiB 中文 1.92ms → 0.092ms。
  这是纯收益 —— 判定结果不变，只是不再用「编一遍再比一遍」这种笨办法。
- **`EXECRAW` 裸字节脚本通路**：与 1.2.8 的 `PUTRAW` 同构，帧头行之后紧跟 nbytes 个裸字节，
  agent 用 bash 内建 `read -N` 收（两次 fork 的 `head -c` + `wc -c` 在 PRoot 下要 10~13ms）。
  必须带 `LC_ALL=C` 才按字节而不是字符计数，正文不能含 NUL。

### 已验证

- 测试 **29 → 31 条**，新增两条 **fd 3 隔离**的回归：**用户脚本写 fd 3 不污染协议流**、
  **用户脚本读 fd 3 吃不到下一帧**。两条都同时断言「拿到 `Bad file descriptor`」和
  「桥上还能正常跑下一条命令」—— 只断言前者会漏掉「静默丢弃也算过关」这种假修复，
  只断言后者则测不出套接字到底有没有关。

实测（v1.2.8 → v1.2.9，**严格串行 A/B，3 轮交叉取中位**）：

| 用例 | v1.2.8 | v1.2.9 | 倍数 |
|---|---|---|---|
| `true` | 98 ms | **14 ms** | 7.0× |
| `echo hello` | 102 ms | **23 ms** | 4.4× |
| 多行 printf | 100 ms | **23 ms** | 4.3× |
| `seq 1 300000`（1MiB 输出） | 175 ms | **128 ms** | 1.4× |
| 1MiB 输出（maxBytes=64KiB 截断） | 76 ms | **37 ms** | 2.1× |

表格最后一行是**截断场景**：输出 1MiB、上限 64KiB，真正上网的只有 64KiB，
所以它同时吃到了「一次 write」和「不必把几 MB 装进变量」两份好处。

固定开销被压掉之后，**空命令的耗时已经接近一次 fork 的成本**，再往下压就该换执行模型了，
不是继续抠这一层。输出越大收益越小 —— 那部分时间本来就花在真实的 IO 与编码上。

## [1.2.8] —— 2026-10-26

修掉一个**静默数据损坏**的真 bug，把大文件传输提速两个数量级，并让「cwd 不存在」这件事
从一串魔法数字变成可判读的语义。

### 修复

- **`termux_pull` 读二进制文件会静默损坏，且 `ok` 仍是 `true`**。这是本次最重要的修复。
  根因在 `plugin/lib/bridge.js` 的 `#settle`：DATA 帧走的是 `decField()`，
  而它内部是 `Buffer.from(field, 'base64').toString('utf8')` —— 拿回字节后**又顺手做了一次
  UTF-8 解码**，非法字节被静默替换成 `U+FFFD`。现象：2048 字节的文件读出来只有 1945 个字符，
  长度对不上，但调用方看到的是 `ok: true`，不报任何错。这类损坏最坏的地方在于**它不失败**。
  修法是拆成两步：新增 `decFieldBuffer()` 只负责把 base64 解回原始 `Buffer`，
  再由新增的 `protocol.decodePayload()` 判定编码 —— **不含 NUL 字节、且 UTF-8 往返编码完全一致**
  才算文本，否则按 base64 返回并置 `binary: true`。`decField()` 保留但不再用于数据载荷。
- **截断落在多字节字符中间会把纯文本误判成二进制**。`maxBytes` 截断可能正好切在一个汉字或
  emoji 的中间，尾部留下 1~3 个不完整字节，整段就被判成非法 UTF-8。新增
  `trimIncompleteUtf8()`，从尾部最多回退 3 个字节找合法边界再判定，避免这种误报。
- **`local` 执行面有同样的毛病**。`plugin/lib/local.js` 原先也是直接 `toString('utf8')` 读文件，
  现在同样走 `decodePayload()`，两个执行面的编码语义终于一致。

### 新增

- **`termux_pull` 输出新增 `encoding`（`utf8` | `base64`）与 `binary`（boolean）两个字段**，
  `bytes` 改为**真实字节数**（与编码无关，不再是 content 的字符长度）。
  判定规则收窄成一句话：**不含 NUL 且是合法 UTF-8 才算文本**。这样调用方不再需要猜，
  「判断大小只看 `bytes`，解释 `content` 先看 `encoding`」。
- **`termux_push` 新增 `encoding` 参数**（`utf8` 默认 / `base64`）。二进制不再是单行道：
  pull 出来的 base64 可以原样 push 回去，与出口正好对齐，能往返。传了非法的 base64
  会明确报 `E_INVALID_ARGUMENT`，而不是写入一堆空字节。
- **`cwd` 不存在返回语义化错误码 `E_BAD_CWD`**（原来只有 `EXIT_97`）。agent 侧在
  `handle_exec` 里**先预探测** `cwd`，不存在就直接返回，命令根本不会执行
  （`wrap.sh` 的 `|| exit 97` 只作竞态兜底）。
- **RESULT 帧新增第 8 字段 `hint`**（裸 ASCII 语义标记，**不是 base64**）：普通路径写 `-`，
  cwd 不存在写 `cwd`。这里有个坑值得记下来 —— 这一列**不能**用 `decField()` 解，
  因为字符串 `cwd` 恰好是合法 base64，会被解成 `"s\x07"`。上层由此能区分
  「我们拦住的 97」和「命令自己 exit 97」，后者会在 `text` 末尾附一句
  「97 也可能是命令自己返回的」。
- **老 agent 自动兼容**：不发第 8 字段时按空串处理，退回 `EXIT_97`。
  agent 是用户手动起的，新老混装是常态，这一点必须容忍。
- **`termux_status` / `lastJob` 增加 `bytes` 与 `binary`**，排障时能看出最近一次 pull
  拿回多少字节、是不是二进制。

### 性能

- **新增 `PUTRAW` 裸字节上行通路**，1 MiB 上传从**秒级降到毫秒级**。
  瓶颈一开始被误判成 base64 编码慢，其实不是 —— 编解码本身只要几十毫秒。真正的原因是
  **bash 的 `read -u 3` 从 socket 读「一行」是逐字节 `read(2)`**：
  1 MiB 的 PUT 行要 **7206ms**，而同样大小的裸字节用 `head -c` 只要 **34ms**。
  所以 `PUTRAW` 改成「帧头行 + 紧随其后的裸字节」：

      PUTRAW <id> <w|a> <path_b64> <nbytes>\n
      <nbytes 个原始字节，不含任何分隔>

  agent 读完帧头那一行后，直接 `head -c <nbytes> <&3` 落盘。这条通路**必须在 agent 空闲时独占** ——
  裸字节流里混进一个 PING 行就等于往文件内容里插垃圾，所以桥接侧的串行派活与心跳跳过忙 agent
  这两条约束都成了硬性前提。
- **`RAW_CHUNK_BYTES = 4 MiB`**，不受 `MAX_LINE_BYTES` 约束（裸字节不是一行，不吃「一行一次 read」
  的惩罚），于是 1 MiB 文件 = 1 帧、4 MiB 文件 = 1 帧，来回次数压到最少。
- **能力协商，老 agent 自动回退**：agent 在 HELLO 第 4 字段声明 `raw`，桥接侧据此走 `#pushRaw`；
  没有声明就走老的 base64 分片。**功能完全等价，只是慢**，不会因为版本不同而报错。
- **`MAX_LINE_BYTES` 从 1 MiB 提到 16 MiB**。这是个真踩过的坑：协议层上限必须**显式大于**
  载荷上限（base64 膨胀 4/3），而旧值恰好等于输出上限 —— `maxBytes=1 MiB` 时数据帧约 1.4 MiB，
  超过 1 MiB 上限被接收端直接 `destroy`，调用方看到的是**莫名其妙的 `E_AGENT_GONE`**。

实测（同一台设备，loopback，中位数）：

| 场景 | 1.2.7 | 1.2.8 | 倍数 |
|---|---|---|---|
| push 1 MiB | 9363 ms | **68 ms** | 约 138× |
| push 4 MiB | 28361 ms | **66 ms** | 约 430× |

pull 方向不受这次改动影响：1 MiB 约 119 ms、4 MiB 约 473 ms。两个方向的字节**完全一致**
（`allIdentical: true`），提速没有以正确性为代价。

### 已验证

- `node --test test/bridge.test.cjs` → **tests 29 / pass 29 / fail 0 / cancelled 0**，
  duration 14.6s，进程自然退出（EXIT=0）。用例从 20 条增加到 **29 条**，新增的 9 条全是围绕
  这次改动的回归：pull 二进制不损坏、带 NUL 时降级 base64、截断落多字节字符中间不误判、
  cwd 不存在带 `hint=cwd`、普通失败不带 hint、local 面读二进制、push 二进制与 pull 往返、
  `decodePayload` 与 push 的 base64 通路自洽、`decodePayload` 的单位边界。
- 二进制往返由用例坐实：pull 4096 字节、push 5000 字节两组都以 `Buffer.equals` 逐字节比对，
  `bytes` 与原始长度精确相等（修复前同一份数据会少掉若干字符却不报错）。
- cwd 语义由两条用例分别坐实：cwd 不存在时 `hint=cwd`（上层映射成 `E_BAD_CWD`）；
  命令自己失败时 hint 为空 —— 保证用户脚本自己的 `exit 97` 不会被误标成路径问题。
- 老 agent 的 base64 回退路径**只做了代码核对，未单独立用例**：`push()` 里按
  `agent.has(CAP_RAW_PUT)` 分流，未声明 `raw` 时走原有的分片实现，该分支在 1.2.7 已被
  「多片 push / pull 往返」用例覆盖。

## [1.2.7] —— 2026-10-26

把 `@local/dsh-termux-bridge` 从「幽灵目录」变成**有声明的依赖**。

1.2.6 及之前，`install.sh` 是手工把包目录拷进 `node_modules/@local/`，**从不在 profile 的
`package.json` 里声明它**。后果是：任何一次 `pnpm install`（升级别的包、清缓存、CI 重建）
都会把这个目录当垃圾静默剪掉，插件凭空消失，而且事后极难看出原因 —— 报错只说 bundle 解析不到，
没人会想到是 pnpm 干的。

### 新增

- **改用 vendor 目录 + `link:` 依赖**：包体放在 profile 的
  `local-plugins/@local/dsh-termux-bridge`，`node_modules/@local/dsh-termux-bridge` 只是指向它的软链，
  `package.json` 里正式声明 `"@local/dsh-termux-bridge": "link:./local-plugins/@local/dsh-termux-bridge"`。
  实测 `pnpm install`、`pnpm add <新包>`、`pnpm install --frozen-lockfile` 之后软链都原样存活。
- **全程离线**：更新 `pnpm-lock.yaml` 用 `pnpm install --lockfile-only --offline`。链接型依赖不访问
  registry，所以安装不需要网络。
- **`uninstall.sh` 四处一起收**：bundle 条目 → `dependencies` 里的 `link:` 声明 → `node_modules` 软链 →
  vendor 包体，再重算 lockfile，不留指向不存在路径的悬空声明。
- **兼容 1.2.6 旧装法**：检测到 `node_modules` 里是实体目录时，把它挪进备份位再升级；
  卸载时也认得这种旧布局。

### 修复

- **回滚把「升级」误判成「首装」**。`cleanup()` 原本用 `[ ! -e "$BACKUP" ]` 判断本次是否首装，
  但这段代码前面几行刚把 `BACKUP` 移回 `VENDOR`，所以条件**永远为真** —— 升级失败时会走首装分支，
  把 bundle 条目摘掉、软链删掉，可包体已经还原、依赖声明也没撤，留下一个「文件都在但插件加载不到」的
  矛盾状态。改为用 `HAD_PREV` 显式记下「装之前有没有旧版」。
- **旧版是软链时回滚不补链**：原逻辑只 `rm -f "$LINK"`，失败后 node_modules 入口就永久消失了。
  新增 `LINK_KIND`（`sym` / `dir`），回滚时按原样还原 —— 软链就重建软链，实体目录就移回备份。

### 已验证（各失败分支全部实测）

- 全新安装 → `pnpm install` / `pnpm add`：软链存活、`require.resolve` 通过。
- 幂等重装：无残留临时位、bundles 不重复。
- 卸载：五项残留检查全 False、之后 `pnpm install` 不报错。
- 从 1.2.6 旧装法升级：实体目录 → 软链、旧内容不残留、无重复 bundle 条目。
- 首装失败（校验阶段就挂）：回到装之前，无包体 / 无软链 / 无声明 / 无 bundle 条目。
- 升级失败（包已发布后挂）：包体、lockfile、软链、依赖声明全部还原。
- 旧装法升级失败：还原成 1.2.6 的实体目录，内容逐字节一致。

### 实测记录（真实 profile）

- 装进 `/root/projects/.dsh/profiles/web` 后：软链指向 `local-plugins/`、依赖声明为 `link:./local-plugins/@local/dsh-termux-bridge`、`require.resolve` 正常。
- 紧接着在同一个 profile 跑 `pnpm install --frozen-lockfile`（Done in 1.5s）后**软链原样存活**，幽灵依赖问题彻底解决。
- `node --test test/bridge.test.cjs` → 20 passed / 0 failed；`node test/smoke.cjs` → SMOKE OK。

### 顺带发现的连带风险（已写进 README 2.4）

跑 `pnpm install` 时，**同机用旧装法的插件会被一起清掉**。本次实测中 `@local/dsh-mobile-adapt`、
`@local/mobile-pilot`、`@local/browser-use` 三个目录当场消失（它们只有 bundle 条目、没有 `dependencies` 声明）。
最阴的是：dsh 进程里早已加载过这些插件，所以当场的工具列表照旧可用，**要等下一次重启才集体失踪**，
日志只写「cannot resolve profile bundle」，完全看不出是 pnpm 干的。三者的恢复办法是各自重跑安装器
（`browser-use` 的安装器**必须带 profile 目录参数**，否则退出 1）。

### 工具坑

- 用 `dsh ... | grep ...` 判断插件是否加载**不可靠**：`dsh` 不在客人 shell 的默认 PATH 里，
  `command not found` 会被管道吞掉，grep 静默返回空，看起来就像「插件没加载」。
  正确写法是绝对路径 `/root/projects/.dsh/dshbox/bin/dsh --profile web --dump-config`。
## [1.2.6] —— 2026-10-26

修掉测试套件的进程泄漏：**20 条用例全过，但进程永不退出**。之前一直靠 `timeout` 硬杀，
所以 CI 里看着是绿的，其实每条流水线都在白等满 250 秒。

### 修复

- **测试收尾留下孤儿 agent，握着管道写端导致事件循环不空**。`boot()` 里 `spawn` 出 agent 后
  只做了 `child.kill('SIGKILL')`：agent 变成 PPID=1 的孤儿**继续持有 spawn 时那两条 stdio 管道**，
  Node 认为还有活跃句柄，进程就永远不退出。现象很有欺骗性——`node --test` 报
  `tests 21 / pass 20 / fail 0 / cancelled 1`，duration 卡到 timeout 被杀，
  可文件里明明只有 20 个 `test()`：那个「第 21 个」是文件级伪用例，即整个进程没能收场。
  修法三处：`spawn` 加 `detached: true`；`t.after` 改为 `await killTree(child)`，内部发
  `process.kill(-child.pid, 'SIGKILL')` 按**进程组**收整棵树（连同 agent fork 的 `timeout`），
  并 `await` 它的 `exit`；最后显式 `destroy()` stdout/stderr。
- **副作用兜底**：`killTree` 带 5 秒超时，进程组杀不掉时按 pid 补一刀，避免收尾自己挂住。

### 已验证

- `node --test test/bridge.test.cjs` → **tests 20 / pass 20 / fail 0 / cancelled 0**，
  **duration 13.7s，进程自然退出（EXIT=0）**，不再需要 `timeout` 兜底。
- 同时清理了历史遗留的三个孤儿 `bash /tmp/dsh-bridge-test-*/agent.sh`。
- README 第 8 节更新：删掉「跑完可能不退出，后台跑再 tail 日志」的旧提醒，
  并把「按进程组杀 + await exit + destroy 管道」写进「环境隔离约定」，作为改测试时的硬约束。

## [1.2.5] —— 2026-10-26

首次真正跑通发布流程（`Azek431/dsh-termux-bridge` 上线）时暴露的三个 bug。
前两个是同一类错误：把环境变量赋值写在了命令**后面**，bash 会把它们当成参数传给
被调用的程序，而不是设进环境。写的时候看不出来，只有在真机上跑一次才会炸。

### 修复

- **建仓请求体为空（`KeyError: N`）**。原写法
  `python3 -c '...os.environ["N"]...' N="$NAME" P="$PRIVATE" D="$DESC"` 把三项赋值当成了
  python 的位置参数，`os.environ` 里根本没有 `N`，建仓直接抛 `KeyError`。改为把赋值前置：
  `N=... P=... D=... python3 -c '...'`。
- **topic 一个都没写进去（`KeyError: T`）**。同一个错误，循环里 `..." T="$t"` 同样无效，
  8 个 topic 全部静默失败（`>/dev/null || true` 把错误吞了，所以更隐蔽）。
  顺便**重构掉逐条读改写**：原来是「读取现有 topics → 追加一个 → PUT 回去」循环 8 次，
  既慢又会在中途失败时留下半成品；改成一次 PUT 全量覆盖，并用 `printf | tr | python3`
  拼 JSON 数组。
- **网络瞬断让整个流程前功尽弃**。建仓时遇到 `curl: (56) Recv failure: Software caused
  connection abort`，脚本直接退出 —— 但其实仓库已经在服务端建好了，只是响应半路断了。
  三处加固：`auth_api()` 统一加 `--retry 4 --retry-delay 2 --retry-all-errors --max-time 40`；
  建仓响应拿不到时**回查一次** `GET /repos/{owner}/{repo}`，存在就继续而不是报失败；
  首次 `git push` 失败自动重试一次。

### 已验证

- `https://github.com/Azek431/dsh-termux-bridge` 可访问，21 个文件全部到位，默认分支 `main`，
  3 个 commit 作者均为 `Azek431`。
- 仓库元数据：description / homepage（`deepseek-ai/deepseek-harness`）/ license `GPL-3.0` /
  8 个 topic 全部生效。
- 脚本重跑幂等：第二次执行正确打印「仓库已存在，跳过创建」与「Everything up-to-date」。

## [1.2.4] —— 2026-10-26

### 新增

- `scripts/push-with-token.sh`：**零交互**发布路径。只依赖 `curl` + `git`，
  连 `gh` 都不需要，不读 TTY、不问任何问题。token 从 `GH_TOKEN` / `GITHUB_TOKEN` 或 stdin 读入，
  `GET /user` 校验并认出 login；仓库不存在才建仓；`git push` 用**一次性 credential helper**
  从环境传 token（不写进 `.git/config`、不拼进 remote URL），最后补 8 个 topic。

### 修复（认知）

- **推翻上一版对卡死的归因**。死代理确实存在、确实是隐患，但它**不是** `gh auth login` 卡住的
  根本原因：用户清空全部代理变量、四个候选端口全 closed、`curl https://github.com` 返回 200 之后，
  `gh auth login` 依然停在原地。
- 实测证明网络与 device flow 本身完全可用：`POST https://github.com/login/device/code` 返回 HTTP/2 200，
  `user_code` 正常生成，`expires_in 899 / interval 5`；轮询
  `POST https://github.com/login/oauth/access_token` 稳定返回 `authorization_pending`。
  真正卡住的是 `gh` 的**终端交互层**（同一 TTY 内读回车 → 切前台开浏览器 → 再读回结果）。
  结论写进 README 第 9 节：代理清了、端口 closed、curl 200 却还不动 ⇒ 不是网络问题，直接换 token 路径。
- 记录端点坑：device flow 是 `POST /login/device/code`，写成 `/login/oauth/device/code` 返回 **422**。
- README「一条命令」代码块下方加醒目提示，卡住时直接跳到零交互路径，不必在 `gh` 上反复重试。

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
- `scripts/push-to-github.sh` 增加**死代理预检**。设备上常见「apt 里配了 `127.0.0.1:2080`、
  但代理程序没起来」，这种死代理会让 `gh` / `git` 在联网那一步**无声挂住**（不报错、只是不动）。
  典型现场：`gh auth login` 选完 "Authenticate Git with your GitHub credentials? Yes" 之后就再也不动
  —— 它卡在拉 device code。实测该端口 ECONNREFUSED，而直连 GitHub 正常（200 / 0.4s，
  device code POST 200 / 0.5s）。脚本现在先探 `http_proxy`/`https_proxy`/`all_proxy`（大小写共 6 个）
  与 `git config --global http.proxy` 指向的端口，探到死端口直接停下并打印修法。
- README 新增「`gh auth login` 卡住不动？先查死代理」一节：三步排查（env | grep -i proxy、
  /dev/tcp 探端口、curl 直连 GitHub）+ 清代理修法 + `GIT_TERMINAL_PROMPT=1`；
  以及 token 兜底路径 `gh auth login --with-token`。

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