#!/usr/bin/env bash
# =============================================================================
# DSH Termux 桥接 agent —— 在 Termux 里跑，主动连回 DSH 客人侧的 127.0.0.1 端口。
#
# 为什么是这个方向：DSH 跑在 App 的 PRoot 客人里，客人内没有 am / su，拉不起
# Termux 进程，两边也没有共享文件系统。唯一的联系是共享同一个网络命名空间，
# 所以只能由你在 Termux 里手动起一次本脚本，让它连回 loopback。
#
# 零依赖：只用 bash 内建 + base64 + date（Termux 基础包自带）。
# 不装 nc / socat / jq / python。
#
# 用法：
#   bash ~/dsh-termux-agent.sh          # 前台跑，Ctrl-C 退出
#   nohup bash ~/dsh-termux-agent.sh >/dev/null 2>&1 &   # 后台跑
#
# 协议：一行一帧，空格分列，所有可能含空格的字段都是 base64（空值写 '-'）。
#   HELLO <ver> <token_b64> <name_b64> <caps>
#   WELCOME <ver> <host_b64> | DENY <code> <text_b64>
#   EXEC    <id> <timeout_ms> <cwd_b64|-> <script_b64> <max_bytes>
#   EXECRAW <id> <timeout_ms> <cwd_b64|-> <nbytes> <max_bytes>
#           <<< 本行之后紧跟 nbytes 个裸字节的脚本正文（非 base64）
#   PUT  <id> <w|a> <path_b64> <data_b64>
#   PUTRAW <id> <w|a> <path_b64> <nbytes>  <<< 本行之后紧跟 nbytes 个裸字节（非 base64）
#   GET  <id> <path_b64> <max_bytes>
#   RESULT <id> <exit> <elapsed_ms> <truncated 0|1> <stdout_b64|-> <stderr_b64|-> <timed_out 0|1> [hint]
#   DATA   <id> <exit> <data_b64|-> <stderr_b64|-> <truncated 0|1>
#   PING <id> -> PONG <id>
#
# 为什么要有 EXECRAW（1.2.9）：脚本走 base64 时，光是从 socket 读完那一行就要
# 逐字节 read(2)（几十毫秒），还得再 fork 两个进程做 base64 -d。裸字节让
# head -c N 直接从 socket 落盘，既没有 33% 膨胀，也不用额外进程。
# =============================================================================
set -u

HOST="__DSH_HOST__"
PORT="__DSH_PORT__"
TOKEN="__DSH_TOKEN__"
NAME="__DSH_NAME__"

[ -n "${DSH_BRIDGE_HOST:-}" ] && HOST="$DSH_BRIDGE_HOST"
[ -n "${DSH_BRIDGE_PORT:-}" ] && PORT="$DSH_BRIDGE_PORT"
[ -n "${DSH_BRIDGE_TOKEN:-}" ] && TOKEN="$DSH_BRIDGE_TOKEN"
[ -n "${DSH_BRIDGE_NAME:-}" ] && NAME="$DSH_BRIDGE_NAME"

