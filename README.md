# 知枝 · Sprig

一个 ⌥Space 唤起的 macOS 轻量问答面板：问一句就有答案，答案里的任何文字都能选中追问，
每次追问都会在右侧知识树里长出一张子卡——知识像枝一样长出来，所以叫「知枝」。

不是聊天客户端，也不是笔记软件——它只做一件事：**把「问」和「追问」之间的摩擦降到接近零**。

```
┌────────────────────────────────────────────┬──────────────────┐
│  问点什么…                          [▤]   │  知识树       12 │
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
| 复制答案 | 选中后 `⌘C` |
| 失焦 / 收起 | `Esc`：先收动作条 → 再收树 → 再取消输入框焦点 → 最后收起（无答案时直接收起） |

## 环境要求

- macOS 14+
- Xcode 16+ / Swift 6（本机验证：Xcode 26.4，Swift 6.3）
- [Ollama](https://ollama.com) 本地运行，默认模型 `qwen3:4b-instruct`
- 唯一三方依赖：[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)

## 快速开始

```bash
# 1. 准备本地模型
ollama pull qwen3:4b-instruct

# 2. 编译（这台机器必须带 --disable-sandbox，见「已知限制」）
cd ~/code/ConceptLens
swift build --disable-sandbox

# 3. 跑测试
swift test --disable-sandbox

# 4. 打包成 .app 并启动
./scripts/make-app.sh
open -a "$PWD/build/Sprig.app"
```

启动后是菜单栏应用（无 Dock 图标），按 `⌥Space` 唤起面板。

## 配置

| 项 | 位置 | 默认值 |
|---|---|---|
| 模型 | 菜单栏「设置…」→ 本地模型 | `qwen3:4b-instruct` |
| Ollama 地址 | `defaults write com.catking.sprig ollamaBaseURL "http://127.0.0.1:11434"` | `http://127.0.0.1:11434` |
| 唤起快捷键 | 菜单栏「设置…」→ 唤起面板快捷键（可录制） | `⌥Space` |
| 知识树快捷键 | 菜单栏「设置…」→ 知识树快捷键（可录制） | `⌘⇧T` |
| 知识库位置 | 菜单栏「设置…」→ 知识库位置 → 选择… | `~/Documents/Sprig`（文件为 `cards-v2.json`） |

环境变量 `SPRIG_MODEL` 可临时覆盖模型，便于命令行调试。

## 命令行调试参数

```bash
Sprig --show                              # 启动即显示面板
Sprig --ask "什么是事件溯源？"             # 启动即提问（可叠加 --tree）
Sprig --tree                              # 启动并展开知识树
Sprig --selftest                          # 无界面校验布局/选区/复制，打印数值后退出
Sprig --tree-dump [--tree-filter 关键词]   # 打印树的行数、宽度、命中标记
Sprig --headless "问题"                    # 只跑 provider + 解析器，逐段打印
Sprig --headless-child                    # 跑子卡（上下文解释）prompt
```

`--selftest` / `--tree-dump` 是为「拿不到屏幕录制权限」的环境准备的：用数值验证布局，而不是截图。

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
│   │   ├── OllamaProvider.swift   # NDJSON 流式
│   │   └── LLMProvider.swift      # provider 协议
│   └── Sprig/                     # AppKit UI
│       ├── main.swift / AppDelegate.swift
│       ├── QuickPanel.swift       # 无边框、非激活、可输入的 NSPanel
│       ├── PanelContentView.swift # 手写 frame 布局
│       ├── PanelController.swift  # 状态机：卡片栈 / 流式 / 导航 / 增删改
│       ├── KnowledgeTreeView.swift
│       ├── BreadcrumbBar.swift / QuestionHeaderView.swift
│       ├── SelectionActionBar.swift / ConfirmDialog.swift / PointerCursor.swift
│       ├── AnswerTextView.swift / InputTextView.swift
│       └── Theme.swift / Settings.swift / Hotkey.swift / SettingsWindowController.swift
├── Tests/SprigCoreTests/          # 17 项单元测试
├── scripts/make-app.sh            # 打包成 build/Sprig.app
└── ARCHITECTURE.md                # 技术架构文档
```

## 已知限制

- **`swift build` 必须加 `--disable-sandbox`**：这台机器上 SwiftPM 自身调用 `sandbox-exec` 会被系统拒绝（`sandbox_apply: Operation not permitted`），加参数即可。
- **本地模型默认关掉思维链**：请求体带 `"think": false`，并限制 `num_ctx: 8192`。qwen3 系默认会先吐大段 `thinking`，且默认 262144 上下文会把 9B 模型撑到 20GB、约 30s/token。
- **跨桌面语义**：面板绑定在唤出它的桌面，切桌面不跟随；在别的桌面按热键会把面板迁过来（轮询 `isOnActiveSpace` 确认迁移完成后再锁定）。
- **不做全局划词**：选词只发生在面板自己的答案区。这是有意为之——省掉辅助功能权限、AX 取词、OCR 三件套。
- 当前只接了 Ollama；provider 协议已留好，接线上模型只需新增一个 `LLMProvider` 实现。

## 后续计划

- 兄弟卡差异对比视图
- Gemini / 线上 provider
- 卡片全文检索（FTS5 / embedding）
- 图标与公证分发
