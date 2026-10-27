# Sprig（知枝）技术架构

> 面向维护者。解释「为什么这么写」，而不是复述代码。
> 交互与使用说明见 [README.md](README.md)。

## 1. 目标与约束

| 目标 | 具体化 | 由此产生的约束 |
|---|---|---|
| 轻 | 包 < 15MB、常驻 < 120MB、热键到可见 < 50ms | 全原生 AppKit，不引 WebView / Electron；面板常驻内存不重建 |
| 快 | 输入即答，首 token 尽量早 | 流式渲染 + 40ms 节流；模型关思维链、限上下文 |
| 低摩擦 | 唤起 → 问 → 追问 全程不换窗口 | 单窗口内完成输入、阅读、选词、分支、导航 |
| 低权限 | 不申请辅助功能 / 屏幕录制 | 选词只发生在自己的 `NSTextView` 里，不做全局划词 |

上下文：面板是 `nonactivating` 的，打字时不会抢走当前 App 的焦点；它是一个菜单栏应用（`LSUIElement`）。

## 2. 分层

```
┌─────────────────────────────────────────────────────────────┐
│  Sprig（UI / AppKit）                                       │
│                                                              │
│  AppDelegate ── 状态栏菜单 / 最小主菜单 / 热键注册             │
│      │                                                       │
│  PanelController（@MainActor 状态机）                         │
│    ├── stack: [Node]        当前卡片路径（面包屑 = 它的标题）   │
│    ├── 流式任务 / 节流刷新 / 选区动作条                        │
│    └── 导航：父卡、树跳转、重命名、删除                         │
│      │                                                       │
│  QuickPanel（NSPanel）  PanelContentView（手写 frame 布局）    │
│    ├── InputTextView      顶部输入（新根卡）                   │
│    ├── BreadcrumbBar      路径（祖先可点回跳）                  │
│    ├── QuestionHeaderView 当前卡的问题原文                     │
│    ├── AnswerTextView     答案渲染 + 原生选词 + 链接命中        │
│    ├── InputTextView      底部输入（基于当前卡追问）            │
│    └── KnowledgeTreeView  树：搜索/高亮/重命名/删除             │
└───────────────────────────┬─────────────────────────────────┘
                            │ 只依赖协议与纯数据
┌───────────────────────────▼─────────────────────────────────┐
│  SprigCore（无 UI，可单测）                                 │
│                                                              │
│  LLMProvider(protocol) ← Ollama / OpenAI 兼容 / Gemini         │
│  TermParser        ⟦术语⟧ 流式状态机                          │
│  ContextAssembler  按 Policy 预算拼上下文                     │
│  Prompt            系统提示词 / 子卡消息模板                   │
│  AnswerCard        卡片模型（树节点）                          │
│  CardStore(actor)  JSON 持久化 + children/path/rename/delete  │
└─────────────────────────────────────────────────────────────┘
```

UI 层不直接读文件，Core 层不 import AppKit——这条边界让「解析器 / 上下文 / 存储」可以在无窗口环境跑测试。

## 3. 模块职责

