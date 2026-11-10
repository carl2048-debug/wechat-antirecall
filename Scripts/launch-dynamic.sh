#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-/Applications/WeChat.app}"
CLI="$ROOT/.build/debug/wechat-antirecall"
RUNTIME="$ROOT/.build/debug/libWeChatAntiRecallRuntime.dylib"

if [[ ! -x "$CLI" || ! -f "$RUNTIME" ]]; then
  echo "请先在项目目录运行 swift build（无需运行测试）。" >&2
  exit 1
fi

exec "$CLI" launch --app "$APP" --runtime-dylib "$RUNTIME"
