# 启赋未来 Cinnamon 云桌面（GitHub Codespaces）

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/qq3295875422-bit/1?quickstart=1)

这个仓库用于在 GitHub Codespaces 中自动部署一个可以通过浏览器访问的中文 Cinnamon 云桌面。

## 已配置

- Ubuntu 24.04
- Cinnamon 2D 桌面
- 简体中文界面与中文字体
- Fcitx5 + 拼音输入法
- TigerVNC
- noVNC（浏览器访问）
- LibreOffice
- Falkon 浏览器
- 文本编辑器、终端、压缩工具等常用软件

## 使用方法

1. 点击上方 **Open in GitHub Codespaces** 按钮，或在仓库里点击 **Code → Codespaces → Create codespace on main**。
2. Codespace 创建后会自动安装桌面环境并启动 noVNC。
3. 打开底部 **PORTS** 面板。
4. 找到端口 **6902 / Cinnamon noVNC**，点击浏览器图标打开。
5. VNC 密码：`qifu2026`

端口默认是 Private：通过公网 HTTPS 地址访问，但需要先登录本人的 GitHub 账号。

如果需要把链接改成任何知道 URL 的人都能打开，在 PORTS 面板右键 6902 → **Port Visibility → Public**。

也可以在 Codespaces 终端执行：

```bash
bash .devcontainer/make-public.sh
```

公开地址格式通常为：

```text
https://<CODESPACE_NAME>-6902.app.github.dev/
```

## 重启桌面

```bash
bash .devcontainer/start-desktop.sh
```

## 日志

```bash
cat ~/.vnc/qifu-vnc.log
cat ~/.vnc/qifu-novnc.log
```

> 安全提示：Public 端口不再受 GitHub 登录保护。只需要自己使用时，建议保持 Private。
