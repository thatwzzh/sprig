# 知枝 · Sprig

一个 ⌥Space 唤起的 macOS 轻量问答面板：问一句就有答案，答案里的任何文字都能选中追问，
每次追问都会在右侧知识树里长出一张子卡——知识像枝一样长出来，所以叫「知枝」。

不是聊天客户端，也不是笔记软件——它只做一件事：**把「问」和「追问」之间的摩擦降到接近零**。

```
┌────────────────────────────────────────────┬──────────────────┐
│  问点什么…                  [gemini ⌄] [▤]│  知识树       12 │
├────────────────────────────────────────────┼──────────────────┤
│  RAG › 幻觉                                │  ▾ RAG           │
│  RAG 是什么？它解决了什么问题？             │    ▾ 幻觉  ●     │
├────────────────────────────────────────────┼────── ▸ 检索      │
│  RAG（检索增强生成）是结合检索与生成的…     │    ▸ 向量数据库   │
│  它缓解了大语言模型的幻觉问题。             │                  │
│  ┈┈┈ 选中任意文字 → [解释] [追问] ┈┈┈       │                  │
├────────────────────────────────────────────┤                  │
│  基于这张卡继续问…                          │                  │
└────────────────────────────────────────────┴──────────────────┘
```

## 核心交互

| 动作 | 方式 |
|---|---|
| 唤起 / 收起 | `⌥Space`（可改）；在别的桌面按会把面板迁到当前桌面 |
| 提问（新根卡） | 顶部输入框，回车 |
| 基于当前卡追问 | 底部输入框，回车（自动挂成子卡，带上下文） |
| 解释选中文字 | 选中 → `解释`，立刻生成子卡并流式回答 |
| 追问选中文字 | 选中 → `追问`，预填「关于「…」：」 |
| 点术语直接展开 | 答案中带下划线的术语，单击即生成子卡 |
| 返回父卡 | 点面包屑 / `⌘[` |
| 知识树 | `⌘⇧T` 开关（设置里可重新录制）；`⌘F` 聚焦搜索（匹配标题与回答正文） |
| 树内重命名 | 单击已选中的节点，或回车；失焦提交，`Esc` 取消 |
| 树内删除 | hover 节点点垃圾桶，或 `⌘⌫`；模态弹窗确认（默认选中「删除」，← → 切换选中） |
| 菜单栏图标 | 只有三项：打开知枝 / 设置… / 退出 |
| 切换模型 | 输入框右侧的模型胶囊，点开选接入；「管理模型接入…」进设置页 |
| 复制答案 | 选中后 `⌘C` |
| 失焦 / 收起 | `Esc`：先收动作条 → 再收树 → 再取消输入框焦点 → 最后收起（无答案时直接收起） |

## 环境要求

