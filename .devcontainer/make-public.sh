#!/usr/bin/env bash
set -euo pipefail

if [ -z "${CODESPACE_NAME:-}" ]; then
  echo "当前环境不是 GitHub Codespaces，无法自动设置公网端口。" >&2
  exit 1
fi

gh codespace ports visibility 6902:public -c "$CODESPACE_NAME"
echo "6902 已请求设置为 Public。"
echo "公网地址格式：https://${CODESPACE_NAME}-6902.app.github.dev/"
