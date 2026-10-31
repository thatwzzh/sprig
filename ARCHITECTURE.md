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
│  LLMProvider(protocol) ← Ollama / OpenAI 兼容 / ACP agent      │
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
| `ContextAssembler` | 上下文 | 按模型真实窗口动态算预算（本地固定紧预算）；预留搜索结果空间；按句子边界截断 |
| `CardStore` | 存储 | `actor`，JSON 原子写入；删除级联 |
| `ProviderConfig` | 接入配置 | 名称/协议/Base URL/Key/模型，Codable 存 UserDefaults；`category` 分本地/免费/自定义，`cachedModels` 存免费类展开的模型清单 |
| `OllamaProvider` | 模型 | NDJSON；`think:false`、`num_ctx:8192`、`keep_alive:10m` |
| `OpenAICompatibleProvider` | 模型 | SSE；`/v1/chat/completions`，Base URL 自动归一化 |
| `AcpClient` | ACP agent | 进程复用、`session/new` 一次一问、登录态隔离、三态探活 |
| `AcpCodec` | ACP 协议 | 帧解析、启动参数补全（`--serve`/`--port`）、错误翻译 |
| `AcpPresets` / `AgentConfig` | agent 目录 | 内置预设清单 + 本机检测（PATH / 自带 CLI / npx 缓存） |
| `WebSearchTool` | 联网搜索 | Tavily `/search`；摘要截 600 字/条，避免吃掉上下文预算 |

## 4. 数据流

### 4.1 提问 → 流式渲染

```
顶部输入回车
  → createRootCard(question)
      新建 AnswerCard(parentID: nil) 压入 stack
      persistCurrentCard()（先落空答案，保证树结构立刻存在）
  → startStreaming([system(answer), user(question)])
      URLSession.bytes → NDJSON 逐行 → yield(content)
  → consume(chunk, owner: cardID)
      先看这张卡是不是当前显示的：
        是 → stack.last.raw += chunk，走解析和渲染
        否 → 只往 backgroundRaw[owner] 累积，不碰视图
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

### 4.5 后台继续生成

面板一次只显示一张卡，但流式请求可以有多条在跑。切换显示时不取消，转后台：

```
切换（新建根卡 / 树里点卡 / 面包屑回退）
  → detachCurrentStreaming()
      backgroundRaw[cardID] = stack.last.raw   ← 已渲染的部分作为起点
      streamTask = nil，isStreaming = false
      （注意：不调 cancel()，Task 会自己跑到底）

后台期间
  → consume(chunk, owner:) 判断 owner ≠ 当前卡 → 只累积

收尾
  → finish(owner:)
      后台：写进 CardStore（用 card(id:) 确认卡还在，避免给已删的卡造幽灵）
      前台：正常收尾
