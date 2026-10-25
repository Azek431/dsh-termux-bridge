#!/usr/bin/env bash
# push-with-token.sh —— 用一枚现成的 GitHub token 直接建仓并推送，全程不交互。
#
# 用途：设备上 gh auth login 的浏览器/device code 交互不可用时（Termux 前台切来切去、
# 剪贴板不通），用一个 PAT 一把推完。token 从环境变量 GH_TOKEN 或标准输入读取。
#
# 用法：
#   GH_TOKEN=github_pat_xxx bash scripts/push-with-token.sh
#   echo github_pat_xxx | bash scripts/push-with-token.sh
#   GH_TOKEN=xxx bash scripts/push-with-token.sh Azek431 dsh-termux-bridge --private
#
# 只依赖 curl + git，不需要 gh。token 不落盘、不进 shell history（推荐从 stdin 喂）。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${1:-}"
NAME="${2:-$(basename "$REPO_DIR")}"
VISIBILITY="${3:---public}"

say() { printf '\033[36m[push]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[push] 失败:\033[0m %s\n' "$*" >&2; exit 1; }

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
  if [ ! -t 0 ]; then TOKEN="$(cat)"; fi
fi
TOKEN="$(printf '%s' "$TOKEN" | tr -d '\r\n \t')"
[ -n "$TOKEN" ] || die "没有 token。用 GH_TOKEN=xxx 传入，或 echo xxx | bash $0"

command -v curl >/dev/null || die "缺 curl：pkg install curl"
command -v git  >/dev/null || die "缺 git：pkg install git"

API="https://api.github.com"
auth_api() { curl -sS -H "Authorization: Bearer $TOKEN" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$@"; }

say "校验 token ..."
LOGIN="$(auth_api "$API/user" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("login") or "")' 2>/dev/null || true)"
if [ -z "$LOGIN" ]; then
  auth_api "$API/user" >&2
  die "token 无效或已过期"
fi
say "已认证为 ${LOGIN}"
[ -n "$OWNER" ] || OWNER="$LOGIN"
FULL="$OWNER/$NAME"

case "$VISIBILITY" in --private|-p) PRIVATE=true ;; *) PRIVATE=false ;; esac

# ---- 1. 建仓（已存在则跳过）----
code="$(auth_api -o /dev/null -w '%{http_code}' "$API/repos/$FULL")"
if [ "$code" = 200 ]; then
  say "仓库 $FULL 已存在，跳过创建"
else
  say "创建仓库 $FULL (private=$PRIVATE) ..."
  body="$(python3 -c 'import json,os;print(json.dumps({"name":os.environ["N"],"private":os.environ["P"]=="true","description":os.environ["D"],"homepage":"https://github.com/deepseek-ai/deepseek-harness","has_issues":True,"has_wiki":False,"auto_init":False}))' \
    N="$NAME" P="$PRIVATE" D="DSH ⇄ Termux 双执行面桥接插件：让 DeepSeek Harness 在受限沙盒里也能执行命令、传文件、起 agent")"
  out="$(auth_api -X POST "$API/user/repos" -d "$body")"
  echo "$out" | grep -q '"full_name"' || { echo "$out" >&2; die "建仓失败"; }
  say "仓库已建：$FULL"
fi

# ---- 2. 推代码 ----
cd "$REPO_DIR"
git config --global --get-all safe.directory 2>/dev/null | grep -qx '\*' || git config --global --add safe.directory '*'
git rev-parse --git-dir >/dev/null 2>&1 || die "$REPO_DIR 不是 git 仓库"
git remote get-url origin >/dev/null 2>&1 && git remote set-url origin "https://github.com/$FULL.git" \
  || git remote add origin "https://github.com/$FULL.git"
git branch -M main
say "推送 main ..."
# 用一次性 credential helper 传 token，避免写进 .git/config 或 URL
git -c credential.helper= -c "credential.helper=!f() { echo username=x-access-token; echo password=$TOKEN; }; f" \
    push -u origin main || die "推送失败（token 需要有 repo 权限）"
say "推送完成"

# ---- 3. 补元数据 ----
say "补 topics 与 homepage ..."
for t in dsh-plugin dsh deepseek-harness termux android proot bridge remote-exec; do
  auth_api -X PUT "$API/repos/$FULL/topics" \
    -d "$(auth_api "$API/repos/$FULL/topics" | python3 -c "
import sys,json,os
cur=json.load(sys.stdin).get('names',[])
t=os.environ['T']
print(json.dumps({'names':sorted(set(cur+[t]))}))" T="$t")" >/dev/null || true
done

echo
say "完成 → https://github.com/$FULL"
echo "  git 已绑定 origin：$(git remote get-url origin)"
