# 启赋未来 · 六地区全球出口节点

目标：把 6 台真实 Linux 云服务器加入同一个 Tailscale 网络，在手机/电脑的 Tailscale 客户端里直接切换出口。

节点：

- 🇯🇵 `qifu-jp-tokyo` — AWS `ap-northeast-1`
- 🇸🇬 `qifu-sg-singapore` — AWS `ap-southeast-1`
- 🇦🇪 `qifu-ae-uae` — AWS `me-central-1`
- 🇿🇦 `qifu-za-capetown` — AWS `af-south-1`
- 🇧🇷 `qifu-br-saopaulo` — AWS `sa-east-1`
- 🇨🇭 `qifu-ch-zurich` — AWS `eu-central-2`

## 安全模型

- EC2 不开放 SSH、HTTP、VNC 等入站端口。
- 只放行 UDP 41641，以提高 Tailscale 直连概率。
- Tailscale reusable auth key 不写进仓库，也不直接写进 EC2 user-data。
- 部署期间 auth key 临时存入各区域的 AWS SSM SecureString；6 台节点完成注册并通过端到端验证后自动删除。
- Tailscale API key 仅用于自动批准节点的 exit-node 默认路由。

## 部署前一次性准备

### 1. AWS

准备一个专门用于本项目的 AWS IAM 凭据，不要使用 root 账号。它需要能够操作：EC2、SSM Parameter Store、IAM instance role/profile、STS，以及启用 opt-in Regions 的 AWS Account 权限。

在 GitHub 仓库 Settings → Secrets and variables → Actions 中建立：

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

### 2. Tailscale

在 Tailscale 管理后台生成：

1. 一个 **Reusable + Pre-approved** auth key，保存为 GitHub Secret：`TAILSCALE_AUTH_KEY`
2. 一个 API access token，保存为 GitHub Secret：`TAILSCALE_API_KEY`

不要把这些 key 写进 issue、commit、README 或聊天消息。

## 一键部署

GitHub → Actions → **Deploy Global Tailscale Exit Nodes** → Run workflow。

默认使用 `t3.nano`。部署脚本会：

1. 检查/启用需要的 AWS 区域；
2. 建立最小 EC2 IAM role；
3. 为每个区域建立安全组；
4. 启动 Amazon Linux 2023；
5. 开启 IP forwarding；
6. 安装 Tailscale 并注册为 exit node；
7. 通过 Tailscale API 自动批准默认路由；
8. 在 GitHub runner 上加入同一个 tailnet；
9. 依次切换 6 个 exit node，并访问 AWS 公网 IP 检测服务；
10. 只有当检测到的出口 IP 与对应 EC2 公网 IP 完全一致时，才会输出 PASS；
11. 最后删除区域内临时保存的 Tailscale auth key。

因此工作流绿色成功并不是“机器开出来了”这么简单，而是代表 6 个出口都做过实际端到端流量验证。

## 手机上使用

Android 安装并登录 Tailscale → Exit Node，即可看到六个 `qifu-*` 节点。选择任意一个后，手机普通互联网流量会从该地区的节点出去。

## 停止计费

运行 `global-exit-nodes/destroy.sh`，或直接在各 AWS Region 终止带 `Project=qifu-global-exit` 标签的实例。

注意：AWS EC2、公网 IPv4、磁盘和公网流量都会产生实际费用。本项目不是免费 VPN。
