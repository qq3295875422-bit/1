# 启赋未来 · FlClash 六地区真实节点

这套工程只面向 FlClash / Mihomo。用户手机不需要安装 Tailscale。

最终配置 `qifu-global.yaml` 包含：

- 🇯🇵 东京 — `ap-northeast-1`
- 🇸🇬 新加坡 — `ap-southeast-1`
- 🇦🇪 阿联酋 — `me-central-1`
- 🇿🇦 南非 — `af-south-1`
- 🇧🇷 巴西 — `sa-east-1`
- 🇨🇭 瑞士 — `eu-central-2`
- ♻️ 自动选择
- 🚀 手动节点选择

## 协议

服务器运行 sing-box Shadowsocks 2022：

- cipher: `2022-blake3-aes-128-gcm`
- TCP 443
- UDP 443
- 每个地区独立随机 16-byte Base64 密钥

服务器不开放 SSH、VNC、HTTP 管理端口。

## 真正的验收标准

部署不是看到 EC2 Running 就算完成。

GitHub runner 会针对六个节点逐个启动本地 sing-box 客户端，通过该 Shadowsocks 节点访问 `checkip.amazonaws.com`。只有实际观察到的公网出口 IPv4 与对应 EC2 公网 IPv4 完全一致才输出 `PASS`。

六个节点全部 PASS 后才生成 FlClash 配置。

## 密钥交付

仓库是 Public，因此包含节点密码的 `qifu-global.yaml` 不会直接 commit，也不会上传为公开 artifact。

工作流会：

1. 在 runner 内生成完整配置；
2. 用随机 AES-256 key 加密配置；
3. 再使用任务专用 RSA 公钥加密 AES key；
4. 只把密文写入 `.qifu-flclash-encrypted.json`；
5. ChatGPT 读取密文后在当前任务环境中解密；
6. 解密成功并校验 SHA-256 后删除仓库中的临时密文；
7. 最终把 `qifu-global.yaml` 作为聊天附件直接交给用户导入 FlClash。

因此节点密码不会出现在公开 commit、Actions 日志或公开 artifact 中。

## 需要的 GitHub Actions Secrets

只需要 AWS：

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

IAM 凭据必须具备创建/查询/删除 EC2、VPC、Security Group、Subnet、Internet Gateway、读取 SSM 公共 AMI Parameter，以及对 opt-in Region 执行 Account Region 启用/查询所需的权限。

不要把 AWS Secret 发到聊天、Issue、README 或 commit 中。

## 部署

设置好两个 Secret 后，修改或创建：

`flclash-global/.deploy-trigger`

即可触发 `Deploy FlClash Six Region Nodes`。

也可以在 GitHub Actions 页面手动 Run workflow。

## 停止计费

运行 `Destroy FlClash Six Region Nodes`，或修改：

`flclash-global/.destroy-trigger`

销毁脚本会终止带 `Project=qifu-flclash-global` 标签的实例并清理本项目创建的 VPC 网络资源。