| 文件 | 职责 | 关键点 |
|---|---|---|
| `QuickPanel` | 面板窗口 | `.nonactivatingPanel + .borderless`、`canBecomeKey = true`、`level = .floating` |
| `PanelController` | 全局状态机 | 唯一持有 `stack`、流式任务、当前卡片 ID |
| `PanelContentView` | 布局 | 手写 frame；圆角由普通 `NSView` 裁切，毛玻璃作为子视图 |
| `AnswerTextView` | 答案区 | `NSTextView`（非 SwiftUI）以获得原生选词与链接点击 |
| `InputTextView` | 输入 | 回车提交 / Esc 回调 / IME 候选框定位修正 |
| `BreadcrumbBar` | 路径 | 祖先可点回跳；不再带兄弟切换器 |
| `KnowledgeTreeView` | 树 | `NSOutlineView`；搜索过滤 + 命中标记 + 内联改名 + hover 删除；无横向滚动 |
| `SelectionActionBar` | 选区动作条 | 面板内浮层，避免独立窗口抢 key window |
| `ConfirmDialog` | 删除确认 | 自绘圆角卡片，无图标；`NSApp.runModal` 应用级 modal，居中在面板上；← → 切换选中，默认选中「删除」 |
| `PointerCursor` | 指针样式 | 可点击控件 hover 显示手型光标（`PointerButton`） |
| `ModelPickerButton` | 模型切换 | 输入框右侧胶囊，固定宽度避免文字换行导致布局抖动 |
| `TermParser` | 流式解析 | 未闭合持有、换行/超长降级、嵌套重开 |
| `ContextAssembler` | 上下文 | 本地/线上两套预算策略 |
| `CardStore` | 存储 | `actor`，JSON 原子写入；删除级联 |
| `ProviderConfig` | 接入配置 | 名称/协议/Base URL/API Key/模型，Codable 存 UserDefaults |
| `OllamaProvider` | 模型 | NDJSON；`think:false`、`num_ctx:8192`、`keep_alive:30m` |
| `OpenAICompatibleProvider` | 模型 | SSE；`/v1/chat/completions`，Base URL 自动归一化 |
| `GeminiProvider` | 模型 | 原生 SSE；`systemInstruction` + `x-goog-api-key` |
| `FreeModelCatalog` | 免费模型目录 | OpenRouter `/api/v1/models`，按 `pricing` 为 0 筛免费；无需 Key。挑模型用「排除表 + 偏好权重」，权重看中文与指令遵循，不按上下文长度 |

## 4. 数据流

### 4.1 提问 → 流式渲染

```
顶部输入回车
  → createRootCard(question)
      新建 AnswerCard(parentID: nil) 压入 stack
      persistCurrentCard()（先落空答案，保证树结构立刻存在）
  → startStreaming([system(answer), user(question)])
      URLSession.bytes → NDJSON 逐行 → yield(content)
  → consume(chunk)
      stack.last.raw += chunk
      TermParser.consume(chunk) → [.text | .term]
      攒进 pendingSegments，40ms 节流
  → flushPendingSegments()
      answerView.append(...)（术语加 .link 属性）
      重新测量高度 → applyHeights → scrollToBottom
  → finishStreaming()
      parser.flush() 收尾 → persistCurrentCard()
```

三层缓冲的原因：网络 chunk 粒度是「几个字」，直接逐块改 `textStorage` 会触发高频重排；
40ms 合并一次，视觉上仍是流式，但布局次数降一个量级。

### 4.2 术语解析状态机

```
normal ──⟦──▶ inTerm ──⟧──▶ normal（产出 .term）
                  │
                  ├─ 换行 / 长度 > 40 / 再次遇到 ⟦ ──▶ fallback
                  └─ 流结束 ──▶ flush() 按普通文本吐出（丢掉标记）

fallback：把已缓冲内容当正文输出，并吞掉后到的 ⟧
```

不做事后 NLP 抽取的原因：多一次模型调用、多一份延迟，且流式期间术语无法「边出边可点」。
`⟦⟧` 不用 `[[ ]]`，是为了不和 Markdown 链接语法打架。

### 4.3 选词 → 子卡

```
拖选/双击选中文字
  → textViewDidChangeSelection → updateSelectionBar()
      选区 ≤120 字 且与答案区相交 → 浮出 [解释][追问]
  → 解释：createChildCard(parentID: 当前卡, selection: 选中文本, question: "")
      1) 截断栈到父卡位置（避免在祖先链之外分叉）
      2) ContextAssembler.context(path: 祖先链, policy: .forProvider(id))
      3) 新卡压栈 → 流式（system(contextual) + user(上下文 + 片段)）
  → 追问：预填「关于「…」：」，提交时同样走 createChildCard
```

### 4.4 导航

