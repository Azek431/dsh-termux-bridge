#!/usr/bin/env bash
# 本地插件自愈守卫：pnpm install 会把没写进 dependencies 的 @local/* 当幽灵依赖清掉，
# 而 profile 的 bundles 里仍然记着它们 —— 结果是 dsh 启动时找不到包、工具凭空消失。
# 本脚本只做一件事：发现 @local 下的包缺失，就重跑对应的 install.sh。
#
# 用法：
#   bash scripts/ensure-installed.sh                 # 自检 + 缺失自动补装
#   bash scripts/ensure-installed.sh --check         # 只自检，不装（CI/收工前用）
#   PROFILE=/path/to/profile bash scripts/ensure-installed.sh
set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

PROFILE="${PROFILE:-/root/projects/.dsh/profiles/web}"
LOCAL="$PROFILE/node_modules/@local"
DSHBOX="${DSHBOX:-/root/projects/.dsh/dshbox/dshbox-plugins}"

# 包目录名 => 安装器路径（安装器自己知道怎么把包名写进 bundles）
declare -A INSTALLER=(
  [dsh-mobile-adapt]="$DSHBOX/mobile-adapt/install.sh"
  [mobile-pilot]="$DSHBOX/mobile-pilot/install.sh"
  [browser-use]="$DSHBOX/browser-use/install.sh"
  [dsh-termux-bridge]="$(cd -- "$(dirname -- "$0")/.." && pwd -P)/install.sh"
)

missing=()
for dir in "${!INSTALLER[@]}"; do
  [ -s "$LOCAL/$dir/package.json" ] || missing+=("$dir")
done

if [ ${#missing[@]} -eq 0 ]; then
  echo "OK: @local 下 " ${#INSTALLER[@]} " 个包都在"
  exit 0
fi

echo "缺失 "${#missing[@]} " 个 @local 包：${missing[*]}"
if [ "$CHECK_ONLY" = 1 ]; then
  echo "（--check 模式，不自动补装）"
  exit 1
fi

rc=0
for dir in "${missing[@]}"; do
  installer="${INSTALLER[$dir]}"
  if [ ! -f "$installer" ]; then
    echo "!! $dir 的安装器不存在: $installer" >&2
    rc=1; continue
  fi
  echo "==> 重装 $dir"
  # browser-use 的安装器要求显式传 profile；其余两者都行
  if ! bash "$installer" "$PROFILE" >/tmp/ensure-$dir.log 2>&1; then
    echo "!! $dir 装失败，日志 /tmp/ensure-$dir.log" >&2
    tail -5 /tmp/ensure-$dir.log >&2
    rc=1; continue
  fi
  [ -s "$LOCAL/$dir/package.json" ] && echo "    OK $dir" || { echo "!! $dir 仍缺失" >&2; rc=1; }
done

echo
echo "补装完成后必须重启 dsh 才生效。"
exit $rc