SILENT=0
[ "${1:-}" = "--quiet" ] && SILENT=1
say() { [ "$SILENT" = 1 ] || printf '%s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

if ! have base64; then
  printf '缺少 base64 命令。请在 Termux 里执行: pkg install coreutils\n' >&2
  exit 1
fi

# base64 -w0 一次进程就出「不带换行」的结果。busybox 版没有 -w，退回 base64|tr 两进程。
B64W=0
if printf x | base64 -w0 >/dev/null 2>&1; then B64W=1; fi
b64pipe() { if [ "$B64W" = 1 ]; then base64 -w0; else base64 | tr -d '\n'; fi; }
b64file() { if [ "$B64W" = 1 ]; then base64 -w0 < "$1"; else base64 < "$1" | tr -d '\n'; fi; }
b64e() { b64pipe; }
b64d() { base64 -d 2>/dev/null; }
# 空串必须编码成 '-'，否则空格分列会把字段个数弄错。
enc() { local s; s=$(printf '%s' "$1" | b64e); [ -z "$s" ] && s='-'; printf '%s' "$s"; }
dec() { [ "$1" = '-' ] && return 0; printf '%s' "$1" | b64d; }

# ── 回包写法的分界点：一次 write 还是流式 ─────────────────────────────────
# 实测出来的硬约束（/tmp/nagleproof.cjs，n=2 轮 × 9 次）：同一份回包内容，
# 一次 write 发完是 0ms，拆成 2~3 次 write 发是固定 40ms。
# 那 40ms 不是我们的代码慢，是 TCP 的 Nagle + 延迟 ACK：
# 第一段小数据发出去后，后续 write 要等对端 ACK，而对端在等 40ms 的延迟 ACK 定时器。
# 桥接侧（Node）自己的 socket 已经 setNoDelay(true)（bridge.js:206），但那管不到
# agent 这一侧 —— bash 的 /dev/tcp 没有 setsockopt，TCP_NODELAY 在这里设不了。
# 所以唯一能做的就是把「小回包」压成一次 write：
#   · 小于等于 SMALL_OUT 字节的 stdout / 文件，先 base64 进变量，再 printf 一次整行；
#   · 更大的才流式（那时 40ms 被几十上百毫秒的总量摊薄，流式省下的 30~50ms 更值）。
# 阈值可用 DSH_BRIDGE_SMALL_OUT 覆盖，方便基准脚本做 A/B。
SMALL_OUT=${DSH_BRIDGE_SMALL_OUT:-65536}
case "$SMALL_OUT" in ''|*[!0-9]*) SMALL_OUT=65536 ;; esac

USE_TIMEOUT=0
have timeout && USE_TIMEOUT=1
# --preserve-status 是 GNU coreutils 的扩展（BSD/macOS 的 timeout 没有）。
# 没有它，被 timeout 杀掉和脚本自己 exit 124 就分不开了，只能退回旧的三层 runner。
# 探测一次，失败就降级——宁可慢几毫秒，也不要在别家 timeout 上直接报错退出。
PRESERVE=0
if [ "$USE_TIMEOUT" = 1 ] && timeout --preserve-status 1 true >/dev/null 2>&1; then
  PRESERVE=1
fi

# ── 计时：不 fork ─────────────────────────────────────────────────────────
# bash 5 的 EPOCHREALTIME 是内建变量。date 一次要 7.96ms（PRoot 下），
# 一条命令记两次时间就是 16ms —— 比真正执行 true（4.5ms）还贵。
# 写成「赋值给全局变量」而不是「打印」，连 $( ) 的子 shell fork 也省掉。
NOW_MS=0
now_get() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local t=${EPOCHREALTIME/./}
    NOW_MS=$(( t / 1000 ))
    return
  fi
  local x
  x=$(date +%s%3N 2>/dev/null)
  case "$x" in
    *N*) NOW_MS=$(( $(date +%s) * 1000 )) ;;
    *)   NOW_MS=$x ;;
  esac
}

# ── 工作目录：只建一次 ───────────────────────────────────────────────────
# mktemp -d 每次 8.9ms，rm -rf 每次 7.5ms。命令之间是严格串行的，
# 所以一个进程只需要一个工作目录，用递增序号区分文件，每 32 次统一清一次，
# 把 rm 摊到每次约 0.2ms。
WORK=""
WORK_DIR="${TMPDIR:-/tmp}/dsh-bridge.$$.$RANDOM"
if mkdir -p "$WORK_DIR" 2>/dev/null; then
  WORK="$WORK_DIR"
  trap 'rm -rf "$WORK"' EXIT INT TERM
else
  printf '无法创建临时目录 %s\n' "$WORK_DIR" >&2
  exit 1
fi
RUN_SEQ=0
NEXT_BASE=""
begin_call() { RUN_SEQ=$(( RUN_SEQ + 1 )); NEXT_BASE="$WORK/j$RUN_SEQ"; }

