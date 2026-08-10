#!/usr/bin/env bash
set -euo pipefail

if [ -z "${CODESPACE_NAME:-}" ]; then
  echo "当前环境不是 GitHub Codespaces，无法自动设置公网端口。" >&2
  exit 1
fi

VNC_PASSWD_BIN="$(command -v tigervncpasswd || command -v vncpasswd || true)"
if [ -z "$VNC_PASSWD_BIN" ]; then
  echo "TigerVNC password utility not found" >&2
  exit 1
fi

NEW_PASSWORD="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(4))
PY
)"

printf '%s\n' "$NEW_PASSWORD" | "$VNC_PASSWD_BIN" -f > "$HOME/.vnc/passwd"
chmod 600 "$HOME/.vnc/passwd"

bash .devcontainer/start-desktop.sh

gh codespace ports visibility 6902:public -c "$CODESPACE_NAME"

echo
echo "=============================================="
echo "6902 已请求设置为 Public。"
echo "公网地址：https://${CODESPACE_NAME}-6902.app.github.dev/"
echo "新的 VNC 密码：$NEW_PASSWORD"
echo "请保存这个密码；每次再次运行本脚本都会生成新密码。"
echo "=============================================="
