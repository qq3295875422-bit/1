#!/usr/bin/env bash
set -euo pipefail

export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8

VNC_SERVER_BIN="$(command -v tigervncserver || command -v vncserver || true)"
if [ -z "$VNC_SERVER_BIN" ]; then
  echo "TigerVNC server not found. Rebuild the Codespace container." >&2
  exit 1
fi

mkdir -p "$HOME/.vnc"

"$VNC_SERVER_BIN" -kill :1 >/dev/null 2>&1 || true
pkill -f 'websockify.*6902' >/dev/null 2>&1 || true
sleep 1

"$VNC_SERVER_BIN" :1 \
  -geometry 1600x900 \
  -depth 24 \
  -localhost yes \
  -SecurityTypes VncAuth \
  -PasswordFile "$HOME/.vnc/passwd" \
  >"$HOME/.vnc/qifu-vnc.log" 2>&1

nohup websockify \
  --web=/usr/share/novnc \
  0.0.0.0:6902 \
  127.0.0.1:5901 \
  >"$HOME/.vnc/qifu-novnc.log" 2>&1 &

echo $! > "$HOME/.vnc/qifu-novnc.pid"

for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:6902/ >/dev/null 2>&1; then
    echo
    echo "=============================================="
    echo "启赋未来 Cinnamon 云桌面已启动"
    echo "noVNC: http://localhost:6902/"
    echo "VNC 密码: qifu2026"
    echo "在 Codespaces 的 PORTS 面板打开 6902 即可。"
    echo "=============================================="
    exit 0
  fi
  sleep 1
done

echo "noVNC 未能正常启动，请查看 $HOME/.vnc/qifu-novnc.log" >&2
exit 1