# 早先这里有一个 runner 层：timeout → bash runner.sh → bash 用户脚本，三层 fork。
# 现在改成 timeout --preserve-status 直接跑用户脚本，省掉中间那层。
# 为什么不再需要 runner 记退出码文件：--preserve-status 会让 timeout 原样报出
# 被跑命令的退出码（实测：脚本自己 exit 124 → 124；被 timeout 杀掉 → 128+信号 = 143/137），
# 所以「自己退 124」和「被 timeout 杀」本来就能从 $? 分开，不用落盘。

say "DSH Termux 桥接 agent：目标 $HOST:$PORT，名称 $NAME"
[ "$USE_TIMEOUT" = 1 ] || say "提示: 没有 timeout 命令，命令超时不会被强制中断（pkg install coreutils 可补上）"

# ── 执行一条命令（EXEC / EXECRAW 共用的后半段）────────────────────────────
# 脚本正文已经在 $NEXT_BASE.in 里了，这里只负责跑它并把结果编码回去。
do_exec() {
  local id="$1" to="$2" cwd="$3" max="$4"
  local base="$NEXT_BASE" out="$NEXT_BASE.out" err="$NEXT_BASE.err"
  local run="$NEXT_BASE.in" code=0 start end size emit ob eb trunc timed secs

  case "$max" in ''|*[!0-9]*) max=65536 ;; esac
  [ "$max" -lt 1024 ] && max=1024

  # cwd 不存在要单独报出来。只用 exit 97 是不够的：用户自己的脚本也可能 exit 97，
  # 上层没法区分「路径写错了」和「命令真的返回了 97」。
  if [ -n "$cwd" ] && [ ! -d "$cwd" ]; then
    printf 'RESULT %s 97 0 0 - %s 0 cwd\n' "$id" "$(enc "cwd 不存在或不是目录: $cwd")" >&3
    return
  fi
  if [ -n "$cwd" ]; then
    {
      printf 'cd '
      printf '%q' "$cwd"
      printf ' || exit 97\n'
      printf 'bash '
      printf '%q' "$base.in"
      printf '\n'
    } > "$base.wrap"
    run="$base.wrap"
  fi

  secs=$(( (to + 999) / 1000 ))
  [ "$secs" -lt 1 ] && secs=1
  now_get
  start=$NOW_MS
  timed=0
  # 3>&- 把套接字关掉，不让用户脚本碰它：dsbox 的 fd 3 就是协议流，
  # 一句 echo x >&3 就能把下一帧的帧头污染成半行垃圾，整条连接从此错位。
  # 关掉之后用户再写 3 号只会拿到 Bad file descriptor，不会伤到桥。
  if [ "$USE_TIMEOUT" = 1 ] && [ "$PRESERVE" = 1 ]; then
    timeout --preserve-status -k 5 "$secs" bash "$run" > "$out" 2> "$err" </dev/null 3>&-
    code=$?
  elif [ "$USE_TIMEOUT" = 1 ]; then
    timeout -k 5 "$secs" bash "$run" > "$out" 2> "$err" </dev/null 3>&-
    code=$?
  else
    bash "$run" > "$out" 2> "$err" </dev/null 3>&-
    code=$?
  fi
  now_get
  end=$NOW_MS
  case "$code" in ''|*[!0-9]*) code=1 ;; esac
  # 唯一还剩的歧义：脚本自己 kill -TERM 自己的 PID 也是 143，与被 timeout 杀同码。
  # 用「有没有跑满时限」区分——被 timeout 杀的一定跑到了时限附近，
  # 自己发信号的通常远早于此。超时统一归一成 124，保持对上层语义稳定。
  if [ "$USE_TIMEOUT" = 1 ] && [ "$PRESERVE" = 1 ] && [ "$code" -gt 128 ]; then
    if [ $(( end - start )) -ge $(( secs * 1000 - 150 )) ]; then
      timed=1
      code=124
    fi
  fi

  # 收尾这一段原来无条件跑 4 个外部命令：wc -c、base64、head+base64。
  # PRoot 下每次 fork 8~10ms，而绝大多数命令的 stderr 是空的、很多连 stdout 都没有，
  # 这 36ms 全花在给空文件做编码上。现在按需：无 stdout 无 stderr 只付一次 test；
  # 有 stderr 才编码一次；有 stdout 才编码（写法见下面的 SMALL_OUT 分支）。
  #
  # 所以「要不要截断」靠 wc -c 的字节数判断，不靠切字符串看长度。
  #
  # ★ 另一条铁律：这段代码里绝不对超长串做全串扫描。
  #   曾经的 core=${ob%%=*} 对 1.4MB 的串是 O(n²)，75 秒都不返回（1MiB 输出用例就挂在这）。
  trunc=0
  size=0
  if [ -s "$out" ]; then
    size=$(wc -c < "$out" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    [ "$size" -gt "$max" ] && trunc=1
  fi
  eb='-'
  if [ -s "$err" ]; then
    eb=$(head -c 65536 "$err" | b64pipe)
    [ -z "$eb" ] && eb='-'
  fi

  # 字段顺序与老版本逐字节一致（RESULT id code elapsed trunc stdout stderr timed hint），
  # 所以新旧两侧任意组合都互认 —— 变的只是「怎么把 stdout 那几个字节送到套接字」，
  # 不是协议本身。两条路径都由 SMALL_OUT 这一个常量决定（见文件头部的解释）：
  #
  #   小回包 → 一次 write 发完整行。这是绝大多数命令走的路，也是把固定开销
  #            从 56ms 压回 14ms 的关键：三次 write 会白等 40ms 的延迟 ACK。
  #   大回包 → 仍然流式。此时总耗时本来就几十上百毫秒，那 40ms 被摊薄，
  #            而流式省下的 30~50ms（不把几 MB 装进变量）更值。
  #
  # 判据是「实际要发多少字节」而不是「文件多大」：截断时只发 max 个字节，
  # 一个 4MiB 的输出配 64KiB 上限，真正上网的只有 64KiB，一次 write 就够。
  # （曾用文件大小做判据，截断场景白走三段写，实测多付 36ms。）
  emit=$size
  [ "$trunc" = 1 ] && emit=$max
  if [ "$emit" -le "$SMALL_OUT" ]; then
    if [ "$size" -eq 0 ]; then
      ob='-'
    elif [ "$trunc" = 1 ]; then
      ob=$(head -c "$max" "$out" | b64pipe)
    else
      ob=$(b64pipe < "$out")
    fi
    printf 'RESULT %s %s %s %s %s %s %s -\n' \
      "$id" "$code" "$(( end - start ))" "$trunc" "$ob" "$eb" "$timed" >&3
  else
    printf 'RESULT %s %s %s %s ' "$id" "$code" "$(( end - start ))" "$trunc" >&3
    head -c "$max" "$out" | b64pipe >&3
    printf ' %s %s -\n' "$eb" "$timed" >&3
  fi

  # 每 32 次统一清一次，把 rm -rf 的成本摊薄（全局串行，删时不会有别的手上活）。
  if [ $(( RUN_SEQ % 32 )) = 0 ]; then
    rm -f "$WORK"/j* 2>/dev/null
  fi
}

