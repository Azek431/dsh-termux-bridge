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

  printf 'RESULT %s %s %s %s %s %s %s\n' "$id" "$code" "$(( end - start ))" "$trunc" "$ob" "$eb" "$timed" >&3
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
FIFO_WAIT=90
while :; do
  if ! exec 3<>"/dev/tcp/$HOST/$PORT" 2>/dev/null; then
    say "连不上 $HOST:$PORT，3 秒后重试（DSH 没起或端口不对）"
    sleep 3
    continue
  fi
  printf 'HELLO 1 %s %s\n' "$(enc "$TOKEN")" "$(enc "$NAME")" >&3
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
        say "握手成功：$rest"
        ;;
      DENY)
        code=${rest%% *}
        say "被拒绝：$code $(printf '%s' "${rest#* }" | b64d 2>/dev/null)"
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
