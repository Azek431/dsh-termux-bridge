#!/usr/bin/env bash
# =============================================================================
# DSH Termux 桥接 agent —— 在 Termux 里跑，主动连回 DSH 客人侧的 127.0.0.1 端口。
#
# 为什么是这个方向：DSH 跑在 App 的 PRoot 客人里，客人内没有 am / su，拉不起
# Termux 进程，两边也没有共享文件系统。唯一的联系是共享同一个网络命名空间，
# 所以只能由你在 Termux 里手动起一次本脚本，让它连回 loopback。
#
# 零依赖：只用 bash 内建 + base64 + date + mktemp（Termux 基础包自带）。
# 不装 nc / socat / jq / python。
#
# 用法：
#   bash ~/dsh-termux-agent.sh          # 前台跑，Ctrl-C 退出
#   nohup bash ~/dsh-termux-agent.sh >/dev/null 2>&1 &   # 后台跑
#
# 协议：一行一帧，空格分列，所有可能含空格的字段都是 base64（空值写 '-'）。
#   HELLO <ver> <token_b64> <name_b64>
#   WELCOME <ver> <host_b64> | DENY <code> <text_b64>
#   EXEC <id> <timeout_ms> <cwd_b64|-> <script_b64> <max_bytes>
#   PUT  <id> <w|a> <path_b64> <data_b64>
#   PUTRAW <id> <w|a> <path_b64> <nbytes>  ← 本行之后紧跟 nbytes 个裸字节（非 base64）
#   GET  <id> <path_b64> <max_bytes>
#   RESULT <id> <exit> <elapsed_ms> <truncated 0|1> <stdout_b64|-> <stderr_b64|-> <timed_out 0|1>
#   DATA   <id> <exit> <data_b64|-> <stderr_b64|-> <truncated 0|1>
#   PING <id> -> PONG <id>
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

b64e() { base64 | tr -d '\n'; }
b64d() { base64 -d 2>/dev/null; }
# 空串必须编码成 '-'，否则空格分列会把字段个数弄错。
enc() { local s; s=$(printf '%s' "$1" | b64e); [ -z "$s" ] && s='-'; printf '%s' "$s"; }
dec() { [ "$1" = '-' ] && return 0; printf '%s' "$1" | b64d; }

now_ms() {
  local t
  t=$(date +%s%3N 2>/dev/null)
  case "$t" in
    *N*) printf '%s' $(( $(date +%s) * 1000 )) ;;
    *)   printf '%s' "$t" ;;
  esac
}

say "DSH Termux 桥接 agent：目标 $HOST:$PORT，名称 $NAME"
[ -n "$(command -v timeout 2>/dev/null)" ] || say "提示: 没有 timeout 命令，命令超时不会被强制中断（pkg install coreutils 可补上）"

# ── 单条命令的处理 ────────────────────────────────────────────────────────
handle_exec() {
  local id="$1" to="$2" cwd_f="$3" script_f="$4" max="$5"
  local cwd script dir code out err start end size ob eb trunc timed flag secs wrap run
  cwd=$(dec "$cwd_f")
  script=$(dec "$script_f")
  case "$max" in ''|*[!0-9]*) max=65536 ;; esac
  [ "$max" -lt 1024 ] && max=1024

  dir=$(mktemp -d "${TMPDIR:-/tmp}/dsh-bridge.XXXXXX" 2>/dev/null) || dir=""
  if [ -z "$dir" ]; then
    printf 'RESULT %s 98 0 0 - %s 0\n' "$id" "$(enc '无法创建临时目录')" >&3
    return
  fi
  printf '%s\n' "$script" > "$dir/body.sh"
  run="$dir/body.sh"
  # cwd 不存在要单独报出来。只用 exit 97 是不够的：用户自己的脚本也可能 exit 97，
  # 上层没法区分「路径写错了」和「命令真的返回了 97」。所以先自己探一次目录，
  # 命中就直接回 RESULT 并带上 kind=cwd；wrap.sh 里的 "|| exit 97" 只作为
  # 检查与执行之间目录被删掉的竞态兜底。
  if [ -n "$cwd" ] && [ ! -d "$cwd" ]; then
    printf 'RESULT %s 97 0 0 - %s 0 cwd\n' "$id" "$(enc "cwd 不存在或不是目录: $cwd")" >&3
    rm -rf "$dir" 2>/dev/null
    return
  fi
  if [ -n "$cwd" ]; then
    {
      printf 'cd '
      printf '%q' "$cwd"
      printf ' || exit 97\n'
      printf 'bash '
      printf '%q' "$dir/body.sh"
      printf '\n'
    } > "$dir/wrap.sh"
    run="$dir/wrap.sh"
  fi

  secs=$(( (to + 999) / 1000 ))
  [ "$secs" -lt 1 ] && secs=1
  # 用 runner 把「命令自己的退出码」写进文件，再让 timeout 包着 runner 跑。
  # 这样两种情况不会混：命令自己 exit 124（文件里写着 124）vs 被 timeout 杀掉（文件根本没写成）。
  # 只看 $? 是分不出来的，两者都是 124。
  cat > "$dir/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
bash "$1" >"$2" 2>"$3" </dev/null
printf '%s' "$?" > "$4"
RUNNER
  start=$(now_ms)
  timed=0
  if have timeout; then
    timeout -k 5 "$secs" bash "$dir/runner.sh" "$run" "$dir/out" "$dir/err" "$dir/code"
  else
    bash "$dir/runner.sh" "$run" "$dir/out" "$dir/err" "$dir/code"
  fi
  end=$(now_ms)
  if [ -f "$dir/code" ]; then
    code=$(cat "$dir/code" 2>/dev/null)
    case "$code" in ''|*[!0-9]*) code=1 ;; esac
  else
    code=124
    timed=1
  fi

  size=$(wc -c < "$dir/out" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  trunc=0
  [ "$size" -gt "$max" ] && trunc=1
  ob=$(head -c "$max" "$dir/out" 2>/dev/null | b64e); [ -z "$ob" ] && ob='-'
  eb=$(head -c 65536 "$dir/err" 2>/dev/null | b64e); [ -z "$eb" ] && eb='-'

  printf 'RESULT %s %s %s %s %s %s %s -\n' "$id" "$code" "$(( end - start ))" "$trunc" "$ob" "$eb" "$timed" >&3
  rm -rf "$dir" 2>/dev/null
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
  if have timeout; then
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
  local id="$1" path_f="$2" max="$3" path size data eb trunc=0 code=0
  path=$(dec "$path_f")
  case "$max" in ''|*[!0-9]*) max=8388608 ;; esac
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    printf 'DATA %s 3 - %s 0\n' "$id" "$(enc "读不到文件: $path")" >&3
    return
  fi
  size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  [ "$size" -gt "$max" ] && trunc=1
  data=$(head -c "$max" "$path" | b64e); [ -z "$data" ] && data='-'
  eb='-'
  printf 'DATA %s %s %s %s %s\n' "$id" "$code" "$data" "$eb" "$trunc" >&3
}

# ── 主循环：断了就重连，直到被 Ctrl-C ────────────────────────────────────
# DENY 分两类：认不出的（令牌错、协议不匹配）必须**直接退出**。老版本对所有 DENY
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
  # 第 4 字段是能力声明：服务端据此决定用 PUTRAW(裸字节) 还是老的 PUT(base64)。
  # 老服务端会忽略多余字段，所以这条改动对旧版服务端是安全的。
  printf 'HELLO 1 %s %s raw\n' "$(enc "$TOKEN")" "$(enc "$NAME")" >&3
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