# 命令替换本身就是一次 fork（PRoot 下 8~10ms），所以能不起子 shell 就别起。
# cwd 绝大多数时候是空的，帧里写的是占位符 "-"：先比字符串，只有真有内容才去解码。
# 这一条把「无 cwd 的普通 exec」省下整整一次 fork。
handle_exec() {
  local id="$1" to="$2" cwd_f="$3" script_f="$4" max="$5" cwd='' script=''
  [ "$cwd_f" = '-' ] || cwd=$(dec "$cwd_f")
  [ "$script_f" = '-' ] || script=$(dec "$script_f")
  begin_call
  printf '%s\n' "$script" > "$NEXT_BASE.in"
  do_exec "$id" "$to" "$cwd" "$max"
}

# 裸字节脚本：帧头之后紧跟 nbytes 个字节，直接落盘，不做 base64 解码。
handle_execraw() {
  local id="$1" to="$2" cwd_f="$3" nbytes="$4" max="$5" cwd='' body='' rc=0
  [ "$cwd_f" = '-' ] || cwd=$(dec "$cwd_f")
  case "$nbytes" in ''|*[!0-9]*) nbytes=0 ;; esac
  begin_call
  # 收裸字节不用 head -c + wc -c：那是两次 fork，PRoot 下每次 8~10ms，实测这条路径
  # 光收帧就占 10~13ms。read -N 是 bash 内建（实测 0ms），按字节精确读、不做行归并，
  # 落盘内容与源逐字节相同（由 test/bridge.test.cjs 的二进制 / 中文 / CRLF 用例守着）。
  # 两个前提必须同时成立：
  #   1) LC_ALL=C —— 否则 -N 数的是字符不是字节，带中文的脚本会读多。
  #   2) 正文里没有 NUL —— NUL 会让 read 提前返回，rc 非 0，下面立刻当作失败处理。
  IFS= LC_ALL=C read -r -N "$nbytes" body <&3 || rc=$?
  printf '%s' "$body" > "$NEXT_BASE.in"
  if [ "$rc" -ne 0 ]; then
    # 短读（对端提前关）或正文含 NUL。两种情况下这条流里都还剩没读走的字节，
    # 继续读下一帧只会把残字节当帧头，越错越远；直接断开，交给重连循环重建干净连接。
    printf 'RESULT %s 96 0 0 - %s 0\n' "$id" "$(enc "脚本正文读取失败（短读或含 NUL 字节），连接将重建")" >&3
    exit 1
  fi
  do_exec "$id" "$to" "$cwd" "$max"
}

