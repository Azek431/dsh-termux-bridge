#!/usr/bin/env bash
# install.sh — dsh-termux-bridge（DSH ⇄ Termux 桥接）一键装配脚本
# 用法: bash install.sh [profile目录] [--port <端口>]
#   默认 profile: $DSH_HOME/profiles/web / /workspace/.dsh/profiles/web / /root/projects/.dsh/profiles/web 依次探测
#   默认端口: 8791（插件内 DEFAULT_PORT；这里只把它写进 install.json 备查，不改插件行为）
#
# 装法（1.2.7 起改成"有声明"的依赖）：
#   包体落在 profile 的 vendor 目录 local-plugins/@local/dsh-termux-bridge；
#   node_modules/@local/dsh-termux-bridge 只是指向它的符号链接；
#   profile 的 package.json 里声明 "@local/dsh-termux-bridge": "link:./local-plugins/@local/dsh-termux-bridge"。
#
# 为什么改：1.2.6 及之前是"手工把目录拷进 node_modules、但不在 package.json 里声明"，
# 那是幽灵包 —— 任何一次 pnpm install 都会把它当多余目录静默剪掉（实测输出 Packages: -1），
# 插件就凭空消失，而且事后极难看出原因。改成 link: 之后它是有声明的依赖，pnpm 不会动它。
# 为什么不用 file: —— 源码在共享存储（fuse）上，pnpm 复制 file: 依赖时会 Permission denied；
# 而且 file: 是复制不是链接，改源码必须重装。所以用 link: 指向 profile 内的 vendor 副本。
#
# 四条讲究：
#   1) 先把会被写坏的东西全查一遍（python3 在不在、插件内容齐不齐、profile 结构对不对），再动手写。
#   2) 复制先落阶段目录，语法与文件清单在阶段目录上验过，才动活跃位置：旧包整体挪进备份位，
#      新包改名上位；发布之后任何一步失败，把半包撤掉、旧包放回原位，并把 package.json 的依赖
#      声明与 pnpm-lock.yaml 一并还原。首装（没有旧版）失败时，连本次登记的 bundle 条目一并摘除，
#      不给 loader 留指向不存在包的条目。
#      这条链路不是原子操作：重装或升级前先停 dsh，装完再启动。
#   3) 改用户 profile 的 package.json 一律"写临时文件 + 原子改名"，不就地截断它。
#   4) 更新 pnpm-lock.yaml 用 --lockfile-only --offline：链接型依赖不需要访问 registry，
#      所以整个安装过程不需要网络。
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

PKG="@local/dsh-termux-bridge"
SRC="$(cd "$(dirname "$0")" && pwd)/plugin"
NM="$PROFILE/node_modules"
PKGJSON="$PROFILE/package.json"
VENDOR_ROOT="$PROFILE/local-plugins/@local"
VENDOR="$VENDOR_ROOT/dsh-termux-bridge"
LINK="$NM/@local/dsh-termux-bridge"
LINK_TARGET="../../local-plugins/@local/dsh-termux-bridge"
DEP_SPEC="link:./local-plugins/@local/dsh-termux-bridge"
LOCK="$PROFILE/pnpm-lock.yaml"
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
PNPM="$(command -v pnpm || true)"
NODE="$(command -v node || true)"
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
if [ ! -e "$VENDOR" ] && [ ! -e "$LINK" ]; then
  for residue in "$VENDOR_ROOT"/.dsh-termux-bridge-backup.*; do
    [ -e "$residue" ] || continue
    echo "! 挂载点缺失但发现上次遗留的备份 $residue，先复位到 vendor 位"
    if mv "$residue" "$VENDOR"; then
      break
    fi
    echo "❌ 备份复位失败：请人工处理 $residue 后重试"
    exit 1
  done
fi

# --- 事务骨架：阶段目录 → 校验 → 备份 → 替换 → 失败回滚 ---
STAGE="$VENDOR_ROOT/.dsh-termux-bridge-stage.$$"
BACKUP="$VENDOR_ROOT/.dsh-termux-bridge-backup.$$"
NMBAK="$NM/@local/.dsh-termux-bridge-nmbackup.$$"
LOCKBAK="$PROFILE/.pnpm-lock.yaml.bridge-bak.$$"
PUBLISHED=""
LINK_MOVED=""
LINK_KIND=""
HAD_PREV=""
DEP_DECLARED=""
LOCK_SAVED=""

