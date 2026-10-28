# 知枝 · Sprig

[![Stars](https://img.shields.io/github/stars/thatwzzh/sprig?style=flat-square&logo=github)](https://github.com/thatwzzh/sprig/stargazers)
[![Downloads](https://img.shields.io/github/downloads/thatwzzh/sprig/total?style=flat-square)](https://github.com/thatwzzh/sprig/releases)
[![License](https://img.shields.io/github/license/thatwzzh/sprig?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square)](https://www.apple.com/macos/)

**按一下 `⌥Space`，问一句，答案就出来了。答案里任何文字都能选中「解释」，每次解释都在右侧知识树里长出一张子卡——知识像枝一样长，所以叫「知枝」。**

不是聊天客户端，也不是笔记软件。它只做一件事：**把「问」和「追问」之间的摩擦降到接近零**。

### [⬇️ 下载](https://github.com/thatwzzh/sprig/releases)

> 还没发布安装包时，可以按[从源码构建](#从源码构建)自己打包，两分钟。

```
┌────────────────────────────────────────────┬──────────────────┐
│  问点什么…                  [gemini ⌄] [▤]│  知识树       12 │
├────────────────────────────────────────────┼──────────────────┤
│  RAG › 幻觉                                │  ▾ RAG           │
│  RAG 是什么？它解决了什么问题？             │    ▾ 幻觉  ●     │
├────────────────────────────────────────────┼────── ▸ 检索      │
│  RAG（检索增强生成）是结合检索与生成的…     │    ▸ 向量数据库   │
│  它缓解了大语言模型的幻觉问题。             │                  │
│  ┈┈┈ 选中任意文字 → [解释] ┈┈┈              │                  │
├────────────────────────────────────────────┤                  │
│  基于这张卡继续问…                          │                  │
└────────────────────────────────────────────┴──────────────────┘
```

## 这是什么

一个常驻菜单栏的问答面板。和网页版 AI 的区别在于**知识会积累**：

- 问第一个问题，得到一张根卡
- 看到不认识的词，选中 → `解释`，长出一张子卡
- 子卡再解释，再长——形成一棵可以回溯的知识树
- 每张卡都记得自己在哪个上下文里诞生，追问时只带相关的祖先节点，不会一次性塞进整段对话

数据全在本机（`~/Documents/Sprig/cards-v2.json`），不上传任何地方。模型调用直连你配置的服务商。

## 安装

**要求**：macOS 14 (Sonoma) 及以上。Apple Silicon 和 Intel 都能跑。

1. 从 [Releases](https://github.com/thatwzzh/sprig/releases) 下载最新的 `.zip`
2. 解压，把 `Sprig.app` 拖到「应用程序」
3. 首次打开会提示"无法验证开发者"——去**系统设置 → 隐私与安全性**，点「仍要打开」

   > 应用没有做代码签名（个人项目），这一步绕不过。介意的话可以自己编译。

4. 打开后菜单栏会出现一枝嫩芽图标，按 `⌥Space` 唤起面板

## 第一次配置：先给它一个能用的模型

**没有配置模型时，面板会显示一条提示，点一下就能进设置页。**

设置页分三类接入，从上到下：

| 类别 | 说明 |
|---|---|
| **本地** | Ollama，跑在本机，完全免费 |
| **免费** | 智谱 GLM / OpenRouter / Gemini，填个 Key 就能用 |
| **自定义** | 任何 OpenAI 兼容服务（DeepSeek、OpenAI、火山方舟…） |

填完 Key 点「测试连接」，看到「✓ 连接正常」就能用了。

---

### ⚠️ 关于免费模型：能用，但别指望它稳定

这是必须先说清楚的一件事。**目前所有"免费"的 LLM 通道都在限流**，包括我们内置的这三个：

| 通道 | 免费额度 | 实际体验 |
|---|---|---|
| 智谱 GLM-4.7-Flash | 官方标称永久免费、不限 token | **实测成功率约 1/3**，多数请求返回「访问量过大」 |
| Gemini 免费层 | 约 10–15 次/分钟 | 频繁 429，且**国内需要代理**才能连上 |
| OpenRouter 免费模型 | 共享上游池，约 20 次/分钟 | 高峰期大量 429 |

**它们适合干什么**：装好之后试一下这个 app 是不是你想要的，问几个问题看看交互顺不顺手。

**不适合干什么**：当日常主力。你会在"这个功能挺好用"和"怎么又 429 了"之间反复横跳。

**为什么会这样**：免费额度是各家用来拉新的，容量池子就那么大，所有人共享。一旦某个模型开始被大量调用，排队就是必然的。

### 那到底该用什么

按你的使用频率选：

| 你的情况 | 建议 | 成本 |
|---|---|---|
| 只是想试试 | 智谱或 Gemini 免费层，**多试几次** | 0 |
| 每天都在用 | **DeepSeek**（自定义接入） | 按 token 计费，充 10 元能用几个月 |
| 不想联网 / 数据敏感 | **本地 Ollama** | 0，代价是占内存 |
| 已经在用 OpenAI | OpenAI API（自定义接入） | 按 token 计费 |

**DeepSeek 是最推荐的付费选项**：国内直连不用代理、按量计费没有"每分钟多少次"的墙、`deepseek-chat` 一次问答大约几分钱。配置方式见[自定义接入](#自定义任何-openai-兼容服务)。

**本地 Ollama 是唯一"绝对稳定且免费"的方案**：

```bash
brew install ollama          # 或从 ollama.com 下载
ollama pull qwen3:4b-instruct   # 2.5 GB，24G 内存的机器很轻松
```

配好之后即使断网也能用。

## 核心交互

| 动作 | 方式 |
|---|---|
| 唤起 / 收起 | `⌥Space`（可改）；在别的桌面按会把面板迁到当前桌面 |
| 提问（新根卡） | 顶部输入框，回车 |
| 基于当前卡追问 | 底部输入框，回车（自动挂成子卡，带上下文） |
| 解释选中文字 | 选中 → `解释`，立刻生成子卡并流式回答 |
| 点术语直接展开 | 答案中带下划线的术语，单击即生成子卡 |
| 返回父卡 | 点面包屑 / `⌘[` |
| 知识树 | `⌘⇧T` 开关（设置里可重新录制）；`⌘F` 聚焦搜索（匹配标题与回答正文） |
| 树内重命名 | 单击已选中的节点，或回车；失焦提交，`Esc` 取消 |
| 树内删除 | hover 节点点垃圾桶，或 `⌘⌫`；模态弹窗确认 |
| 切换模型 | 输入框右侧的模型胶囊，点开选接入 |
| 联网搜索开关 | 输入框右侧的地球仪，开着时变蓝 |
| 复制答案 | 选中后 `⌘C` |
| 收起 | `Esc`：先收树 → 再取消输入框焦点 → 最后收起 |

**几个顺手的设计**：

- 答案里的术语会自动加下划线，点一下就能展开——这是主路径
- 面板展开知识树时会占满 944pt，收起时回到 680pt
- 流式输出时切换到别的卡，那张卡会在后台继续生成，切回去能看到完整内容
- 面板高度流式期间只增不减，不会因为换行忽高忽低

## 模型接入详解

### 本地（Ollama）

只填地址和模型名。地址默认 `http://127.0.0.1:11434`，点「同步模型」会自动列出本机已 pull 的模型。

> **注意**：pull 很多模型不会同时吃内存。模型只在被调用时加载，闲置 10 分钟后自动卸载。真正占磁盘的是权重文件（一个 9B 模型约 10 GB）。

### 免费（三个通道）

| 通道 | 领 Key 的地方 | 模型 |
|---|---|---|
| 智谱 GLM | [bigmodel.cn/usercenter/proj-mgmt/apikeys](https://bigmodel.cn/usercenter/proj-mgmt/apikeys) | `glm-4.7-flash`（唯一免费的，其余型号要充值） |
| OpenRouter | [openrouter.ai/keys](https://openrouter.ai/keys) | 定价为 0 且能对话的，当前 9 个 |
| Gemini | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | 只列 `flash` 系，需要代理 |

**智谱要实名认证**——没实名的账号生成的 Key 用不了。这一步最容易漏。

**同步模型**：点按钮会拉取该通道的可用模型，**只保留探测通过的**（404 / 403 / 400 的直接剔除，429 保留——那是暂时的）。探测只对 OpenRouter 做：智谱和 Gemini 逐个探会把免费额度打光。

### 自定义（任何 OpenAI 兼容服务）

填名称、Base URL、Key、模型名，可以加任意多条：

| 平台 | Base URL | 模型示例 |
|---|---|---|
| **DeepSeek** | `https://api.deepseek.com` | `deepseek-chat`（快）/ `deepseek-reasoner`（推理）|
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| 火山方舟（豆包） | `https://ark.cn-beijing.volces.com/api/v3` | 控制台的接入点 ID |
| 阿里百炼 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-flash` |
| Groq | `https://api.groq.com/openai/v1` | `openai/gpt-oss-120b` |
| LM Studio | `http://127.0.0.1:1234/v1` | 加载的模型名 |

Base URL 填到 `/v1` 或只填域名都能识别，`https://x/v1` 不会被拼成 `/v1/v1`。

### 代理

**设置页「联网搜索」下面有一行「代理」**，填 `http://127.0.0.1:7890` 之类，所有出站请求都走它。留空则跟随系统设置。

什么时候需要：用 Gemini、OpenAI、OpenRouter 这些境外服务时。国内服务（DeepSeek、智谱）不需要。

## 联网搜索

知识问答常需要最新信息，所以接了工具调用——**模型自己决定要不要搜、搜什么**，不是每次提问都塞一堆结果进去。

配置：设置页 →「联网搜索」→ 打开开关 → 选后端 → 填 Key。

| 后端 | 额度 | 特点 |
|---|---|---|
| **Tavily** | 1000 次/月免费 | 国际搜索，质量好，需要代理 |
| **DeepSeek** | 5 元/1000 次成功请求 | 国内直连，中文结果更强 |

**搜索结果显示成一行**：

```
🔍 搜索「今日金价」，参考了 3 条来源      ← 点这行弹出来源菜单
```

点开能看到「标题 · 域名」，hover 显示摘要，点击打开原文。设计成折叠的是因为把来源链接铺在正文里会打断阅读。

**什么时候会搜**：只有涉及时事、当前价格、最新版本号、或者模型确实不知道的冷门事实时才搜。问"什么是设计模式"这类稳定知识，模型直接凭知识回答——搜了反而会拿到一堆营销文。

## 常见问题

### 菜单栏图标不见了

这是 macOS 26 的一个已知问题。系统给第三方菜单栏项加了独立授权，关掉后 app 端**没有任何 API 能恢复**。

排查顺序：

1. **系统设置 → 菜单栏 → 拉到底「允许在菜单栏中显示」**，确认 Sprig 是开着的
2. 确认只跑了一个实例：`pgrep -f "Sprig.app/Contents/MacOS/Sprig"` 应该只有一行
3. 菜单栏图标太多时会被挤到屏幕外，关掉几个不用的
4. 以上都不行 → 换 bundle id（等于让系统重新分配授权），但配置需要重新迁移

`killall SystemUIServer`、重启电脑都**不会**重置这个授权。

### 一直 429

免费额度用完了。等一分钟，或者换成付费接入。app 会自动重试一次并尝试换个模型，但额度是真没了。

### TLS 握手失败

两个可能：**目标域名被网络拦截**（最常见），或者证书真的有问题。

- 用 Gemini / OpenAI / OpenRouter 时，先在设置里配好代理
- Tavily 在国内直连不通，必须走代理；或者换成 DeepSeek 搜索后端

「证书有问题」这个提示容易误导——在国内环境，九成是网络拦截。

### 面板高度忽高忽低

已经修了。如果还遇到，说明是窗口 resize 的时序问题，可以在设置里把知识树收起来再展开一次。

### 答案文字被右侧裁掉

也修了（文本容器宽度少算 inset 导致）。如果还遇到，告诉我你的字号设置。

## 配置项

| 项 | 位置 | 默认值 |
|---|---|---|
| 模型接入 | 菜单栏「设置…」→ 模型接入 | 首次启动：智谱 / Gemini 免费 |
| 唤起快捷键 | 菜单栏「设置…」→ 唤起面板快捷键 | `⌥Space` |
| 知识树快捷键 | 菜单栏「设置…」→ 知识树快捷键 | `⌘⇧T` |
| 知识库位置 | 菜单栏「设置…」→ 知识库 → 选择… | `~/Documents/Sprig` |
| 代理 | 菜单栏「设置…」→ 联网搜索 → 代理 | 空（跟随系统） |

**API Key 存在本机偏好设置里**（`~/Library/Preferences/com.catking.sprig.app.plist`），**明文**。没有走 Keychain，因为未签名应用反复索要钥匙串权限很烦。别把这份配置同步到云端。

想备份或迁移配置：

```bash
defaults export com.catking.sprig.app ~/sprig-backup.plist
defaults import com.catking.sprig.app ~/sprig-backup.plist
```

## 给开发者

技术细节都在 [ARCHITECTURE.md](ARCHITECTURE.md)：分层、数据流、上下文装配、窗口焦点、并发模型、踩过的坑。

### 从源码构建

```bash
git clone https://github.com/thatwzzh/sprig.git
cd sprig
./scripts/make-app.sh          # 打包成 build/Sprig.app
open build/Sprig.app
```

**注意**：某些环境下 `swift build` 需要加 `--disable-sandbox`（SwiftPM 调 `sandbox-exec` 被系统拒绝）。`make-app.sh` 里已经处理了。

跑测试：

```bash
swift test --disable-sandbox
```

改完代码重新部署（会先优雅退出旧实例、再打包、再启动、最后校验只有一个实例）：

```bash
./scripts/restart-app.sh
```

### 命令行调试参数

```bash
Sprig --show                              # 启动即显示面板
Sprig --ask "什么是事件溯源？"             # 启动即提问
Sprig --tree                              # 启动并展开知识树
Sprig --settings                          # 启动即打开设置
Sprig --settings --dump                   # 打印表单状态后退出
Sprig --selftest                          # 无界面校验布局/选区/复制
Sprig --tree-dump [--tree-filter 关键词]   # 打印树的行数、宽度、命中
Sprig --headless "问题"                    # 只跑 provider + 解析器
Sprig --probe-free                        # 同步免费模型并打印探活结果
```

`--selftest` / `--tree-dump` / `--settings --dump` 是为**拿不到屏幕录制权限**的环境准备的：用数值验证布局，而不是截图。

### 项目结构

```
Sprig/
├── Package.swift                  # SPM 清单
├── Sources/
│   ├── SprigCore/                 # 无 UI 依赖，可单测
│   │   ├── AnswerCard.swift       # 卡片模型（含 searchLog 搜索记录）
│   │   ├── CardStore.swift        # actor，JSON 持久化 + 树操作
│   │   ├── ContextAssembler.swift # 上下文预算装配
│   │   ├── TermParser.swift       # ⟦术语⟧ 流式状态机
│   │   ├── Prompt.swift           # 系统提示词
│   │   ├── LLMProvider.swift      # provider 协议 + 错误翻译
│   │   ├── ProviderConfig.swift   # 接入配置模型 + 内置预设
│   │   ├── FreeModelCatalog.swift # OpenRouter 免费清单 + 偏好排序
│   │   ├── HTTPClient.swift       # 共享 URLSession（支持自定义代理）
│   │   ├── Tool.swift             # ToolCall / ToolDefinition / ChatEvent
│   │   ├── TimeTool.swift         # get_current_time 工具
│   │   ├── WebSearchTool.swift    # web_search 工具（Tavily / DeepSeek）
│   │   ├── OllamaProvider.swift   # NDJSON 流式
│   │   ├── OpenAICompatibleProvider.swift  # SSE，覆盖所有 /v1/chat/completions
│   │   └── GeminiProvider.swift   # Gemini 原生 SSE + function calling
│   └── Sprig/                     # AppKit 层
│       ├── PanelController.swift  # 面板状态机、流式渲染、后台任务
│       ├── PanelContentView.swift # 手写 frame 布局
│       ├── AnswerTextView.swift   # 答案渲染 + 术语/链接
│       └── ...
├── Tests/SprigCoreTests/          # 65 个单测，覆盖解析/预算/选型
└── scripts/
    ├── make-app.sh                # 打包 .app
    └── restart-app.sh             # 退出 → 打包 → 启动 → 校验实例数
```

## 已知限制

- **未签名**：首次打开要手动允许，每次重新构建后系统可能再问一次
- **免费模型限流**：见上文，这是外部限制，app 只能重试和降级
- **API Key 明文存储**：见上文，权衡后的选择
- **单窗口**：同时只能开一个面板，但多张卡可以在后台并发（最多 8 条连接）
- **上下文窗口**：按模型窗口动态分配预算，超长对话会丢弃最早的节点

## 后续计划

- [ ] 代码签名 + 公证，去掉首次打开的确认步骤
- [ ] 卡片导出为 Markdown / 分享图
- [ ] 全局快捷键支持更多组合
- [ ] 知识树的多选与批量整理

---

**License**: MIT · **反馈**: [Issues](https://github.com/thatwzzh/sprig/issues)
