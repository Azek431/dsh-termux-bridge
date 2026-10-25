#!/usr/bin/env bash
# uninstall.sh — 卸载 termux-bridge（DSH ⇄ Termux 桥接）
# 用法: bash uninstall.sh [profile目录]
#
# 顺序与安装相反：**先从 bundles 里摘掉这一条**，再删包目录。
# 删除范围以安装时留下的所有权清单为准：只动清单登记的包目录，不凭"文件内容含某个字符串"
# 在规范路径之外扩大删除面。本包不建 node_modules/.bin 入口，所以这里没有命令链接要收。
# 不碰 Termux 侧：agent 脚本由用户自己在 Termux 里装/删，卸载插件不会去连它、也不会去删它。
set -e
PROFILE="${1:-}"
if [ -z "$PROFILE" ]; then
  if [ -n "${DSH_HOME:-}" ] && [ -d "$DSH_HOME/profiles/web" ]; then PROFILE="$DSH_HOME/profiles/web"; fi
fi
if [ -z "$PROFILE" ] || [ ! -d "$PROFILE" ]; then
  echo "❌ 找不到 profile。用法: bash uninstall.sh /path/to/.dsh/profiles/web"
  exit 1
fi

PKG="@local/termux-bridge"
NM="$PROFILE/node_modules"
PKGJSON="$PROFILE/package.json"
PKGDIR="$NM/@local/termux-bridge"
MANIFEST="$PKGDIR/.termux-bridge-install.json"
PY="$(command -v python3 || true)"

if [ -f "$PKGJSON" ] && [ -n "$PY" ]; then
  echo "==> 从 bundles 移除 $PKG"
  "$PY" - "$PKGJSON" "$PKG" << 'PYEOF'
import json, os, sys, tempfile
path, pkg = sys.argv[1], sys.argv[2]
d = json.load(open(path))
bundles = (d.get('dsh', {}).get('profile', {}).get('bundles')) or []
if pkg in bundles:
    d['dsh']['profile']['bundles'] = [b for b in bundles if b != pkg]
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or '.')
    with os.fdopen(fd, 'w') as handle:
        json.dump(d, handle, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    print('   bundles =', d['dsh']['profile']['bundles'])
else:
    print('   (bundles 中未找到,已跳过)')
PYEOF
elif [ -f "$PKGJSON" ]; then
  echo "❌ 没有 python3，动不了 $PKGJSON；先别删包，否则 bundles 里会留下指向不存在包的条目"
  exit 1
fi

if [ -f "$MANIFEST" ]; then
  echo "==> 读到所有权清单，确认包归属"
else
  echo "! 没有所有权清单（可能是手工放置的），仍按规范路径 $PKGDIR 处理"
fi

echo "==> 移除 $PKGDIR"
rm -rf "$PKGDIR"

echo "✅ 卸载完成,重启 dsh 生效。"
echo "   若 Termux 里还留着 agent 脚本，请自行停掉：pkill -f termux-bridge-agent"