`stack: [Node]` 是唯一真源：面包屑标题、问题条、答案内容都由它派生。
跳转（树节点）时用 `CardStore.path(to:)` 重建整个栈，而不是只改当前节点——
这样面包屑永远和内容一致。

每张卡记忆自己的滚动位置（`Node.scroll`），返回父卡时恢复。

## 5. 数据模型与持久化

```swift
struct AnswerCard {
    id: UUID
    parentID: UUID?      // nil = 根卡
    title: String        // 面包屑/树上的短标题
    question: String     // 发给模型的问题（子卡可能为空）
    answer: String       // 含 ⟦⟧ 的原始回答，用于重放渲染
    selectedText: String?
    createdAt: Date
}
```

存储：默认 `~/Documents/Sprig/cards-v2.json`（设置里可换目录），`CardStore` 是 `actor`，
写入用 `.atomic`。切换目录时若目标库不存在，会先把当前库（或更早的
`~/Documents/a/cards-v2.json` / `~/Library/Application Support/ConceptLens/cards-v2.json`）复制过去，
避免卡片"消失"。
删除是级联的（先求后代闭包，再一起移除）。

**为什么不是 GRDB**：当前量级在几百张卡，JSON 足够且零依赖。接口刻意保持
`upsert / all / card / children / path / rename / delete` 七个方法——换成 GRDB + FTS5 时只替换实现，
调用方不动。触发升级的信号是「需要全文检索」或「卡片上千」。

## 6. 上下文装配

`ContextAssembler.Policy` 按「本地 / 线上」分两套预算（单位：字符）。
判断依据是 `LLMProvider.isLocal`——Ollama 为 true，其余为 false。用布尔值而不是 provider id，
是因为接入配置的主键是 UUID，按字符串匹配会在用户新增接入后失效：

| 参数 | 本地（Ollama） | 线上 |
|---|---|---|
| 总预算 | 2400 | 12000 |
| 当前回答 | 1200 | 6000 |
| 直接父级 | 600 | 3000 |
| 更远祖先 | 0（只留标题+问题） | 800 |
| 祖先层数 | 4 | 12 |

分配顺序是「由近到远」：当前卡必须完整（它是被解释的对象），父级给因果，更远的只留问题行。
本地砍得更狠，因为 8k 窗口还要留给回答，且小模型对长输入更敏感。

输出形如：

```
【当前回答】（幻觉）
问题：解释「幻觉」
<answer>

【上级上下文】
- RAG：RAG 是什么？它解决了什么问题？
  <父级回答摘要>
```

明确不塞兄弟卡（同层分支会互相干扰）、不塞整棵树。
升级路径：卡片 > 200 或出现跨分支引用 → embedding 检索 top-k；深度大且质量下降 → 每卡懒生成摘要。

## 7. 窗口、焦点与跨桌面

| 决策 | 选择 | 理由 |
|---|---|---|
| 窗口类型 | `NSPanel` + `.nonactivatingPanel` + `.borderless` | 能成为 key 接收输入，但不激活 App；`.titled` 的 28pt 标题栏会吞掉输入框点击 |
| 层级 | `.floating` | 压住普通窗口，不盖系统弹窗 |
| 跨桌面 | `[.managed, .fullScreenAuxiliary]` | 绑定唤出它的桌面；切桌面不跟随 |
| 唤出迁移 | 临时 `.moveToActiveSpace` + 轮询 `isOnActiveSpace` | 在别的桌面按热键要迁过来；确认迁移完成再锁回 `.managed` |
| 失焦 | 沉底（`level = .normal` + `orderBack`），不隐藏 | 用户切 App 时面板仍在，不打断回来继续看 |
| 菜单跟踪 | `NSMenu.didBegin/EndTracking` 计数屏蔽 | 右键菜单期间面板会 resignKey，否则菜单和面板一起消失 |
| 删除确认 | 自绘 `ConfirmDialog` + `NSApp.runModal` | 应用级 modal；`NSAlert` 会固定占一块图标区，去掉图标也留空白 |
| `Esc` | 动作条 → 树 → 取消输入焦点 → 收起 | 两级语义，先失焦再关闭 |
| `⌘C/V/X/A` | 局部 keydown 监视 + 最小主菜单 | `LSUIElement` 没有菜单栏，标准编辑动作没人转发 |