handle_put() {
  local id="$1" mode="$2" path_f="$3" data_f="$4" path code=0
  path=$(dec "$path_f")
  if [ -z "$path" ]; then
    printf 'RESULT %s 96 0 0 - %s 0\n' "$id" "$(enc '远端路径为空')" >&3
    return
  fi
  mkdir -p "$(dirname "$path")" 2>/dev/null
  if [ "$mode" = "a" ]; then
    printf '%s' "$data_f" | b64d >> "$path" || code=$?
  else
    printf '%s' "$data_f" | b64d > "$path" || code=$?
  fi
  printf 'RESULT %s %s 0 0 - %s 0\n' "$id" "$code" "$(enc '')" >&3
}

handle_putraw() {
  local id="$1" mode="$2" path_f="$3" nbytes="$4"
  local path before=0 after=0 wrote code=0
  path=$(dec "$path_f")
  case "$nbytes" in ''|*[!0-9]*) nbytes=0 ;; esac
  # 无论路径是否合法，这 nbytes 个字节都必须从流里读走。
  # 留在 socket 里的字节会被当成下一帧的帧头，之后整条连接就全乱了 ——
  # 症状是「突然开始报未知帧」，而且不会自愈。
  if [ -z "$path" ]; then
    head -c "$nbytes" <&3 >/dev/null 2>&1
    printf 'RESULT %s 96 0 0 - %s 0\n' "$id" "$(enc '远端路径为空')" >&3
    return
  fi
  mkdir -p "$(dirname "$path")" 2>/dev/null
  [ "$mode" = "a" ] && [ -f "$path" ] && before=$(wc -c < "$path" 2>/dev/null)
  case "$before" in ''|*[!0-9]*) before=0 ;; esac
  # head -c N 的读循环每次 read(MIN(剩余, BUFSIZ))，不会多吃一个字节，
  # 所以紧随其后的下一帧帧头是安全的；对端半路消失时也不会永久阻塞。
  if [ "$USE_TIMEOUT" = 1 ]; then
    if [ "$mode" = "a" ]; then
      timeout -k 2 120 head -c "$nbytes" <&3 >> "$path" || code=$?
    else
      timeout -k 2 120 head -c "$nbytes" <&3 > "$path" || code=$?
    fi
  else
    if [ "$mode" = "a" ]; then
      head -c "$nbytes" <&3 >> "$path" || code=$?
    else
      head -c "$nbytes" <&3 > "$path" || code=$?
    fi
  fi
  after=$(wc -c < "$path" 2>/dev/null)
  case "$after" in ''|*[!0-9]*) after=0 ;; esac
  wrote=$(( after - before ))
  # 短读必须显式报错：半截文件看起来和成功一模一样，
  # 用户拿到 ok=true 却得到被截断的二进制，比直接失败难查得多。
  if [ "$wrote" -ne "$nbytes" ]; then
    printf 'RESULT %s 96 0 0 - %s 0\n' "$id" "$(enc "只收到 $wrote/$nbytes 字节，连接可能中断")" >&3
    return
  fi
  printf 'RESULT %s %s 0 0 - %s 0\n' "$id" "$code" "$(enc '')" >&3
}

