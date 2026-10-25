#!/usr/bin/env bash
# install.sh — termux-bridge（DSH ⇄ Termux 桥接）一键装配脚本
# 用法: bash install.sh [profile目录] [--port <端口>]
#   默认 profile: $DSH_HOME/profiles/web / /workspace/.dsh/profiles/web / /root/projects/.dsh/profiles/web 依次探测
#   默认端口: 8791（插件内 DEFAULT_PORT；这里只把它写进 install.json 备查，不改插件行为）
#
# 与 mobile-pilot / dsh-mobile-adapt 的 install.sh 同形：把 plugin/ 复制进 profile 的
# node_modules/@local/termux-bridge，再把它注册进 profile 的 dsh.profile.bundles。
# 这个包不像 mobile-pilot 那样需要信箱挂载点（它不依赖宿主绑进来的目录），也
# 不需要 node_modules/.bin 命令入口（它的对外形态是 6 个 termux_* 工具 + 一条回环 TCP），
# 所以第 5 步改成写一份 install 元数据，不建命令链接。
#
# 三条讲究（照抄 mobile-pilot 的做法）：
#   1) 先把会被写坏的东西全查一遍（python3 在不在、插件内容齐不齐、profile 结构对不对），再动手写。
#   2) 复制先落阶段目录，语法与文件清单在阶段目录上验过，才动活跃包：旧包整体挪进备份位，
#      新包改名上位；发布之后任何一步失败，把半包撤掉、旧包放回原位。首装（没有旧版）
#      失败时，连本次登记的 bundle 条目一并摘除，不给 loader 留指向不存在包的条目。
#      这条链路不是原子操作：重装或升级前先停 dsh，装完再启动。
#   3) 改用户 profile 的 package.json 一律"写临时文件 + 原子改名"，不就地截断它。
set -e

PROFILE=""
PORT_HINT="8791"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "❌ --port 后面要跟一个端口号"; exit 1; fi
      PORT_HINT="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ ${#ARGS[@]} -gt 0 ] && PROFILE="${ARGS[0]}"

if [ -z "$PROFILE" ]; then
  if [ -n "${DSH_HOME:-}" ] && [ -d "$DSH_HOME/profiles/web" ]; then
    PROFILE="$DSH_HOME/profiles/web"
  elif [ -d "/workspace/.dsh/profiles/web" ]; then
    PROFILE="/workspace/.dsh/profiles/web"
  elif [ -d "/root/projects/.dsh/profiles/web" ]; then
    PROFILE="/root/projects/.dsh/profiles/web"
  fi
fi
if [ -z "$PROFILE" ] || [ ! -d "$PROFILE" ]; then
  echo "❌ 找不到 dsh profile 目录。请手动指定: bash install.sh /path/to/.dsh/profiles/web"
  exit 1
fi

PKG="@local/termux-bridge"
SRC="$(cd "$(dirname "$0")" && pwd)/plugin"
NM="$PROFILE/node_modules"
PKGJSON="$PROFILE/package.json"
# 必需文件清单：安装源、阶段目录与发布结果各核一遍。
# agent/termux-bridge-agent.sh 必须在列 —— 少了它 termux_bootstrap 只能吐空脚本，
# 表现为"工具都在，但手机那边永远连不上"，最难查。
REQUIRED="package.json cordis.patch.yml lib/index.js lib/bridge.js lib/protocol.js lib/local.js agent/termux-bridge-agent.sh"

# --- 0) 先验：任何一项不过都不写东西 ---
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "❌ 注册 bundle 要改 profile 的 package.json，这一步靠 python3；沙盒里没有就先装，别在半途退出"
  exit 1
fi
for f in $REQUIRED; do
  [ -f "$SRC/$f" ] || { echo "❌ 插件内容不完整，缺 $SRC/$f"; exit 1; }
done
[ -f "$PKGJSON" ] || { echo "❌ 找不到 $PKGJSON (profile 结构不兼容)"; exit 1; }
"$PY" - "$PKGJSON" << 'PYEOF'
import json, sys
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
d = json.load(open(sys.argv[1]))
bundles = d.get('dsh', {}).get('profile', {}).get('bundles')
if not isinstance(bundles, list):
    sys.exit('❌ package.json 缺少 dsh.profile.bundles,请确认 profile 结构(需 dsh 0.1.x)')
PYEOF

# --- 0.5) 自愈上次异常退出留下的残留 ---
if [ ! -e "$NM/$PKG" ]; then
  for residue in "$NM/@local"/.termux-bridge-backup.*; do
    [ -e "$residue" ] || continue
    echo "! 活跃包缺失但发现上次遗留的备份 $residue，先复位到活跃位"
    if mv "$residue" "$NM/$PKG"; then
      break
    fi
    echo "❌ 备份复位失败：请人工处理 $residue 后重试"
    exit 1
  done
fi

# --- 事务骨架：阶段目录 → 校验 → 备份 → 替换 → 失败回滚 ---
STAGE="$NM/@local/.termux-bridge-stage.$$"
BACKUP="$NM/@local/.termux-bridge-backup.$$"
if [ -e "$STAGE" ]; then
  STAGE="$STAGE.retry"
  if [ -e "$STAGE" ]; then
    echo "❌ 阶段目录 $STAGE 仍被上次安装的残留占用，请人工清理后重试"
    exit 1
  fi
fi
if [ -e "$BACKUP" ]; then
  BACKUP="$BACKUP.retry"
  if [ -e "$BACKUP" ]; then
    echo "❌ 备份位 $BACKUP 仍被上次安装的残留占用，请人工清理后重试"
    exit 1
  fi
fi
PUBLISHED=""