`toggle()` 的语义：面板可见但 `isDemoted` 或 `!isOnActiveSpace` 时是**拉回**，不是收起。

## 8. 布局系统

不用 Auto Layout：流式输出时每 40ms 改一次高度，约束求解在这个频率下会抖。

高度公式（无答案时只有输入区）：

```
total = inputHeight(46…96)
      + breadcrumb(28) + questionHeight(22…46) + 1
      + answerHeight(30…420) + 1
      + bottomHeight(40…84)
```

- 左侧问答区固定 `680`；展开树时窗口加宽 `264`，问答区宽度不变。
- 文本高度一律用 `NSLayoutManager.usedRect(for:)` 实测，再 `setFrame`。
- 圆角：`PanelContentView`（普通 `NSView`）负责 `cornerRadius + masksToBounds`，
  `NSVisualEffectView` 降级为铺满的子视图并加 `maskImage`——它的背景层不跟随 `layer.cornerRadius`。

## 9. 并发模型

- UI 全部 `@MainActor`；`PanelController` 是唯一状态所有者。
- 流式用 `Task { @MainActor ... }`，`for try await` 挂起时不阻塞主线程。
- 取消：切换卡片/导航前 `cancelStreaming()`，会把已收到的部分回答落盘。
- `CardStore` 是 `actor`，调用方 `await`；写盘在 actor 内串行。
- 树刷新是异步的：`reload()` 拉全量卡片后重建 `TreeNode`，卡片量小，不值得做增量。

## 10. 关键取舍

| 场景 | 选了 | 没选 | 原因 |
|---|---|---|---|
| 答案渲染 | `NSTextView` | SwiftUI `Text` | 需要原生拖选、选区回调、自定义命中 |
| 术语抽取 | prompt 内联标记 | 事后 NLP/小模型 | 省一次调用，流式期间即可点击 |
| 卡片存储 | JSON | GRDB/FTS5 | 量级小，接口已预留替换 |
| 确认框 | 内嵌条 | `NSAlert` | sheet 抢 key window、露直角 |
| 划词入口 | 面板内选词 | 全局 AX 取词 + OCR | 省掉辅助功能权限与三级降级链 |
| 输入语义 | 顶部=新根卡，底部=子卡 | 统一一个输入框 | 两个动作语义不同，混在一起用户无法预测 |

## 11. 踩过的坑（都在代码里有注释）