handle_get() {
  local id="$1" path_f="$2" max="$3" path size emit eb='-' trunc=0 code=0 data='-'
  path=$(dec "$path_f")
  case "$max" in ''|*[!0-9]*) max=8388608 ;; esac
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    printf 'DATA %s 3 - %s 0\n' "$id" "$(enc "读不到文件: $path")" >&3
    return
  fi
  size=$(wc -c < "$path" 2>/dev/null)
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  [ "$size" -gt "$max" ] && trunc=1
  # 与 do_exec 完全相同的两条路径、同样的理由（见文件头部 SMALL_OUT 的注释）：
  # 小文件一次 write 发完整行，避开 Nagle 的 40ms 延迟 ACK；大文件才流式，
  # 免得把 8MiB 的 base64（10.9MB）装进变量。判据同样是「实发字节数」。
  emit=$size
  [ "$trunc" = 1 ] && emit=$max
  if [ "$emit" -le "$SMALL_OUT" ]; then
    if [ "$trunc" = 1 ]; then
      data=$(head -c "$max" "$path" | b64pipe)
    else
      data=$(b64pipe < "$path")
    fi
    [ -z "$data" ] && data='-'
    printf 'DATA %s %s %s %s %s\n' "$id" "$code" "$data" "$eb" "$trunc" >&3
  else
    printf 'DATA %s %s ' "$id" "$code" >&3
    head -c "$max" "$path" | b64pipe >&3
    printf ' %s %s\n' "$eb" "$trunc" >&3
  fi
}