- macOS 14+
- Xcode 16+ / Swift 6（本机验证：Xcode 26.4，Swift 6.3）
- 唯一三方依赖：[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- 模型二选一（也可以都配）：
  - **Google Gemini**：去 [AI Studio](https://aistudio.google.com/apikey) 领一个 API Key，免费层即可跑 `gemini-2.5-flash`
  - **[Ollama](https://ollama.com) 本地**：`ollama pull qwen3:4b-instruct`，完全离线

## 快速开始

```bash
# 1. 编译（这台机器必须带 --disable-sandbox，见「已知限制」）
cd ~/code/Sprig
swift build --disable-sandbox

# 2. 跑测试
swift test --disable-sandbox

# 3. 打包成 .app 并启动
./scripts/make-app.sh
open -a "$PWD/build/Sprig.app"
```

启动后是菜单栏应用（无 Dock 图标），按 `⌥Space` 唤起面板。

首次使用按这条路走：

```bash
# A. 用免费 Gemini（新装默认就是它）
#    菜单栏图标 → 设置… → 模型接入 → 选「Gemini（免费）」→ 粘贴 API Key → 测一下「测试连接」

# B. 用本地 Ollama
ollama pull qwen3:4b-instruct       # 设置页点「拉取」可以直接挑模型
```

面板右下角的模型胶囊随时切换，不用回设置页。

## 模型接入

每条接入独立保存名称、协议、Base URL、API Key、模型名，可以存任意多条，在面板里一键切换。

| 协议 | 适用 | 默认 Base URL |
|---|---|---|
| **Google Gemini** | Gemini 原生接口（`v1beta/...:streamGenerateContent`） | `https://generativelanguage.googleapis.com` |
| **OpenAI 兼容** | OpenAI、DeepSeek、Moonshot、Groq、OpenRouter、智谱、火山方舟、阿里百炼、LM Studio、vLLM… | `https://api.openai.com/v1` |
| **Ollama（本地）** | 本机 Ollama | `http://127.0.0.1:11434` |

Base URL 填到 `/v1` 或只填域名都能识别，`https://x/v1` 不会被拼成 `/v1/v1`。

几个免费额度可以直接填进「OpenAI 兼容」：

| 平台 | Base URL | 模型示例 |
|---|---|---|
| Groq | `https://api.groq.com/openai/v1` | `openai/gpt-oss-120b` |
| OpenRouter | `https://openrouter.ai/api/v1` | `nvidia/nemotron-3-super-120b-a12b:free` |
| 智谱 | `https://open.bigmodel.cn/api/paas/v4` | `glm-4.7-flash` |
| 火山方舟 | `https://ark.cn-beijing.volces.com/api/v3` | 控制台里的接入点 ID |
| 阿里百炼 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-flash` |

> 免费额度变动频繁，具体以各家控制台为准；上面这几个只在写这份文档时核对过。

## 配置

| 项 | 位置 | 默认值 |
|---|---|---|
| 模型接入 | 菜单栏「设置…」→ 模型接入；或在面板点模型胶囊 | 新装：Gemini 免费 / 老用户：Ollama |
| 唤起快捷键 | 菜单栏「设置…」→ 唤起面板快捷键（可录制） | `⌥Space` |
| 知识树快捷键 | 菜单栏「设置…」→ 知识树快捷键（可录制） | `⌘⇧T` |
| 知识库位置 | 菜单栏「设置…」→ 知识库 → 选择… | `~/Documents/Sprig`（文件为 `cards-v2.json`） |

接入配置存在 UserDefaults 的 `providerConfigs`（JSON 数组），API Key 也在里面——**明文保存在本机偏好设置**，没有走 Keychain。这是为了避开未签名应用反复索要钥匙串权限的问题，别把这份配置同步到任何云端。

环境变量 `SPRIG_MODEL` 可临时覆盖模型名，便于命令行调试。

## 命令行调试参数

```bash
Sprig --show                              # 启动即显示面板
Sprig --ask "什么是事件溯源？"             # 启动即提问（可叠加 --tree）
Sprig --tree                              # 启动并展开知识树
Sprig --settings                          # 启动即打开设置
Sprig --settings --dump                   # 打印表单状态后退出（无界面校验）
Sprig --selftest                          # 无界面校验布局/选区/复制，打印数值后退出
Sprig --tree-dump [--tree-filter 关键词]   # 打印树的行数、宽度、命中标记
Sprig --headless "问题"                    # 只跑 provider + 解析器，逐段打印
Sprig --headless-child                    # 跑子卡（上下文解释）prompt
```

`--selftest` / `--tree-dump` / `--settings --dump` 是为「拿不到屏幕录制权限」的环境准备的：用数值验证布局，而不是截图。

## 项目结构

```
Sprig/
├── Package.swift                  # SPM 清单
├── Sources/
│   ├── SprigCore/                 # 无 UI 依赖，可单测
│   │   ├── AnswerCard.swift       # 卡片模型（id/parentID/title/question/answer/selectedText）
│   │   ├── CardStore.swift        # actor，JSON 持久化 + 树操作（children/path/rename/delete）
│   │   ├── ContextAssembler.swift # 上下文预算装配（本地/线上两套 Policy）
│   │   ├── TermParser.swift       # ⟦术语⟧ 流式状态机
│   │   ├── Prompt.swift           # 系统提示词与子卡消息模板
│   │   ├── LLMProvider.swift      # provider 协议（id / displayName / isLocal / stream）
│   │   ├── ProviderConfig.swift   # 一条接入的配置模型 + 内置预设
│   │   ├── OllamaProvider.swift   # NDJSON 流式
│   │   ├── OpenAICompatibleProvider.swift  # SSE 流式，覆盖所有 /v1/chat/completions
│   │   └── GeminiProvider.swift   # Gemini 原生 SSE（systemInstruction / x-goog-api-key）
│   └── Sprig/                     # AppKit UI
│       ├── main.swift / AppDelegate.swift
│       ├── QuickPanel.swift       # 无边框、非激活、可输入的 NSPanel
│       ├── PanelContentView.swift # 手写 frame 布局
│       ├── PanelController.swift  # 状态机：卡片栈 / 流式 / 导航 / 增删改 / 模型切换
│       ├── ModelPickerButton.swift # 输入框右侧的模型胶囊
│       ├── KnowledgeTreeView.swift
│       ├── BreadcrumbBar.swift / QuestionHeaderView.swift
│       ├── SelectionActionBar.swift / ConfirmDialog.swift / PointerCursor.swift
│       ├── AnswerTextView.swift / InputTextView.swift
│       └── Theme.swift / Settings.swift / Hotkey.swift / SettingsWindowController.swift
├── Tests/SprigCoreTests/          # 17 项单元测试
├── scripts/make-app.sh            # 打包成 build/Sprig.app
├── scripts/restart-app.sh         # 退出旧实例 → 重新打包 → 启动，改完代码跑这个
└── ARCHITECTURE.md                # 技术架构文档
```

## 菜单栏图标不见了

macOS 26 (Tahoe) 把第三方菜单栏项收归 ControlCenter 管理，并加了一道授权。按顺序查：

1. **系统设置 → 菜单栏 → 最下面的「允许在菜单栏中显示」**，确认本 app 的开关是开的。
   这是 macOS 26 新加的，按 bundle id 记录。一旦关掉（手滑拖出菜单栏、或系统迁移时默认关闭），
   `NSStatusItem` 就彻底失效——要么 `isVisible = true` 被系统立刻重置回 false，
   要么图标窗口被 ControlCenter 摆到屏幕外（y 为负）。**app 端没有任何 API 能自行恢复。**
2. 确认只有一个实例在跑：`pgrep -f "Contents/MacOS/Sprig" | wc -l`。
   多于 1 就跑 `./scripts/restart-app.sh`，它会把所有实例清干净并校验。
3. 确认没被刘海挡住：菜单栏太挤时图标会被塞到刘海下面，没有任何提示。
   收紧间距可以腾出空间（社区方案，本机未验证效果）：
   `defaults -currentHost write -globalDomain NSStatusItemSpacing -int 6`，然后重新登录。
4. 如果系统设置里根本找不到本 app 的条目，或者打开了仍然不显示——**换一个 bundle id** 是最直接的办法。
   本项目就靠这招解决过一次：`com.catking.sprig` → `com.catking.sprig.app`。
   新 id 在系统里是全新条目，默认允许；`Settings.migrateLegacyDefaultsIfNeeded` 会把旧域的
   快捷键、接入配置、知识库目录整体搬过来，用户无感（迁移后 `defaults read com.catking.sprig.app`
   能看到 `migratedFromBundle` 记录来源）。

**`killall SystemUIServer`、`killall ControlCenter`、重启电脑都不会重置这道授权**——授权是持久化的，
只在系统设置里能改。图标消失先查第 1 条，不要怀疑代码。

## 已知限制

- **`swift build` 必须加 `--disable-sandbox`**：这台机器上 SwiftPM 自身调用 `sandbox-exec` 会被系统拒绝（`sandbox_apply: Operation not permitted`），加参数即可。
- **本地模型默认关掉思维链**：请求体带 `"think": false`，并限制 `num_ctx: 8192`。qwen3 系默认会先吐大段 `thinking`，且默认 262144 上下文会把 9B 模型撑到 20GB、约 30s/token。
- **API Key 明文存在 UserDefaults**：没走 Keychain，未签名应用重签后 Keychain 会反复索权。介意就自己改 `Settings.providerConfigs` 的存取。
- **免费额度随时会变**：Gemini 免费层的模型清单和速率限制在 2026 年调整过多次，429 时先降低频率；Gemini 3.x 系列目前不在免费名单里，默认值锁在 `gemini-2.5-flash`。
- **跨桌面语义**：面板绑定在唤出它的桌面，切桌面不跟随；在别的桌面按热键会把面板迁过来（轮询 `isOnActiveSpace` 确认迁移完成后再锁定）。
- **不做全局划词**：选词只发生在面板自己的答案区。这是有意为之——省掉辅助功能权限、AX 取词、OCR 三件套。
- **菜单栏图标受 macOS 26 授权控制**：详见上面「菜单栏图标不见了」，这不是 app 能自己修的。

## 后续计划

- 兄弟卡差异对比视图
- 接入配置导入 / 导出（目前只在本机 UserDefaults）
- 卡片全文检索（FTS5 / embedding）
- 图标与公证分发