```

**哪些场景转后台、哪些仍然取消**：

| 场景 | 处理 | 理由 |
|---|---|---|
| 新建根卡 | detach | 用户想看新问题，旧的不该陪葬 |
| 树里切卡 / 面包屑回退 | detach | 只是换显示 |
| 追问子卡 | **cancel** | 追问依赖父卡的完整内容 |
| 清空面板 | cancel | |

**切回一张还在跑的卡** → `adoptBackgroundIfNeeded`：

1. 把 `backgroundRaw` 铺回节点，先渲染出来
2. `parser = TermParser()` 吞掉已有内容但不产出（后续 chunk 只吐增量）
3. 用另一个 parser 扫一遍填 `seenTerms`（否则术语下划线会重复）
4. 清掉 `backgroundRaw[cardID]`，让后续 `consume` 走前台分支

**关键约束**：`renderCurrent` 用的是独立的 `replay` parser 重放 raw，
和流式用的 `parser` 是两套状态，所以「吞掉内容」不影响已渲染的部分。

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
      2) ContextAssembler.context(path: 祖先链, policy: .dynamic(窗口, isLocal, toolReserve))
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

存储：默认 `~/Documents/Sprig/repository/`。人读的是每棵知识树一份 Markdown；程序读隐藏的 `.cards.json`（设置里可换目录），`CardStore` 是 `actor`，
写入用 `.atomic`。切换目录时若目标库不存在，会把当前库复制过去，避免卡片"消失"。
删除是级联的（先求后代闭包，再一起移除）。

**为什么不是 GRDB**：当前量级在几百张卡，JSON 足够且零依赖。接口刻意保持
`upsert / all / card / children / path / rename / delete` 七个方法——换成 GRDB + FTS5 时只替换实现，
调用方不动。触发升级的信号是「需要全文检索」或「卡片上千」。

## 6. 上下文装配

预算按**模型的真实上下文窗口**算，拿不到窗口才退回保守默认（单位：字符）。

窗口来源：

| provider | 来源 | 实测 |
|---|---|---|
| Ollama | `/api/tags` 的 `details.context_length` | 262,144 |
| OpenAI / DeepSeek / 自定义网关 | 拿不到，用默认 128k 估算 | — |

算法在 `Policy.dynamic`：`min(max(窗口/3, 4000), 30000)`。上限 30000 是因为再长首字延迟和
token 费用都上去了，对问答的边际收益很低；下限 4000 兜住小窗口模型。

**本地模型不参与窗口计算**，固定用 `.local` 那套。原因不是窗口（qwen3.5:9b 也有 262k），
而是 9B 级模型喂太长质量会明显下降——窗口大不代表能用满。

| 参数 | 本地（Ollama） | 线上（动态） |
|---|---|---|
| 总预算 | 2400 | 窗口/3，夹在 4000–30000 |
| 当前回答 | 1200 | 总预算的一半 |
| 直接父级 | 600 | 总预算/4，上限 6000 |
| 更远祖先 | 0（只留标题+问题） | 总预算/15，上限 1500 |
| 祖先层数 | 4 | 12 |

分配顺序是「由近到远」：当前卡必须完整（它是被解释的对象），父级给因果，更远的只留问题行。

**工具预留**：`Policy.toolReserve` 在装配时先扣掉。联网搜索的结果是流式循环里额外追加的消息，
装配器看不见，不预留的话卡片上下文和搜索结果会叠加撑爆窗口。开启联网时预留 3000 字（一轮典型搜索量）。

**截断**：`truncate` 优先落在段落换行，其次句末标点，只能保住 50%/60% 以上才接受，否则硬切。
硬 `prefix` 会把结尾砍掉，而结论往往就在最后一句。

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
- 流式归属：每条流式任务带一个 `owner: UUID`（卡片 id）。渲染与否由
  「owner 是不是当前显示的卡」决定，不是由「有没有 streamTask」决定——
  后者只能记一条，多任务并行时会丢。
- 取消：只有「追问子卡 / 清空面板」会 `cancelStreaming()`；
  切换显示走 `detachCurrentStreaming()`，任务继续在后台跑完并落库。
- 瞬时故障：TLS 握手失败 / 连接中断会先 `HTTPClient.resetSession()` 再重试——
  `URLSession` 的连接池会缓存坏掉的 TLS 会话，不换池重试也是撞同一条。
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
| 流式切换 | 转后台继续跑 | 直接取消 | 半截答案没有价值，而且用户看不出是被打断的 |
| 搜索结果 | 折叠成一行 + 点开菜单 | 平铺标题和域名 | 平铺会把正文切碎，读起来很吵 |
| 免费模型 | 内置智谱一家，其余走自定义接入 | 内置一堆免费通道 | 免费政策变得比代码快，内置多了都在维护别人的限流 |

## 11. 实现约束（每一条在代码里都有注释）

1. **`NSVisualEffectView` 的圆角要靠外层裁切**：背景层是方的，直接设 `cornerRadius` 会露四角。外层容器裁切 + `maskImage`。
2. **确认框自绘，不用 `NSAlert`**：`icon = nil` 会回退到 App 图标，空图仍占一块图标区。用 `ConfirmDialog` + `NSApp.runModal`，level 提到 `.modalPanel`（否则被 `.floating` 面板压住）。
3. **菜单跟踪期间屏蔽 `resignKey`**：`NSMenu` 打开会让面板失焦收起，靠 `didBegin/EndTracking` 计数判断。
4. **`NSOutlineView` 作 `documentView` 时手算宽高**：frame 不会自动跟随 scroll view。
5. **树宽按 clip 宽度夹住**：`NSScrollView` 会把 documentView 撑宽 32pt，导致横向滚动和行尾按钮被裁。在 `frame` / `setFrameSize` 两处夹宽度，按钮按 `visibleRightEdge` 定位。
6. **面板用 `.borderless`**：`.titled` 的标题栏会吞掉顶部 28pt 的点击（变成拖拽区）。
7. **IME 候选框位置手算**：非激活面板里中文候选框会飘，覆写 `firstRect(forCharacterRange:)` 换算屏幕坐标。
8. **Ollama 显式关思考链**：qwen3 默认开思维链，`content` 为空、`thinking` 逐字输出，所以请求带 `"think": false`。
9. **Ollama 显式限 `num_ctx`**：默认窗口会让 9B-q8 撑到 20GB、约 30s/token，固定 `num_ctx: 8192`。
10. **构建要 `--disable-sandbox`**：SwiftPM 调 `sandbox-exec` 被系统拒绝，`make-app.sh` 里已带。
11. **菜单栏图标依赖系统授权**：系统设置 → 菜单栏 → 「允许在菜单栏中显示」，按 bundle id 记录。关掉后 `NSStatusItem` 失效，`isVisible = true` 会被重置，**app 端没有 API 能自行恢复**。
12. **`NSTextContainer` 宽度交给 `widthTracksTextView`**：手动设成 `bounds.width` 会让文字右侧多出 16pt、画到面板外。诊断看 `--selftest` 打印的 `textContainer.size`，正确值是 `frame.width - 32`。
13. **`openAICompatible` 是筐，按 `baseURL` 分流**：`fetchFreeModels` 与路径拼接都要区分 `bigmodel`（`/api/paas/v4` 不能再补 `/v1`），用 `hasVersionPrefix` 识别 `/v1` `/v3` `/v4`。
14. **「读表单再执行」前先 `persistXxx()`**：`controlTextDidEndEditing` 要等失焦才触发，而按钮 action 先跑，会读到旧值再把空值写回输入框。
15. **判断「有没有内容」看缓冲，不看 `stack.raw`**：后台跑的那张卡 `stack.raw` 一定是空的。
16. **免费模型限流是产品约束**：智谱 GLM-4.7-Flash 成功率约 1/3，app 只做重试 + 换模型，额度没了只能等。

## 12. 测试与调试

`swift test --disable-sandbox` 覆盖三块纯逻辑（16 项）：

- `TermParser`：分片、跨块标记、未闭合持有、换行/超长降级、空术语、多术语。
- `CardStore`：树操作、路径、重命名、级联删除、JSON 往返。
- `ContextAssembler`：按窗口动态算预算、工具预留挤占祖先、句子边界截断、由近到远分配。

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
                 │                                                  └─ AcpClient（外部进程）
                 └─ SettingsWindowController
```