remove_bundle_entry () {
  "$PY" - "$PKGJSON" "$PKG" << 'PYEOF'
import json, os, sys, tempfile
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
path, pkg = sys.argv[1], sys.argv[2]
d = json.load(open(path))
profile = d.get('dsh', {}).get('profile', {})
bundles = profile.get('bundles')
if isinstance(bundles, list) and pkg in bundles:
    profile['bundles'] = [b for b in bundles if b != pkg]
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or '.')
    with os.fdopen(fd, 'w') as handle:
        json.dump(d, handle, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
PYEOF
}

cleanup () {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$rc" -ne 0 ]; then
    if [ -n "$PUBLISHED" ] && [ ! -e "$BACKUP" ]; then
      # 首装失败：没有旧版可回。半包撤掉之后，bundle 条目会悬空 —— 一并摘除。
      rollback_note=""
      rm -rf "$NM/$PKG" || { rollback_note="$rollback_note
⚠ 残留未清：包目录 $NM/$PKG 仍存在，请手动删除"; }
      remove_bundle_entry || { rollback_note="$rollback_note
⚠ 残留未清：bundle 条目摘除失败，请手动检查 $PKGJSON"; }
      echo "❌ 安装失败，已回滚：本次是首装，半包与 bundle 条目都已摘除，profile 回到安装前的状态" >&2
      [ -n "$rollback_note" ] && printf '%s\n' "$rollback_note" >&2
    else
      # 升级失败（或失败发生在发布之前）：旧包复位后条目照旧指向它，不摘。
      if [ -n "$PUBLISHED" ]; then
        rm -rf "$NM/$PKG" || true
      fi
      if [ -e "$BACKUP" ]; then
        mv "$BACKUP" "$NM/$PKG" || true
        echo "❌ 安装失败，已回滚：$NM/$PKG 恢复为上一版本，旧版保持可用" >&2
      fi
    fi
  elif [ -n "$BACKUP" ] && [ -e "$BACKUP" ]; then
    rm -rf "$BACKUP" || true
  fi
  if [ -n "$STAGE" ]; then
    rm -rf "$STAGE" || true
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_inventory () {
  local root="$1" f
  for f in $REQUIRED; do
    if [ ! -s "$root/$f" ]; then
      echo "❌ 文件清单核对没过：$root/$f 缺失或为空"
      return 1
    fi
  done
}

# --- 1) 复制到阶段目录：校验全部在暂存位上做，不过就不动活跃包 ---
mkdir -p "$NM/@local"
echo "==> 复制插件到阶段目录 $STAGE"
cp -r "$SRC" "$STAGE"

NODE="$(command -v node || true)"
if [ -n "$NODE" ]; then
  # 别把 install.sh / uninstall.sh / agent/*.sh 加进来 —— 那是 sh，会被按 JS 判成语法错。
  for f in lib/index.js lib/bridge.js lib/protocol.js lib/local.js; do
    "$NODE" --check "$STAGE/$f" || { echo "❌ JS 语法检查没过：$STAGE/$f"; exit 1; }
  done
else
  echo "! 沙盒里没有 node，跳过 JS 语法预检；工具一条都不出现时先往这一处查"
fi
bash -n "$STAGE/agent/termux-bridge-agent.sh" || { echo "❌ agent 脚本语法检查没过"; exit 1; }
check_inventory "$STAGE"

# --- 2) 旧包让位 ---
if [ -e "$NM/$PKG" ]; then
  echo "==> 旧包挪进备份位 $BACKUP"
  mv "$NM/$PKG" "$BACKUP"
fi

# --- 3) 发布 ---
echo "==> 发布到 $NM/$PKG"
mv "$STAGE" "$NM/$PKG"
PUBLISHED=1
check_inventory "$NM/$PKG"
chmod +x "$NM/$PKG/agent/termux-bridge-agent.sh"

# --- 4) 注册进 profile bundles ---
echo "==> 注册 bundle: $PKG"
"$PY" - "$PKGJSON" "$PKG" << 'PYEOF'
import json, os, sys, tempfile
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
path, pkg = sys.argv[1], sys.argv[2]
d = json.load(open(path))
bundles = d['dsh']['profile']['bundles']
if pkg not in bundles:
    bundles.append(pkg)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or '.')
    with os.fdopen(fd, 'w') as handle:
        json.dump(d, handle, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
print('   bundles =', bundles)
PYEOF

# --- 5) 所有权清单：卸载只删这里登记过的东西 ---
echo "==> 写所有权清单"
"$PY" - "$NM/$PKG/.termux-bridge-install.json" "$PORT_HINT" $REQUIRED << 'PYEOF'
import json, os, sys, tempfile, time
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
target, port = sys.argv[1], sys.argv[2]
files = sys.argv[3:]
payload = {
    'package': '@local/termux-bridge',
    'files': files,
    'portHint': int(port) if str(port).isdigit() else port,
    'installedAtWall': int(time.time()),
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target) or '.')
with os.fdopen(fd, 'w') as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
os.replace(tmp, target)
PYEOF

echo
echo "+ termux-bridge 装配完成。请重启 dsh 生效。"
echo "+ 重启后 agent 的工具列表里会多出 6 个工具：termux_status / termux_bootstrap / termux_exec /"
echo "  termux_run / termux_push / termux_pull。"
echo "+ 下一步：termux_status 会把在 Termux 里安装 agent 的命令打出来；拿到命令去 Termux 里跑，"
echo "  或者 Termux 里直接: bash <(curl -s http://127.0.0.1:$PORT_HINT/agent) —— 两者等价。"
echo "+ 包的替换不是原子操作（阶段目录→校验→备份→替换）：重装或升级前先停 dsh，装完再启动。"