1. **`NSVisualEffectView` 圆角无效**：背景层是方的，直接设 `cornerRadius` 会露四角。→ 外层容器裁切 + `maskImage`。
2. **`NSAlert` 的图标去不掉**：设 `icon = nil` 会回退到 App 图标，换空图仍占一块图标区（新版系统还排在标题上方）。→ 自绘 `ConfirmDialog`，`NSApp.runModal` 应用级模态，level 提到 `.modalPanel`（否则被 `.floating` 面板压住）。
3. **`NSMenu` 打开导致面板消失**：菜单跟踪期间 `resignKey`。→ `didBegin/EndTracking` 计数屏蔽。
4. **`NSOutlineView` 不自动撑满**：作为 `documentView` 时 frame 不会跟随 scroll view，必须手算宽高。
5. **`NSScrollView` 把 documentView 撑宽 32pt**：树会冒出横向滚动，行尾 hover 按钮也会落进裁切区。→ 在 `frame` / `setFrameSize` 两处把宽度夹到 clip 宽度；按钮按 `visibleRightEdge` 定位，标题占满按钮左侧并以省略号收尾。
6. **`.titled` 标题栏吞点击**：顶部 28pt 变成拖拽区。→ `.borderless`。
7. **IME 候选框错位**：非激活面板里中文输入法候选框会飘。→ 覆写 `firstRect(forCharacterRange:)` 手工换算屏幕坐标。
8. **qwen3 默认开思维链**：`content` 为空、`thinking` 逐字输出。→ `"think": false`。
9. **Ollama 默认 `num_ctx=262144`**：9B-q8 撑到 20GB、约 30s/token。→ `num_ctx: 8192`。
10. **SwiftPM 被 `sandbox-exec` 拦截**：本机所有构建命令需 `--disable-sandbox`。
11. **macOS 26 起菜单栏图标需要系统授权**：系统设置 → 菜单栏 → 「允许在菜单栏中显示」，按 bundle id 记录。
    关掉后 `NSStatusItem` 直接失效——`isVisible = true` 会被系统立刻重置回 false，或者图标窗口被
    ControlCenter 摆到屏幕外（y 为负）。**app 端没有任何 API 能自行恢复。**
    症状极易误判成代码 bug：实测改图标宽度、去掉 `item.menu`、改 bundle id、改 app 名、精简 Info.plist、
    延迟创建、去 `prewarm`、`killall SystemUIServer` / ControlCenter / Dock 全部无效；
    同一份代码换个时间点启动有时能显示，是因为当时授权开关还开着。详见 README「菜单栏图标不见了」。

## 12. 测试与调试

`swift test --disable-sandbox` 覆盖三块纯逻辑（16 项）：

- `TermParser`：分片、跨块标记、未闭合持有、换行/超长降级、空术语、多术语。
- `CardStore`：树操作、路径、重命名、级联删除、JSON 往返。
- `ContextAssembler`：本地/线上预算差异、由近到远分配、当前问题必须进上下文。

UI 无法截图时的替代方案（本机没有屏幕录制权限）：

| 参数 | 验证内容 |
|---|---|
| `--selftest` | 面板尺寸、各区块 frame、选区动作条、`⌘C` 是否真的进了剪贴板 |
| `--tree-dump [--tree-filter 词]` | 树的行数/列宽/单元格坐标、搜索命中集合与标记点 |
| `--headless "问题"` | provider + 解析器全链路（逐段打印 TEXT/TERM） |
| `--headless-child` | 子卡上下文 prompt 的实际输出 |

## 13. 扩展点

- **新增 provider**：实现 `LLMProvider`（`id` + `displayName` + `stream(messages:)`，本机推理再盖 `isLocal`），
  在 `ProviderConfig.makeProvider()` 里加一个分支；配置、UI、菜单都不必动。
  上下文策略按 `provider.isLocal` 自动切换（`ContextAssembler.Policy.forLocal`）。
- **换存储**：只改 `CardStore` 的七个方法实现。
- **加检索**：卡片树已经是 `parentID` 结构，加 embedding 字段 + top-k 检索，接在 `ContextAssembler` 之前。
- **加复习**：`AnswerCard` 是纯数据，可外挂 `dueAt/interval` 而不影响现有树。
- **加导出**：`CardStore.all()` + `path(to:)` 已能还原任意子树。

## 14. 文件依赖

```
main.swift
 └─ AppDelegate ─┬─ KeyboardShortcuts（热键）
                 ├─ PanelController ─┬─ PanelContentView ─┬─ BreadcrumbBar
                 │                   │                    ├─ QuestionHeaderView
                 │                   │                    ├─ AnswerTextView
                 │                   │                    ├─ InputTextView ×2
                 │                   │                    ├─ SelectionActionBar
                 │                   │                    └─ KnowledgeTreeView
                 │                   ├─ CardStore (actor)
                 │                   └─ Settings ── ProviderConfig ──┬─ OllamaProvider
                 │                                                  ├─ OpenAICompatibleProvider
                 │                                                  └─ GeminiProvider
                 └─ SettingsWindowController
```