## 15. ACP agent 接入

面板可以把问题转给一个外部 ACP agent（`AcpClient`），进程按「启动命令 + 工作目录」复用，
每一问单独 `session/new`。

**启动参数**（`AcpEnvironment.codebuddyLaunchAdjustment`）：WorkBuddy 自带的
`codebuddy` 没有 `codebuddy-headless`，要走 lite 包（`CODEBUDDY_FORCE_LITE_WB_BUNDLE=1`），
并且 `--serve`、`--acp`、`--port <空闲端口>` 三个都得在：

- 只写 `--acp` → `MODULE_NOT_FOUND` 直接退出；
- `--serve --acp` 不给端口 → 它自己挑的端口被已在运行的实例占着，进程活着但**一个帧都不回**
  （表现就是 initialize 永远超时）；
- 显式给一个空闲端口，才真的停在 stdio ACP 上。

**登录态隔离**（`AcpClient.agentHome`）：**只对 codebuddy/cbc 生效**，agent 的 HOME 指向
`~/Library/Application Support/Sprig/agent-home`，于是它的 `~/.codebuddy` 和
`~/Library/Application Support/CodeBuddyExtension`（凭据）都落在自己目录里。

原因是 codebuddy 的 ACP `authenticate` 第一步就是「已登录就先 logout」，
共用凭据文件会把 WorkBuddy 桌面端的登录态顶掉。隔离之后登录、退出都只影响 agent 自己。
claude / codex / gemini 这类 agent 用**正常 HOME**：它们的登录态本来就不跟别的进程抢，
隔离只会让用户莫名其妙地重登一次。
`SPRIG_AGENT_HOME=none` 可关掉隔离，`SPRIG_AGENT_HOME=<路径>` 可换位置。

**模型**：`session/new` 会带回 `models.availableModels`（新形状）或 `configOptions` 里 `category=model` 的那条（老形状），`parseSessionStart` 两种都认。
切换先发 `session/set_config_option`，被拒（`-32602`，codex-acp 就是这样）再退到 legacy 的 `session/set_model`。
每一问都是新会话，所以选中的模型在每轮 `session/prompt` 之前要重设一次。

