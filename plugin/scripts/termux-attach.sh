#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# DSH Termux 桥接 —— 一键挂载脚本
#
# 放在 Android 共享存储里，Termux 直接 bash 它即可连回 DSH 客人侧的桥接端口。
# 与 DSH 客人共享同一网络命名空间，所以 127.0.0.1 是通的，不需要 root、不需要端口映射。
#
# 用法（在 Termux 里，复制整行）：
#   bash ~/storage/shared/编程/DeepSeek-Hermes/插件/dsh-termux-bridge/scripts/termux-attach.sh
#   # 或指定名字：bash ... termux-attach.sh my-phone
#
# 想常驻（推荐，这样以后都不用管 Termux 有没有在前台）：
#   termux-wake-lock
#   nohup bash ~/storage/shared/编程/DeepSeek-Hermes/插件/dsh-termux-bridge/scripts/termux-attach.sh \
#     >> ~/.dsh-bridge.log 2>&1 &
#
# 令牌每次 DSH 重启可能变化，所以本脚本不内置令牌，而是每次向桥接端口现拉：
# 这样脚本可以长期放在共享存储里不用改。
# =============================================================================
set -u

HOST="${DSH_BRIDGE_HOST:-127.0.0.1}"
PORT="${DSH_BRIDGE_PORT:-8791}"
NAME="${1:-${DSH_BRIDGE_NAME:-}}"

URL="http://$HOST:$PORT/agent"
[ -n "$NAME" ] && URL="$URL?name=$(printf '%s' "$NAME" | tr -d '&?=' )"

echo "==> 从 $URL 拉取 agent 脚本"

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    echo "缺少 curl 与 wget，Termux 里先跑: pkg install curl" >&2
    return 1
  fi
}

TMP="${TMPDIR:-/tmp}/dsh-bridge-agent.$$.sh"
if ! fetch "$URL" > "$TMP" 2>/dev/null || [ ! -s "$TMP" ]; then
  rm -f "$TMP"
  cat >&2 <<EOF
拉取失败。依次自查：
  1) DSH 这边桥接在监听吗  —— 让模型跑 termux_status
  2) 端口对不对              —— 上面 URL 里的 $PORT
  3) 本机 127.0.0.1 通不通    —— Termux 里: curl -v http://$HOST:$PORT/agent
EOF
  exit 1
fi

echo "==> 已获取 $(wc -c <"$TMP" | tr -d ' ') 字节，开始连接（Ctrl-C 退出，连上后收到 BYE 会自动重连）"
exec bash "$TMP"