_take_slot () {
  # $1 = 期望路径；被占用时追加 .retry，再占用即判失败（echo 出最终路径）
  local p="$1"
  if [ -e "$p" ]; then
    p="$p.retry"
    if [ -e "$p" ]; then
      echo "❌ 临时位 $p 仍被上次安装的残留占用，请人工清理后重试" >&2
      return 1
    fi
  fi
  printf '%s' "$p"
}

mkdir -p "$NM/@local" "$VENDOR_ROOT"
STAGE="$(_take_slot "$VENDOR_ROOT/.dsh-termux-bridge-stage.$$")"
BACKUP="$(_take_slot "$VENDOR_ROOT/.dsh-termux-bridge-backup.$$")"
NMBAK="$(_take_slot "$NM/@local/.dsh-termux-bridge-nmbackup.$$")"

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

declare_dep () {
  # 把 link: 依赖写进 package.json，并把"改动前的值"打到 stdout（供回滚）
  "$PY" - "$PKGJSON" "$PKG" "$DEP_SPEC" << 'PYEOF'
import json, os, sys, tempfile
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
path, pkg, spec = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
deps = d.get('dependencies')
if not isinstance(deps, dict):
    deps = d.setdefault('dependencies', {})
prev = deps.get(pkg) or ''
if prev == spec:
    print(prev)
    raise SystemExit(0)
deps[pkg] = spec
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or '.')
with os.fdopen(fd, 'w') as handle:
    json.dump(d, handle, ensure_ascii=False, indent=2)
os.replace(tmp, path)
print(prev)
PYEOF
}

