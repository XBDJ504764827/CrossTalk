#!/usr/bin/env bash
# CrossTalk 编译脚本
#
# 用法：
#   ./build.sh setup  首次：下载 SourceMod 1.11 编译器到 .sm111/
#   ./build.sh        编译（自动准备 include；无外部依赖，纯 SM 自带 includes）
#
# 环境变量：
#   SM_DIR             SourceMod 1.11 解压目录（默认项目下 .sm111/）
#   SPCOMP             spcomp 路径（默认 $SM_DIR/addons/sourcemod/scripting/spcomp64）
set -euo pipefail
cd "$(dirname "$0")"

SM_DIR="${SM_DIR:-$(pwd)/.sm111}"
SPCOMP="${SPCOMP:-$SM_DIR/addons/sourcemod/scripting/spcomp64}"

if [[ "${1:-}" == "setup" ]]; then
  echo "Downloading SourceMod 1.11 (latest git build)..."
  mkdir -p "$SM_DIR"
  url="$(curl -s https://sm.alliedmods.net/smdrop/1.11/ | grep -o 'sourcemod-1.11[^"]*-linux.tar.gz' | sort -V | tail -n1)"
  curl -sL -o /tmp/sm111.tar.gz "https://sm.alliedmods.net/smdrop/1.11/$url"
  tar xzf /tmp/sm111.tar.gz -C "$SM_DIR"
  chmod +x "$SM_DIR/addons/sourcemod/scripting/spcomp"* 2>/dev/null || true
  rm -f /tmp/sm111.tar.gz
  echo "SourceMod extracted to $SM_DIR"
  ls -lh "$SM_DIR/addons/sourcemod/scripting/spcomp"* 2>&1 | head -n 5 || true
  exit 0
fi

# Robust spcomp lookup: prefer spcomp64 (32-bit spcomp fails on ubuntu-24.04 without i386 ld)
if [[ ! -x "$SPCOMP" ]]; then
  for cand in \
    "$SM_DIR/addons/sourcemod/scripting/spcomp64" \
    "$SM_DIR/sourcemod/scripting/spcomp64" \
    "$SM_DIR/addons/sourcemod/scripting/spcomp" \
    "$SM_DIR/sourcemod/scripting/spcomp"; do
    if [[ -x "$cand" ]]; then SPCOMP="$cand"; break; fi
  done
fi
if [[ ! -x "$SPCOMP" ]]; then
  echo "spcomp not found: $SPCOMP (also tried fallbacks under \$SM_DIR=$SM_DIR)"
  echo "Run './build.sh setup' first, or set SM_DIR/SPCOMP."
  ls -R "$SM_DIR" 2>&1 | head -n 100 || true
  exit 1
fi

INC_PATHS=()
if [ -d "addons/sourcemod/scripting/include" ]; then
  INC_PATHS+=(-i=addons/sourcemod/scripting/include)
fi

SM_INCLUDE="$SM_DIR/addons/sourcemod/scripting/include"
if [[ ! -d "$SM_INCLUDE" ]] && [[ -d "$SM_DIR/sourcemod/scripting/include" ]]; then
  SM_INCLUDE="$SM_DIR/sourcemod/scripting/include"
fi

mkdir -p addons/sourcemod/plugins

# Strict mode: -E warnings-as-errors (PR/release CI uses STRICT=1)
STRICT_FLAGS=()
if [[ "${STRICT:-0}" == "1" ]]; then
  STRICT_FLAGS=(-E)
fi

"$SPCOMP" addons/sourcemod/scripting/crosstalk.sp \
  "${INC_PATHS[@]}" \
  -i="$SM_INCLUDE" \
  "${STRICT_FLAGS[@]}" \
  -o=addons/sourcemod/plugins/crosstalk.smx

echo "OK: addons/sourcemod/plugins/crosstalk.smx"
