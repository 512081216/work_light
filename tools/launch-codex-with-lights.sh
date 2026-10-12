#!/bin/sh
set -eu
bridge_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
is_running() {
  if pgrep -x "$1" >/dev/null; then return 0; else bridge_status=$?; fi
  if [ "$bridge_status" -ne 1 ]; then
    echo '无法确认桌面程序已退出；为避免干扰正在执行的任务，已停止启动。请在系统终端执行。' >&2
    exit 2
  fi
  return 1
}
if is_running ChatGPT || is_running Codex; then
  echo '请先保存并结束其他任务，再手动完全退出 Codex/ChatGPT，然后重新执行此脚本。' >&2
  exit 1
fi
bridge_app=/Applications/ChatGPT.app
if [ ! -d "$bridge_app" ]; then bridge_app=/Applications/Codex.app; fi
test -d "$bridge_app"
open --env "CODEX_CLI_PATH=$bridge_dir/codex-runtime-bridge.sh" -a "$bridge_app"
