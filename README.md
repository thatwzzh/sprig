# 知枝 · Sprig

[![Stars](https://img.shields.io/github/stars/thatwzzh/sprig?style=flat-square&logo=github)](https://github.com/thatwzzh/sprig/stargazers)
[![Downloads](https://img.shields.io/github/downloads/thatwzzh/sprig/total?style=flat-square&logo=github)](https://github.com/thatwzzh/sprig/releases)
[![Release](https://img.shields.io/github/v/release/thatwzzh/sprig?style=flat-square)](https://github.com/thatwzzh/sprig/releases/latest)
[![License](https://img.shields.io/github/license/thatwzzh/sprig?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square)](https://www.apple.com/macos/)

**按一下 `⌥Space`，问一句，答案就出来了。答案里任何文字选中就能「解释」，每次解释都在右侧知识树里长出一张子卡——知识像枝一样长，所以叫「知枝」。**

不是聊天客户端，也不是笔记软件。它只做一件事：**把「问」和「追问」之间的摩擦降到接近零**。

模型来源两条路：填 API Key 直连各家服务商，或者**接一个本机已经装好的 agent**（CodeBuddy Code / Claude Code / Codex / Cursor CLI），直接吃你已有的订阅额度，不用另外买。

### [⬇️ 下载](https://github.com/thatwzzh/sprig/releases)

> 也可以按[从源码构建](#从源码构建)自己打包。

```
┌────────────────────────────────────────────┬──────────────────┐
│  问点什么…                     [智谱 ⌄] [▤]│  知识树       12 │
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

## 快速开始

### 1. 装上

**要求**：macOS 14 (Sonoma) 及以上。

1. 从 [Releases](https://github.com/thatwzzh/sprig/releases) 下载最新的 `.zip`
2. 解压，把 `Sprig.app` 拖进「应用程序」
3. 首次打开会提示「无法验证开发者」——去**系统设置 → 隐私与安全性**点「仍要打开」
4. 菜单栏出现图标后，按 `⌥Space` 唤起面板

### 2. 接入模型或 agent

点菜单栏图标 →「设置…」，或面板右上角的模型胶囊 →「管理模型接入…」。

| 方式 | 适合谁 | 怎么配 |
|---|---|---|
| **API Key** | 手里有各家 key | 设置 →「模型接入」，三段任选：**本地**（Ollama）、**免费**（智谱 GLM）、**自定义**（OpenAI 兼容，填 Base URL + Key + 模型名） |
| **本机 Agent** | 已经装过 CLI 并登录过 | 设置 →「Agent」，会自动列出本机检测到的 CLI。单击标签即可配**默认模型**和**思考强度**，之后用它的订阅额度回答 |

配好之后，在面板的模型胶囊里随时切换。

### 3. 问第一个问题

按 `⌥Space`，在顶部输入框敲问题回车。

### 4. 让知识长起来

- 选中答案里的任意文字 → 点「解释」→ 长出一张子卡
- 带下划线的术语，单击也能直接展开
- 每棵知识树都会投影成一份 Markdown，可以直接用别的工具打开

## 这是什么

一个常驻菜单栏的问答面板。和网页版 AI 的区别在于**知识会积累**：

- 问第一个问题，得到一张根卡
- 看到不认识的词，选中 → `解释`，长出一张子卡
- 子卡再解释，再长——形成一棵可以回溯的知识树

数据全在本机（`~/Documents/Sprig/repository/`），模型调用直连你配置的服务商。

## 快捷问答

| 动作 | 方式 |
|---|---|
| 唤起 / 收起 | `⌥Space`（可改） |
| 提问（新根卡） | 顶部输入框，回车 |
| 基于当前卡追问 | 底部输入框，回车（自动挂成子卡，带上下文） |
| 解释选中文字 | 选中 → `解释` |
| 点术语直接展开 | 答案中带下划线的术语，单击即生成子卡 |
| 返回父卡 | 点面包屑 / `⌘[` |
| 切换模型 / 思考强度 | 输入框右侧的模型胶囊、🧠 图标 |
| 联网搜索开关 | 输入框右侧的地球仪，开着时变蓝 |
| 复制答案 | 选中后 `⌘C` |
| 报错后重试 | 答案末尾的「↻ 重试本次对话」 |
| 收起 | `Esc`，逐层退出 |

## 知识树

每张卡片都记得自己在哪个上下文里诞生，追问时只带相关的祖先节点。

| 动作 | 方式 |
|---|---|
| 开关知识树 | `⌘⇧T`（设置里可重新录制） |
| 搜索 | `⌘F`，匹配标题和回答正文 |
| 重命名 | 单击已选中的节点，或回车；失焦提交，`Esc` 取消 |
| 删除 | hover 节点点垃圾桶，或 `⌘⌫`；模态弹窗确认 |

- 删除是级联的：删一张卡会带着它的所有子卡一起走
- 搜索命中会在节点上标出来，点一下跳到那张卡

## Markdown 同步

**一棵知识树 = 一个 Markdown 文件**，子卡按层级写在同一个文件里：

```markdown
<!-- sprig:root 7D51CB74-... -->

# RAG

RAG 是什么？

RAG（检索增强生成）是结合检索与生成的 AI 方法。

## 幻觉

> 选中：幻觉

这里指模型编造看似合理但错误的事实。

本文由知枝生成。要修改内容，请在应用里改；直接改这个文件不会写回知识库。
```

- 文件写在知识库目录里（默认 `~/Documents/Sprig/repository/`），和 `.cards.json` 同一个文件夹
- **Markdown 是投影，不是源**：在应用里改会重新生成；直接改文件，下次保存会被覆盖
- 首行的 `<!-- sprig:root ... -->` 是标记。删主卡时只删带标记的文件，你自己放进去的笔记不会被碰
- 换知识库目录时，如果目标目录还没有库，会先把当前库复制过去

## 接一个本机 agent

不想用云端模型时，可以把问题交给一个**本机已装的命令行 agent**。这种模式下它会自己读文件、跑工具，知枝只负责提问和展示。

**设置页 → Agent** 会自动列出本机已经装了的 agent，一个名字一个标签，后面的图标是状态：

| 图标 | 含义 |
|---|---|
| ✓ | 握手通过，可以直接用 |
| ! | 没登录——去终端用这个 agent 自己的方式登录一次 |
| ✕ | 失败，悬停看原因 |
| ◌ | 正在测 |
| ○ | 还没测 |

- **测试全部**：逐条握手
- **重新检测**：装、卸 agent 之后点它，不用重开设置
- **＋**：添加自定义 agent（名称 + 启动命令）
- **单击标签**：检测到的条目可以配**默认模型**，自定义的还能改名字和命令。模型要先点「读取」拉一次清单，首项是「跟随 agent 默认」
- **工作目录**：所有 agent 共用，是 agent 读写文件的当前目录

**怎么切**：对话窗口底部的模型胶囊 →「Agent」组。选中期间联网开关会置灰——联不联网由 agent 自己决定。

## 模型接入

| 类别 | 说明 |
|---|---|
| **本地** | Ollama，跑在本机，完全免费 |
| **免费** | 智谱 GLM，填个 Key 就能用 |
| **自定义** | 任何 OpenAI 兼容服务（DeepSeek、OpenAI、火山方舟…） |

### 本地（Ollama）

地址默认 `http://127.0.0.1:11434`，点「同步模型」会列出本机已 pull 的模型。模型只在调用时加载，闲置后自动卸载。

```bash
brew install ollama
ollama pull qwen3:4b-instruct
```

### 免费（智谱 GLM）

| 通道 | 领 Key 的地方 | 模型 |
|---|---|---|
| 智谱 GLM | [bigmodel.cn/usercenter/proj-mgmt/apikeys](https://bigmodel.cn/usercenter/proj-mgmt/apikeys) | `glm-4.7-flash`（唯一的免费型号，其余要充值） |

智谱要先**实名认证**，没实名的账号生成的 Key 用不了。免费型号限流明显，适合试手，不适合当主力。

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

Base URL 填到 `/v1` 或只填域名都行。

### 代理

设置页「代理」一行填 `http://127.0.0.1:7890` 之类，所有出站请求都走它，留空则跟随系统。用 OpenAI、Tavily 这类境外服务时需要。

## 联网搜索

知识问答常需要最新信息，所以接了工具调用——**模型自己决定要不要搜、搜什么**。

配置：设置页 →「联网搜索」→ 打开开关 → 选后端 → 填 Key。

| 后端 | 额度 | 特点 |
|---|---|---|
| **Tavily** | 1000 次/月免费 | 国际搜索，质量好，需要代理 |
| **DeepSeek** | 5 元/1000 次成功请求 | 国内直连，中文结果更强 |

搜索结果折叠成一行，点开才展开：

```
🔍 搜索「今日金价」，参考了 3 条来源      ← 点这行弹出来源菜单
```

点开能看到「标题 · 域名」，悬停显示摘要，点击打开原文。

## 配置与备份

| 项 | 位置 | 默认值 |
|---|---|---|
| 模型接入 | 菜单栏「设置…」→ 模型接入 | 智谱免费 + Ollama |
| Agent | 菜单栏「设置…」→ Agent | 自动列出本机已装的 agent |
| Agent 工作目录 | 设置页 → Agent → 工作目录 | `~/Documents/Sprig/workspaces` |
| 知识库位置 | 菜单栏「设置…」→ 知识库 → 选择… | `~/Documents/Sprig/repository` |
| 阅读主题 | 菜单栏「设置…」→ 阅读主题 | 默认 |
| 代理 | 菜单栏「设置…」→ 联网搜索 → 代理 | 空（跟随系统） |

**API Key 存在本机偏好设置里**（`~/Library/Preferences/com.catking.sprig.app.plist`），**明文**，别把这份配置同步到云端。

```bash
defaults export com.catking.sprig.app ~/sprig-backup.plist
defaults import com.catking.sprig.app ~/sprig-backup.plist
```

## 常见问题

### 提示「无法验证开发者」

系统设置 → 隐私与安全性 → 拉到底，点「仍要打开」。

### 菜单栏图标不见了

系统设置 → **菜单栏** → 拉到底「允许在菜单栏中显示」，确认知枝是开着的。

### 一直 429

免费额度用完了。等一分钟，或者换成付费接入。

### TLS 握手失败

多半是网络到不了目标域名：用 OpenAI / Tavily 这类境外服务时先配好代理，或者把搜索后端换成 DeepSeek。

## 开发者

技术细节都在 [ARCHITECTURE.md](ARCHITECTURE.md)：分层、数据流、上下文装配、ACP 接入、无界面验证。

### 从源码构建

```bash
git clone https://github.com/thatwzzh/sprig.git
cd sprig
./scripts/make-app.sh          # 打包成 build/Sprig.app
open build/Sprig.app
```

```bash
swift build --disable-sandbox  # 本机 SwiftPM 需要（make-app.sh 已处理）
swift test --disable-sandbox   # 单测
./scripts/restart-app.sh       # 退出旧实例 → 打包 → 启动 → 校验只有一个实例
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
Sprig --test-agents                       # 逐条测试已配置的 agent
SPRIG_ACP_TRACE=/tmp/acp.log Sprig --ask "你好"   # 记录 ACP 原始帧
SPRIG_SNAP=/tmp/settings.png Sprig --settings --dump   # 把设置窗口画成 PNG
Sprig --md-demo /tmp/md.png github        # 渲染一段样例 Markdown（default/github/newsprint）
Sprig --chart-demo /tmp/chart.png         # 画两张示例图表
Sprig --html-demo /tmp/html.png           # 渲染一段示例 HTML 并落盘
```

`--selftest` / `--tree-dump` / `--settings --dump` 是为拿不到屏幕录制权限的环境准备的：用数值验证布局，而不是截图。

### 项目结构

```
Sprig/
├── Package.swift                  # SPM 清单
├── Sources/
│   ├── SprigCore/                 # 无 UI 依赖，可单测
│   │   ├── AnswerCard.swift       # 卡片模型（含 searchLog 搜索记录）
│   │   ├── CardStore.swift        # actor，JSON 持久化 + 树操作
│   │   ├── CardMarkdown.swift     # 知识树 → Markdown 投影
│   │   ├── MarkdownLite.swift     # 答案的 Markdown 解析
│   │   ├── ContextAssembler.swift # 上下文预算装配
│   │   ├── TermParser.swift       # ⟦术语⟧ 流式状态机
│   │   ├── Prompt.swift           # 系统提示词
│   │   ├── LLMProvider.swift      # provider 协议 + 错误翻译
│   │   ├── ProviderConfig.swift   # 接入配置模型 + 内置预设
│   │   ├── HTTPClient.swift       # 共享 URLSession（支持自定义代理）
│   │   ├── Tool.swift             # ToolCall / ToolDefinition / ChatEvent
│   │   ├── TimeTool.swift         # get_current_time 工具
│   │   ├── WebSearchTool.swift    # web_search 工具（Tavily / DeepSeek）
│   │   ├── ModelProbe.swift       # 模型探活
│   │   ├── OllamaProvider.swift   # NDJSON 流式
│   │   ├── OpenAICompatibleProvider.swift  # SSE，覆盖所有 /v1/chat/completions
│   │   ├── AcpClient.swift        # ACP agent 进程、会话、登录、三态探活
│   │   ├── AcpCodec.swift         # ACP 线协议（帧解析、启动参数、错误翻译）
│   │   ├── AcpJSON.swift          # 轻量 JSONValue
│   │   ├── AcpPresets.swift       # 内置 agent 预设清单
│   │   └── AgentConfig.swift      # agent 配置模型 + 本机检测
│   └── Sprig/                     # AppKit 层
│       ├── PanelController.swift  # 面板状态机、流式渲染、后台任务
│       ├── PanelContentView.swift # 手写 frame 布局
│       ├── AnswerTextView.swift   # 答案渲染 + 术语/链接
│       ├── MarkdownTheme.swift    # 阅读主题（排版 + 配色）
│       ├── TableImage.swift       # 表格绘制
│       ├── ChartImage.swift       # 图表绘制
│       ├── HtmlSnapshot.swift     # HTML 离屏渲染
│       ├── KnowledgeTreeView.swift# 知识树（搜索/重命名/删除）
│       ├── AgentChipsView.swift   # 设置页的 agent 标签流
│       └── ...
├── Tests/SprigCoreTests/          # 单测：解析/预算/选型/ACP
├── assets/logo/                   # 图标源（SVG + icns 导出脚本）
└── scripts/
    ├── make-app.sh                # 打包 .app
    └── restart-app.sh             # 退出 → 打包 → 启动 → 校验实例数
```

## 已知限制

- **未签名**：首次打开要手动允许，每次重新构建后系统可能再问一次
- **免费模型限流**：外部限制，只能等或换付费接入
- **API Key 明文存储**：见上文，别同步到云端
- **单窗口**：同时只能开一个面板，但多张卡可以在后台并发
- **上下文窗口**：按模型窗口动态分配预算，超长对话会丢弃最早的节点

---

**License**: MIT · **反馈**: [Issues](https://github.com/thatwzzh/sprig/issues)
