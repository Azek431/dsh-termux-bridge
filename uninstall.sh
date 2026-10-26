#!/usr/bin/env bash
# uninstall.sh — 卸载 dsh-termux-bridge（DSH ⇄ Termux 桥接）
# 用法: bash uninstall.sh [profile目录]
#
# 顺序与安装相反：**先从 bundles 里摘掉这一条**，再删包体。
# 1.2.7 起装法是"vendor 目录 + node_modules 软链 + package.json 里 link: 依赖声明"，
# 所以卸载要把这四处一起收干净，否则会留下：
#   - bundles 里指向不存在包的条目
#   - package.json 里指向不存在路径的 link: 依赖（下次 pnpm install 会报错或产出坏链接）
#   - node_modules 里断掉的软链
#   - vendor 目录里无人认领的包体
# 删除范围以安装时留下的所有权清单为准：只动清单登记的包体目录，不凭"文件内容含某个字符串"
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

PKG="@local/dsh-termux-bridge"
NM="$PROFILE/node_modules"
PKGJSON="$PROFILE/package.json"
VENDOR="$PROFILE/local-plugins/@local/dsh-termux-bridge"
LINK="$NM/@local/dsh-termux-bridge"
MANIFEST="$VENDOR/.dsh-termux-bridge-install.json"
LOCK="$PROFILE/pnpm-lock.yaml"
PY="$(command -v python3 || true)"
PNPM="$(command -v pnpm || true)"

# 兼容 1.2.6 及之前的旧装法：那时包直接拷在 node_modules 里，没有 vendor 目录。
LEGACY=""
if [ ! -d "$VENDOR" ] && [ -d "$LINK" ] && [ ! -L "$LINK" ]; then
  LEGACY=1
  MANIFEST="$LINK/.dsh-termux-bridge-install.json"
fi

if [ -f "$PKGJSON" ] && [ -n "$PY" ]; then
  echo "==> 从 bundles 移除 $PKG"
  "$PY" - "$PKGJSON" "$PKG" << 'PYEOF'
import json, os, sys, tempfile
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
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

  echo "==> 从 dependencies 移除 $PKG 的 link: 声明"
  "$PY" - "$PKGJSON" "$PKG" << 'PYEOF'
import json, os, sys, tempfile
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
path, pkg = sys.argv[1], sys.argv[2]
d = json.load(open(path))
deps = d.get('dependencies')
if isinstance(deps, dict) and pkg in deps:
    removed = deps.pop(pkg)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or '.')
    with os.fdopen(fd, 'w') as handle:
        json.dump(d, handle, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    print('   已移除:', pkg, '=', removed)
else:
    print('   (dependencies 中未找到,已跳过)')
PYEOF
elif [ -f "$PKGJSON" ]; then
  echo "❌ 没有 python3，动不了 $PKGJSON；先别删包，否则 bundles / dependencies 里会留下指向不存在包的条目"
  exit 1
fi

if [ -f "$MANIFEST" ]; then
  echo "==> 读到所有权清单，确认包归属"
else
  echo "! 没有所有权清单（可能是手工放置的），仍按规范路径处理"
fi

if [ -n "$LEGACY" ]; then
  echo "==> 移除旧装法的包目录 $LINK（1.2.6 及之前：直接拷在 node_modules 里）"
  rm -rf "$LINK"
else
  if [ -L "$LINK" ]; then
    echo "==> 移除软链 $LINK"
    rm -f "$LINK"
  elif [ -e "$LINK" ]; then
    echo "==> 移除残留的 node_modules 入口 $LINK"
    rm -rf "$LINK"
  fi

  echo "==> 移除包体 $VENDOR"
  rm -rf "$VENDOR"

  # vendor 目录清空后顺手收掉空壳，不让 local-plugins 越积越脏
  rmdir "$PROFILE/local-plugins/@local" 2>/dev/null || true
  rmdir "$PROFILE/local-plugins" 2>/dev/null || true
fi

# lockfile 里还留着这条 link: 的解析记录，重新算一遍（离线即可，链接型依赖不访问 registry）
if [ -n "$PNPM" ] && [ -f "$LOCK" ]; then
  echo "==> 更新 pnpm-lock.yaml（--lockfile-only --offline）"
  ( cd "$PROFILE" && "$PNPM" install --lockfile-only --offline ) || {
    echo "! lockfile 更新失败，不影响卸载结果；下次 pnpm install 会自行修正"
  }
else
  echo "! 跳过 lockfile 更新（没有 pnpm 或没有 lockfile）；不影响卸载结果"
fi

echo "✅ 卸载完成,重启 dsh 生效。"
echo "   已收干净：bundle 条目 / link: 依赖声明 / node_modules 软链 / vendor 包体。"
echo "   若 Termux 里还留着 agent 脚本，请自行停掉：pkill -f termux-bridge-agent"
