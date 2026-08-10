#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y universe
sudo apt-get update
sudo apt-get install -y \
  cinnamon cinnamon-session cinnamon-l10n \
  tigervnc-standalone-server tigervnc-common tigervnc-tools \
  novnc websockify dbus-x11 x11-xserver-utils xauth \
  locales language-pack-zh-hans fonts-noto-cjk fonts-wqy-microhei \
  fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-config-qt \
  libreoffice libreoffice-gtk3 libreoffice-l10n-zh-cn \
  falkon gedit gnome-terminal file-roller evince \
  curl wget git vim nano htop unzip p7zip-full ca-certificates

sudo locale-gen zh_CN.UTF-8 en_US.UTF-8
sudo update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh

mkdir -p "$HOME/.vnc" "$HOME/.config/fcitx5"

cat > "$HOME/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
export XDG_CURRENT_DESKTOP=X-Cinnamon
export XDG_SESSION_DESKTOP=cinnamon2d
export DESKTOP_SESSION=cinnamon2d
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export LIBGL_ALWAYS_SOFTWARE=1
fcitx5 -d --replace >/tmp/qifu-fcitx5.log 2>&1 &
exec dbus-run-session -- cinnamon-session-cinnamon2d
EOF
chmod +x "$HOME/.vnc/xstartup"

cat > "$HOME/.config/fcitx5/profile" <<'EOF'
[Groups/0]
Name=默认
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=默认
EOF

VNC_PASSWD_BIN="$(command -v tigervncpasswd || command -v vncpasswd || true)"
if [ -z "$VNC_PASSWD_BIN" ]; then
  echo "TigerVNC password utility not found" >&2
  exit 1
fi
printf '%s\n' 'qifu2026' | "$VNC_PASSWD_BIN" -f > "$HOME/.vnc/passwd"
chmod 600 "$HOME/.vnc/passwd"

sudo tee /usr/share/novnc/index.html >/dev/null <<'EOF'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="0; url=/vnc.html?autoconnect=true&resize=scale">
  <title>启赋未来 Cinnamon 云桌面</title>
</head>
<body>正在进入云桌面……</body>
</html>
EOF

if ! grep -q 'QIFU_CLOUD_DESKTOP' "$HOME/.profile" 2>/dev/null; then
  cat >> "$HOME/.profile" <<'EOF'
# QIFU_CLOUD_DESKTOP
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
EOF
fi

echo "Cinnamon 中文云桌面组件安装完成。"
