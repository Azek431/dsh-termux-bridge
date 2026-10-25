#!/usr/bin/env bash
# push-to-github.sh —— 在 Termux（或任何装了 gh 并已 gh auth login 的机器）里，
# 把本仓库一键建到 GitHub 并推送。
#
# 为什么要这个脚本：DSH 跑在 proot 客人里，看不到 Termux 的 ~/.config/gh/oauth_token，
# 客人的 gh 永远是未登录状态。凭据只在 Termux 侧，所以推送必须在 Termux 里执行。
# 仓库本身在 Android 共享存储上，Termux 直接能看见，不需要复制。
#
# 用法（在 Termux 里）：
#   bash push-to-github.sh                  # owner 从 gh 账号推断，仓库名取目录名
#   bash push-to-github.sh Azek431           # 指定 owner
#   bash push-to-github.sh Azek431 dsh-termux-bridge --private
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${1:-}"
NAME="${2:-$(basename "$REPO_DIR")}"
VISIBILITY="${3:---public}"

say() { printf '\033[36m[push]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[push] 失败:\033[0m %s\n' "$*" >&2; exit 1; }

# 本地代理端口是否真的在监听。设备上常见"apt 里配了 127.0.0.1:2080、但代理程序没起来"，
# 这种死代理会让 gh / git 在联网那一步无声挂住（不报错，只是不动），最难查。
probe_port() {
  local host="$1" port="$2"
  (exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1 && return 0
  return 1
}

check_proxy() {
  local bad=0
  local vars="http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
  for v in $vars; do
    local val="${!v:-}"
    [ -n "$val" ] || continue
    local hp="${val#*://}"
    hp="${hp%%/*}"
    local h="${hp%%:*}" p="${hp##*:}"
    case "$val" in *://*) ;; *) h="$hp"; p=80 ;; esac
    [ -n "$p" ] || p=80
    if probe_port "$h" "$p"; then
      say "检测到代理 $v=$val（端口在监听，可用）"
    else
      printf '\033[33m[push] 警告:\033[0m %s=%s 指向的端口没有程序在监听，gh/git 会卡在这里不报错\n' "$v" "$val" >&2
      bad=1
    fi
  done
  local gp
  gp="$(git config --global --get http.proxy 2>/dev/null || true)"
  if [ -n "$gp" ]; then
    local hp="${gp#*://}" h="${hp%%:*}" p="${hp##*:}"
    if ! probe_port "$h" "$p"; then
      printf '\033[33m[push] 警告:\033[0m git http.proxy=%s 的端口没在监听\n' "$gp" >&2
      bad=1
    fi
  fi
  if [ "$bad" = 1 ]; then
    cat >&2 <<'EOF'

  修法（任选）:
    1) 让代理程序起来，再重跑本脚本；
    2) 或者在当前 shell 里先清掉代理再跑:
         unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
         git config --global --unset http.proxy   # 若有
         ./scripts/push-to-github.sh
EOF
    die "存在指向死端口的代理配置，先处理上面的提示"
  fi
}

# --- 0. 前置检查 ---------------------------------------------------------
command -v git >/dev/null 2>&1 || die "没有 git。Termux 里先跑: pkg install git"
command -v gh  >/dev/null 2>&1 || die "没有 gh。Termux 里先跑: pkg install gh"

# 先查代理再联网：死代理是 gh 静默卡死的头号原因，必须先拦下来。
check_proxy

gh auth status >/dev/null 2>&1 || die "gh 还没登录。先跑: gh auth login （选 GitHub.com → HTTPS → 浏览器或粘贴 token）"

# gh auth login 只写 ~/.config/gh/hosts.yml，不会自动把 gh 装成 git 的 credential helper；
# 少了这一步，gh repo create --push 和 git push 都会死在
# "could not read Username for 'https://github.com'"。幂等，重复跑无害。
gh auth setup-git >/dev/null 2>&1 || say "gh auth setup-git 失败，若后面 push 报 could not read Username，手动跑一次 gh auth setup-git"

[ -d "$REPO_DIR/.git" ] || die "这里不是 git 仓库: $REPO_DIR"

# 共享存储是 fuse，属主可能和当前 uid 不一致，git 会报 dubious ownership。
git config --global --get-all safe.directory 2>/dev/null | grep -qx '\*' || {
  say "把仓库目录加进 git safe.directory（fuse 上属主与当前用户不一致，否则 git 拒绝操作）"
  git config --global --add safe.directory "$REPO_DIR"
}

cd "$REPO_DIR"

[ -z "$(git status --porcelain)" ] || say "注意: 工作区有未提交改动，本次只推已提交的内容"

# --- 1. 确定 owner -------------------------------------------------------
if [ -z "$OWNER" ]; then
  OWNER="$(gh api user --jq .login)"
  say "未指定 owner，用当前 gh 账号: $OWNER"
fi
[ -n "$NAME" ] || NAME="$(basename "$REPO_DIR")"
FULL="$OWNER/$NAME"
say "目标仓库: $FULL ($VISIBILITY)"

DESC="DSH ⇄ Termux / 本地双执行面桥接插件：让 DeepSeek Harness 在受限沙盒里也能执行命令、传文件、起 agent"

# --- 2. 建仓（不在这里推，推送单独一步，失败时才能给出准确提示）--------
if gh repo view "$FULL" >/dev/null 2>&1; then
  say "远程仓库已存在，跳过创建"
else
  say "创建远程仓库（不推）"
  gh repo create "$FULL" "$VISIBILITY" --source=. --remote=origin --description "$DESC"
fi

# --- 3. 补 remote（已存在但没 origin 的情况）与推送 ----------------------
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "https://github.com/$FULL.git"
fi
git branch --show-current | grep -qx main || git branch -M main

say "推送到 origin/main"
if ! git push -u origin main; then
  die "推送失败。最常见的原因是 gh 没配成 git 的 credential helper，跑一次
       gh auth setup-git
     然后重跑本脚本即可。也可能是 token 缺 repo scope：
       gh auth refresh -s repo"
fi

# --- 4. 仓库元数据：描述 / 主页 / topics ---------------------------------
say "写仓库描述、主页与 topics"
for t in dsh-plugin dsh deepseek-harness termux android proot bridge remote-exec; do
  gh repo edit "$FULL" --add-topic "$t" >/dev/null 2>&1 || say "（topic $t 未加上，可稍后在网页补）"
done
gh repo edit "$FULL" --description "$DESC" --homepage "https://github.com/deepseek-ai/deepseek-harness" >/dev/null 2>&1 || true

say "完成 → https://github.com/$FULL"
gh repo view "$FULL" --json name,url,visibility,defaultBranchRef --jq "."