**Markdown 渲染**：`MarkdownLite` 解析（标题/列表/引用/代码块/表格/行内样式）→ `AnswerTextView.renderRich` 排版。
表格画成图片再挂 `NSTextAttachment`（`TableImage`）：`NSTextTable` 的行高和边框不可控，图片则完全可算，
图表同理（`ChartImage`：柱状/折线，步长取 1/1.2/1.5/2/2.5/3/4/5/6/8×10ⁿ，避免 12.5 这种刻度）。
```html 块走 `HtmlSnapshot`：WKWebView 离屏加载（塞进 borderless window，否则不排版）→ 量 scrollHeight →
`takeSnapshot`；结果按 HTML 内容哈希缓存在内存，并落成 `assets/html-<hash>.png`。
导出时 `expandHtmlBlocks` 若图片存在就写 `![](assets/…)`，否则把标签转义成代码块（原文不丢）。
导出侧 `CardMarkdown.expandChartBlocks` 把 `sprig-chart` 代码块转成两列表格，
知识库里永远是可读的 Markdown。

代码块按语言着色：`SprigCore/CodeHighlighter` 手写扫描（注释/字符串/数字/标识符 + 每门语言一张关键字表），
**输入输出必须逐字相等**（有测试锁着），不认识的语言整段按 plain 处理。token 色不跟主题走，统一一套明暗。

```mermaid 走 `MermaidSnapshot`：运行时（3.4MB `mermaid.min.js`）随包放在 `Contents/Resources`，
WKWebView 载入后轮询 `<svg>` 出现再截图。注意 mermaid 11 的 dist 是 esbuild 包，**没有 `window.mermaid`**，
要从 `globalThis.__esbuild_esm_mermaid_nm.mermaid.default` 取。渲染宽度固定 `Theme.answerTextWidth`（616），
**不要拿 `bounds.width` 当缓存键**——布局过程中它会从 1 变到 640，键一抖就查不到图。
画不出来（运行时缺失/语法错）退回代码块显示源码。

**报错不落盘**：失败文案只放在 `Node.errorText`（面板显示用），末尾带一个 `sprig://retry` 链接——
点击由 `textView(_:clickedOnLink:)` 分发到 `retryTurn()`，用同一张卡重建原请求重跑。不写进 `card.answer`，
所以既不会进 JSON 也不会被 `CardMarkdown` 同步进 Markdown。卡片保留问题、答案留空。

**登录流程**：没登录时 `session/new` 不回 refusal，而是
`error.data.category = "auth"`（`AcpError.authRequired`）。收到它就先发 `authenticate`，
agent 随后推 `_codebuddy.ai/authUrl` 通知，面板把链接显示出来并打开浏览器，
`authenticate` 兑现后自动重试一次。链接在**启动阶段**就会推，所以钩子是整轮挂着的，
不是只在 `login()` 里等。

**排查**：`SPRIG_ACP_TRACE=/tmp/acp.log` 启动，收发的原始帧都落到文件里。

**Agent 区**：设置页是一排标签（`AgentChipsView`），只显示名称，状态用名称后面的图标表示
（`✓` 成功 / `!` 未登录 / `✕` 失败 / `○` 没测），一行放不下自动换行。

启动和打开设置时 `AgentDetector.detect()` 扫本机：PATH 上能解析到的可执行文件、
WorkBuddy 自带 CLI、以及 `~/.npm/_npx` 里已经下过的包（claude / codex 这两个走 npx 的）。
命中的自动并进来（`Settings.syncDetectedAgents`）。**检测出来的只是标签**：不能删、点了也没反应；
单击任何一条都会打开设置弹窗（检测到的只能改模型，自定义的还能改名字和命令）；`＋` 挂在标签流末尾（自定义项），删除放在弹窗里（只有自定义项有这个按钮）。
面板当前用哪一条由标签边框高亮表示，切换在对话窗口的模型菜单里。
删掉检测项记的是预设 id（`dismissedAgentPresets`）；每次检测都会回头看那个预设**现在还装不装**，
已经卸载的把记录清掉——所以重装之后它会自己回来。
标题行左侧的「重新检测」手动重扫一次，不用关掉再打开设置。

工作目录是**全局共用**的，放在标签下面，不放进添加弹窗——换 agent 不该顺带换目录。
「测试全部」逐条握手（`AcpClient.probeStatus`：initialize + `session/new`；
遇到 `authRequired` 先用 agent 声明的方法 `authenticate` 一次再重试——cursor 每个连接都要求先握手，
即使 `agent status` 显示已登录）。
对话窗口的模型菜单直接列出所有已配置 agent，选谁就用谁。

Agent 模式下**联网搜索开关禁用**（面板上的和设置页的都是）：联不联网由 agent 自己决定。