restore_dep () {
  # $1 = 改动前的值（空串表示原本没有这条依赖 → 删掉）
  "$PY" - "$PKGJSON" "$PKG" "$1" << 'PYEOF'
import json, os, sys, tempfile
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
path, pkg, prev = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
deps = d.get('dependencies')
if not isinstance(deps, dict):
    raise SystemExit(0)
if prev == '':
    if pkg in deps:
        del deps[pkg]
else:
    deps[pkg] = prev
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
    # 包体复原
    if [ -n "$PUBLISHED" ]; then
      rm -rf "$VENDOR" || true
    fi
    if [ -e "$BACKUP" ]; then
      mv "$BACKUP" "$VENDOR" || true
    fi
    # node_modules 入口复原：先撤掉本次建的东西，再把旧的放回去
    # 注意：不能靠"BACKUP 还在不在"判断首装 —— 上面几行已经把 BACKUP 移回 VENDOR 了，
    # 那样无论升级还是首装都会走进首装分支。用 HAD_PREV 显式记下"装之前有没有旧版"。
    if [ -n "$PUBLISHED" ] || [ -n "$LINK_MOVED" ]; then
      if [ -L "$LINK" ]; then rm -f "$LINK" || true; fi
    fi
    if [ -n "$LINK_MOVED" ]; then
      if [ -e "$NMBAK" ]; then
        mv "$NMBAK" "$LINK" || true
      elif [ "$LINK_KIND" = "sym" ]; then
        ln -sfn "$LINK_TARGET" "$LINK" || true
      fi
    fi
    # 依赖声明与 lockfile 复原
    if [ -n "$DEP_DECLARED" ]; then
      restore_dep "${DEP_PREV:-}" || echo "⚠ 依赖声明复原失败，请手动检查 $PKGJSON" >&2
    fi
    if [ -n "$LOCK_SAVED" ] && [ -f "$LOCKBAK" ]; then
      cp "$LOCKBAK" "$LOCK" || true
      rm -f "$LOCKBAK" || true
    fi
    if [ -n "$PUBLISHED" ] && [ -z "$HAD_PREV" ]; then
      # 首装失败：没有旧版可回。半包撤掉之后，bundle 条目会悬空 —— 一并摘除。
      remove_bundle_entry || echo "⚠ bundle 条目摘除失败，请手动检查 $PKGJSON" >&2
      echo "❌ 安装失败，已回滚：本次是首装，半包 / 软链 / 依赖声明 / bundle 条目都已撤掉，profile 回到安装前的状态" >&2
    else
      echo "❌ 安装失败，已回滚：旧版包体、软链、依赖声明与 lockfile 都已还原" >&2
    fi
  else
    [ -e "$BACKUP" ] && rm -rf "$BACKUP" || true
    [ -e "$NMBAK" ] && rm -rf "$NMBAK" || true
    [ -f "$LOCKBAK" ] && rm -f "$LOCKBAK" || true
  fi
  rm -rf "$STAGE" || true
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

# --- 1) 复制到阶段目录：校验全部在暂存位上做，不过就不动活跃位置 ---
echo "==> 复制插件到阶段目录 $STAGE"
cp -r "$SRC" "$STAGE"

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

# --- 2) 旧版本让位（包体与 node_modules 入口分别处理）---
# HAD_PREV：装之前是否已有旧版（决定失败时是"回滚"还是"撤干净"）
# LINK_KIND：旧版在 node_modules 里是软链(sym)还是实体目录(dir)，回滚要按原样还原
if [ -e "$VENDOR" ]; then
  echo "==> 旧包挪进备份位 $BACKUP"
  mv "$VENDOR" "$BACKUP"
  HAD_PREV=1
fi
if [ -L "$LINK" ]; then
  echo "==> 移走旧软链 $LINK"
  rm -f "$LINK"
  LINK_MOVED=1
  LINK_KIND=sym
  HAD_PREV=1
elif [ -e "$LINK" ]; then
  echo "==> 旧版把包直接拷在 node_modules 里（1.2.6 及之前的装法），挪进备份位 $NMBAK"
  mv "$LINK" "$NMBAK"
  LINK_MOVED=1
  LINK_KIND=dir
  HAD_PREV=1
elif [ -n "$HAD_PREV" ]; then
  # 包体在、入口不在：旧版布局本来就该有个软链，回滚时补回来
  LINK_KIND=sym
fi

# --- 3) 发布包体 + 建软链 ---
echo "==> 发布到 $VENDOR"
mv "$STAGE" "$VENDOR"
PUBLISHED=1
check_inventory "$VENDOR"
chmod +x "$VENDOR/agent/termux-bridge-agent.sh" || true

echo "==> 建立 node_modules 软链 $LINK -> $LINK_TARGET"
ln -sfn "$LINK_TARGET" "$LINK"
if [ ! -L "$LINK" ]; then
  echo "❌ 软链没建起来：$LINK"
  exit 1
fi

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

# --- 5) 在 package.json 里声明 link: 依赖（这一步让包不再是"幽灵"）---
echo "==> 声明依赖 $PKG = $DEP_SPEC"
DEP_PREV="$(declare_dep)"
DEP_DECLARED=1
echo "   原值: ${DEP_PREV:-（无，本次新增）}"

# --- 6) 更新 pnpm-lock.yaml（离线既够也安全：链接型依赖不访问 registry）---
if [ -n "$PNPM" ]; then
  if [ -f "$LOCK" ]; then
    cp "$LOCK" "$LOCKBAK"
    LOCK_SAVED=1
  fi
  echo "==> 更新 pnpm-lock.yaml（--lockfile-only --offline）"
  ( cd "$PROFILE" && "$PNPM" install --lockfile-only --offline )
else
  echo "! 没找到 pnpm，跳过 lockfile 更新。"
  echo "  已声明的 link: 依赖不会进 lockfile，下次有 pnpm 时请补一条："
  echo "  ( cd $PROFILE && pnpm install --lockfile-only --offline )"
fi

# --- 7) 所有权清单：卸载只删这里登记过的东西 ---
echo "==> 写所有权清单"
"$PY" - "$VENDOR/.dsh-termux-bridge-install.json" "$PORT_HINT" "$VENDOR" "$LINK" "$LINK_TARGET" "$DEP_SPEC" $REQUIRED << 'PYEOF'
import json, os, sys, tempfile, time
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass
target, port, vendor, link, link_target, dep_spec = sys.argv[1:7]
files = sys.argv[7:]
payload = {
    'package': '@local/dsh-termux-bridge',
    'layout': 'vendor-link',
    'vendor': vendor,
    'link': link,
    'linkTarget': link_target,
    'depSpec': dep_spec,
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
echo "+ dsh-termux-bridge 装配完成。请重启 dsh 生效。"
echo "+ 布局：包体在 $VENDOR，node_modules 里是指向它的软链，package.json 里已声明 link: 依赖"
echo "  —— 以后 pnpm install / pnpm add 都不会再把它当多余目录剪掉。"
echo "+ 重启后 agent 的工具列表里会多出 6 个工具：termux_status / termux_bootstrap / termux_exec /"
echo "  termux_run / termux_push / termux_pull。"
echo "+ 下一步：termux_status 会把在 Termux 里安装 agent 的命令打出来；拿到命令去 Termux 里跑，"
echo "  或者 Termux 里直接: bash <(curl -s http://127.0.0.1:$PORT_HINT/agent) —— 两者等价。"
echo "+ 包的替换不是原子操作（阶段目录→校验→备份→替换）：重装或升级前先停 dsh，装完再启动。"
