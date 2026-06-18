# Tang Agent Android

一个类似你截图里的 Android AI 客户端初版骨架。

## 当前初版已经包含

- 对话首页：顶部模型名、侧边栏、消息列表、输入框、发送按钮
- 侧边栏：收藏、电脑、项目、今天、技能、设置入口
- 模型服务设置：API Key、Base URL、默认模型
- DeepSeek / OpenAI-Compatible Chat Completions 调用
- 本地保存：设置和当前对话消息会保存到 SharedPreferences
- 技能页占位：先展示“需要先配置工作区”，后续可接入文件目录、工具调用、MCP

## 默认接口

默认按 DeepSeek/OpenAI 兼容格式调用：

```text
POST {baseUrl}/chat/completions
Authorization: Bearer {apiKey}
```

默认值：

```text
baseUrl = https://api.deepseek.com
model = deepseek-chat
```

## 下一步建议

1. 换成 Room 数据库，支持多个会话和搜索历史。
2. 加 SSE 流式输出。
3. 加模型服务列表：DeepSeek、OpenAI、Qwen、Kimi、GLM、豆包。
4. 加 Bot 管理：每个 Bot = system prompt + model + tools。
5. 加 Agent 工作区：用 Android Storage Access Framework 选择本地目录。
6. 加 Skills 工具系统：读文件、写文件、搜索文件、联网搜索。

## 打开方式

用 Android Studio 打开仓库根目录，等待 Gradle Sync，然后运行 `app`。

如果 Gradle 版本提示过旧，按 Android Studio 提示升级 Android Gradle Plugin 即可。