# ── 主循环：断了就重连，直到被 Ctrl-C ────────────────────────────────────
# DENY 分两类：认不出的（令牌错、协议不匹配）必须直接退出。老版本对所有 DENY
# 一律 break 然后立刻重连，令牌错时就变成一个 3 秒一次的无限重连循环，进程永远留在
# 后台 —— 这正是测试里能残留一堆 agent、把后来那次冒烟测试搞脏的原因。
FIFO_WAIT=90
FATAL=0
FAILS=0
# 重试上限：0 = 无限重试（默认，DSH 重启后 agent 自己会接回去）。
# 设成 >0 时，连续失败这么多次就退出 —— 测试用它保证 agent 不会变成孤儿进程。
MAX_FAIL=${DSH_BRIDGE_MAX_FAIL:-0}
case "$MAX_FAIL" in ''|*[!0-9]*) MAX_FAIL=0 ;; esac
while [ "$FATAL" = 0 ]; do
  if ! exec 3<>"/dev/tcp/$HOST/$PORT" 2>/dev/null; then
    FAILS=$(( FAILS + 1 ))
    if [ "$MAX_FAIL" -gt 0 ] && [ "$FAILS" -ge "$MAX_FAIL" ]; then
      say "连续 $FAILS 次连不上 $HOST:$PORT，已达上限，退出"
      exit 1
    fi
    # 退避：3,6,12,24,30,30… 秒。固定 3 秒在 DSH 关掉之后会变成一个安静的
    # 每 3 秒一次的无限空转，谁也注意不到。
    BACKOFF=$(( 3 << (FAILS - 1) ))
    [ "$BACKOFF" -gt 30 ] && BACKOFF=30
    say "连不上 $HOST:$PORT，${BACKOFF} 秒后重试（DSH 没起或端口不对）"
    sleep "$BACKOFF"
    continue
  fi
  # 第 4 字段是能力声明：服务端据此决定用 EXECRAW / PUTRAW（裸字节）还是老的 base64。
  # 老服务端会忽略多余字段，所以这条改动对旧版服务端是安全的。
  printf 'HELLO 1 %s %s raw,rawx\n' "$(enc "$TOKEN")" "$(enc "$NAME")" >&3
  say "已连接，等待任务…"

  silent=0
  while :; do
    if IFS= read -r -t "$FIFO_WAIT" -u 3 line; then
      :
    else
      rc=$?
      if [ "$rc" -le 128 ]; then
        # read 返回 1 = EOF，连接已断
        say "连接被关闭，重连"
        break
      fi
      # >128 = 超时。服务器每 30 秒发一次 PING；连续两个窗口都没动静说明对端已经不在了。
      silent=$(( silent + 1 ))
      [ "$silent" -ge 2 ] && { say "对端静默，重连"; break; }
      continue
    fi
    silent=0
    [ -z "$line" ] && continue
    tag=${line%% *}
    rest=""
    [ "$tag" != "$line" ] && rest=${line#* }
    case "$tag" in
      WELCOME)
        FAILS=0
        say "握手成功：$rest"
        ;;
      BYE)
        # 服务端让我们别连了（典型场景：同一个名字的新 agent 已经在跑，我们这个是被顶掉的旧连接）。
        # 必须直接退出：否则断线后立刻重连，再反过来把新的顶掉，两条连接乒乓对踢。
        say "被服务端要求断开：$(printf '%s' "$rest" | b64d 2>/dev/null)"
        FATAL=1
        break
        ;;
      DENY)
        code=${rest%% *}
        say "被拒绝：$code $(printf '%s' "${rest#* }" | b64d 2>/dev/null)"
        case "$code" in
          E_BAD_TOKEN|E_PROTO_MISMATCH)
            # 重连一万次也不会变好：令牌与协议版本都是脚本里的常量，只能换脚本。
            say "这个错误重试无用，agent 退出。请回 DSH 里重新执行 termux_bootstrap 拿新启动脚本。"
            FATAL=1
            ;;
          *)
            say "10 秒后重试"
            sleep 10
            ;;
        esac
        break
        ;;
      PING)
        printf 'PONG %s\n' "$rest" >&3
        ;;
      EXEC)
        IFS=' ' read -r -a F <<< "$rest"
        handle_exec "${F[0]:-}" "${F[1]:-30000}" "${F[2]:--}" "${F[3]:--}" "${F[4]:-65536}"
        ;;
      EXECRAW)
        IFS=' ' read -r -a F <<< "$rest"
        handle_execraw "${F[0]:-}" "${F[1]:-30000}" "${F[2]:--}" "${F[3]:-0}" "${F[4]:-65536}"
        ;;
      PUT)
        IFS=' ' read -r -a F <<< "$rest"
        handle_put "${F[0]:-}" "${F[1]:-w}" "${F[2]:--}" "${F[3]:--}"
        ;;
      PUTRAW)
        IFS=' ' read -r -a F <<< "$rest"
        handle_putraw "${F[0]:-}" "${F[1]:-w}" "${F[2]:--}" "${F[3]:-0}"
        ;;
      GET)
        IFS=' ' read -r -a F <<< "$rest"
        handle_get "${F[0]:-}" "${F[1]:--}" "${F[2]:-8388608}"
        ;;
      PONG|RESULT|DATA)
        : ;;
      *)
        : ;;
    esac
  done

  exec 3>&- 2>/dev/null
  exec 3<&- 2>/dev/null
  sleep 1
done