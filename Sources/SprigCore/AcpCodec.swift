import Foundation

/// 用户在面板里要批准或拒绝的一次 agent 询问。字段来自 ACP `session/request_permission`。
public struct AcpPermissionOption: Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct AcpPermissionAsk: Equatable, Sendable {
    public var sessionId: String
    public var title: String
    public var detail: String
    public var options: [AcpPermissionOption]

    public init(sessionId: String, title: String, detail: String, options: [AcpPermissionOption]) {
        self.sessionId = sessionId
        self.title = title
        self.detail = detail
        self.options = options
    }
}

public enum AcpPermissionOutcome: Equatable, Sendable {
    case selected(String)
    case cancelled
}

enum AcpFold: Equatable {
    /// 写进答案正文的一段
    case message(String)
    /// 思考。有正文时丢掉；整轮只有思考时才补出来
    case thought(String)
    /// 工具活动。调用方按 toolCallId 去重
    case tool(id: String, title: String)
    case ignore
}

enum AcpInbound: Equatable {
    case result(id: JSONValue, result: JSONValue)
    case failure(id: JSONValue, message: String, needsAuth: Bool)
    case notification(method: String, params: JSONValue)
    case request(id: JSONValue, method: String, params: JSONValue)
}

/// agent 在 `session/new` 里报的一个可选模型。
public struct AcpModel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// 右上角那行小字：计费倍率 / 上下文窗口，没有就空着
    public var detail: String
    /// agent 报的输入窗口（token）。拿它算上下文预算，而不是套云端模型的值。
    public var maxInputTokens: Int?

    public init(id: String, name: String, detail: String = "", maxInputTokens: Int? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.maxInputTokens = maxInputTokens
    }

    /// 「auto」是 agent 自己路由的档位：又慢又不可预期，列表里直接不显示
    public var isAuto: Bool { id.lowercased().hasPrefix("auto") }

    public var label: String {
        detail.isEmpty ? name : "\(name)（\(detail)）"
    }
}

/// agent 暴露的一个会话选项（模型、思考强度、权限模式…），`session/set_config_option` 可改。
public struct AcpConfigOption: Codable, Equatable, Sendable, Identifiable {
    public struct Choice: Codable, Equatable, Sendable {
        public var value: String
        public var name: String
        public init(value: String, name: String) {
            self.value = value
            self.name = name
        }
    }

    public var id: String
    public var name: String
    public var category: String
    public var currentValue: String
    public var choices: [Choice]

    public init(id: String, name: String, category: String, currentValue: String, choices: [Choice]) {
        self.id = id
        self.name = name
        self.category = category
        self.currentValue = currentValue
        self.choices = choices
    }

    /// 思考强度：codebuddy 叫 thought_level，codex 叫 reasoning_effort
    public var isThoughtLevel: Bool {
        let lower = category.lowercased() + " " + id.lowercased()
        return lower.contains("thought") || lower.contains("reason")
    }
}

/// `session/new` 里知枝关心的那部分。
public struct AcpSessionStart: Equatable, Sendable {
    public var sessionId: String
    public var models: [AcpModel]
    public var currentModelID: String?
    /// 模型这一项在 `configOptions` 里的 configId，默认就是 "model"
    public var modelConfigID: String
    /// 全部选项（思考强度、权限模式等），UI 按需取用
    public var options: [AcpConfigOption]
}

/// ACP 线协议里知枝用到的那一段。
///
/// 和 dsh-ntr 同一条 stdio：一行一个 JSON-RPC。
/// 只转发最后一条用户消息；`agent_message_chunk` 的文字才是回答。
public enum AcpCodec {
    static let protocolVersion = 1

    /// 挂在用户问题后面的显示约定。知枝的术语是点开来的，agent 不写标记就点不了。
    public static let termHint = "\n\n（用中文直接回答。专有名词第一次出现时写成 ⟦术语⟧，不要解释这个标记；"
        + "需要分点、对比或给步骤时用 Markdown 列表/表格/代码块；画图用 mermaid，不要输出 HTML。）"

    /// 启动命令的展示名。`npx -y some-pkg` 显示包名，而不是 npx。
    public static func programName(commandLine: String) -> String {
        let tokens = tokenize(commandLine)
        guard let first = tokens.first, !first.isEmpty else { return "Agent" }
        let base = (first as NSString).lastPathComponent
        let launchers: Set<String> = ["npx", "npm", "bunx", "pnpm", "yarn"]
        if launchers.contains(base), let last = tokens.last, last != first {
            let name = (last as NSString).lastPathComponent
            if name.hasPrefix("@"), let leaf = name.split(separator: "/").last {
                return String(leaf)
            }
            return name
        }
        return base
    }

    /// 最后一条用户消息。system / assistant / tool 不转发给 agent。
    public static func forwardText(from messages: [ChatMessage]) -> String? {
        var last: String?
        for message in messages where message.role == .user {
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            last = text
        }
        return last
    }

    /// 引号感知的命令行切分。空的 `""` 也保留成一个空参数。
    static func tokenize(_ raw: String) -> [String] {
        let chars = Array(raw)
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?
        var touched = false
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if let quote = activeQuote {
                if char == "\\", quote == "\"", index + 1 < chars.count, chars[index + 1] == "\"" {
                    current.append("\"")
                    index += 2
                    continue
                }
                if char == quote {
                    activeQuote = nil
                    index += 1
                    continue
                }
                current.append(char)
                index += 1
                continue
            }
            if char == "\"" || char == "'" {
                activeQuote = char
                touched = true
                index += 1
                continue
            }
            if char == " " || char == "\t" || char == "\n" || char == "\r" {
                if touched || !current.isEmpty {
                    tokens.append(current)
                }
                current = ""
                touched = false
                index += 1
                continue
            }
            current.append(char)
            touched = true
            index += 1
        }
        if touched || !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    static func resolveExecutable(_ token: String, path: String) -> String? {
        let expanded = (token as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent(expanded)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func initializeRequest(id: Int) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .number(Double(protocolVersion)),
                "clientCapabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("sprig"),
                    "title": .string("知枝"),
                    "version": .string("1"),
                ]),
            ]),
        ])
    }

    static func newSessionRequest(id: Int, cwd: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("session/new"),
            "params": .object([
                "cwd": .string(cwd),
                "mcpServers": .array([]),
            ]),
        ])
    }

    /// 早期/兼容实现用的换模型方法，参数更窄（只有 modelId）。
    /// codex-acp 这类 agent 只实现了它，`set_config_option` 会回 `-32602`。
    static func setModelRequest(id: Int, sessionId: String, modelId: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("session/set_model"),
            "params": .object([
                "sessionId": .string(sessionId),
                "modelId": .string(modelId),
            ]),
        ])
    }

    /// 切换会话配置项（模型、权限模式都走这一个方法）。
    static func setConfigOptionRequest(id: Int,
                                       sessionId: String,
                                       configId: String,
                                       value: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("session/set_config_option"),
            "params": .object([
                "sessionId": .string(sessionId),
                "configId": .string(configId),
                "value": .string(value),
            ]),
        ])
    }

    /// 解析 `session/new` 的返回：会话 id + 可选模型 + 当前模型。
    ///
    /// 模型信息有两种表达：`models.availableModels`（新）和 `configOptions` 里
    /// `category == "model"` 的那条（老）。两种都认，优先 `models`。
    static func parseSessionStart(_ result: JSONValue) -> AcpSessionStart? {
        guard let sessionId = result["sessionId"]?.string, !sessionId.isEmpty else { return nil }

        var modelConfigID = "model"
        var optionModels: [AcpModel] = []
        var optionCurrent: String?
        for option in result["configOptions"]?.array ?? [] where option["category"]?.string == "model" {
            if let id = option["id"]?.string, !id.isEmpty { modelConfigID = id }
            optionCurrent = option["currentValue"]?.string
            for choice in option["options"]?.array ?? [] {
                guard let value = choice["value"]?.string, !value.isEmpty else { continue }
                optionModels.append(AcpModel(id: value,
                                             name: choice["name"]?.string ?? value,
                                             detail: choice["description"]?.string ?? ""))
            }
        }

        var models: [AcpModel] = []
        for item in result["models"]?["availableModels"]?.array ?? [] {
            guard let id = item["modelId"]?.string, !id.isEmpty else { continue }
            let choice = AcpModel(id: id,
                                  name: item["name"]?.string ?? id,
                                  detail: modelDetail(item["_meta"]),
                                  maxInputTokens: maxInput(of: item["_meta"]))
            if choice.isAuto { continue }
            models.append(choice)
        }
        if models.isEmpty { models = optionModels }

        var parsedOptions: [AcpConfigOption] = []
        for option in result["configOptions"]?.array ?? [] {
            guard let id = option["id"]?.string, !id.isEmpty else { continue }
            let choices = (option["options"]?.array ?? []).compactMap { choice -> AcpConfigOption.Choice? in
                guard let value = choice["value"]?.string, !value.isEmpty else { return nil }
                return .init(value: value, name: choice["name"]?.string ?? value)
            }
            parsedOptions.append(AcpConfigOption(id: id,
                                                 name: option["name"]?.string ?? id,
                                                 category: option["category"]?.string ?? "",
                                                 currentValue: option["currentValue"]?.string ?? "",
                                                 choices: choices))
        }

        let current = result["models"]?["currentModelId"]?.string ?? optionCurrent
        return AcpSessionStart(sessionId: sessionId,
                               models: models,
                               currentModelID: current,
                               modelConfigID: modelConfigID,
                               options: parsedOptions)
    }

    static func maxInput(of meta: JSONValue?) -> Int? {
        guard case .number(let tokens)? = meta?["maxInputTokens"], tokens > 0 else { return nil }
        return Int(tokens)
    }

    /// `_meta` 里挑两个最有用的：计费倍率、上下文窗口。
    static func modelDetail(_ meta: JSONValue?) -> String {
        guard let meta else { return "" }
        var parts: [String] = []
        if let credits = meta["credits"]?.string, !credits.isEmpty { parts.append(credits) }
        if case .number(let window)? = meta["maxInputTokens"], window > 0 {
            parts.append("\(Int(window / 1000))k")
        }
        return parts.joined(separator: " · ")
    }

    static func promptRequest(id: Int, sessionId: String, text: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("session/prompt"),
            "params": .object([
                "sessionId": .string(sessionId),
                "prompt": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]),
        ])
    }

    static func cancelNotification(sessionId: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/cancel"),
            "params": .object([
                "sessionId": .string(sessionId),
            ]),
        ])
    }

    static func authenticateRequest(id: Int, methodId: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("authenticate"),
            "params": .object(["methodId": .string(methodId)]),
        ])
    }

    /// 认识的「浏览器登录」方法 id。别的 agent 用的是 api-key / oauth 之类，
    /// 猜错会把它拉进一个没法在 ACP 里完成的登录流程，所以只认这几个。
    static let browserAuthMethodIDs = ["internal", "external", "iOA", "selfhosted"]

    /// 只在这几个方法里挑一个；没有就返回 nil，交给用户自己去终端登录。
    ///
    /// 除了已知 id，也认「名字里带 login/oauth/sso/device」的方法——cursor 的
    /// `cursor_login` 就属于这种，它的登录流程同样是开浏览器，能在 ACP 里走完。
    static func browserAuthMethod(from methods: [JSONValue]) -> String? {
        let ids = methods.compactMap { $0["id"]?.string }
        // 先按偏好顺序挑已知的（微信登录优先于网页登录）
        for preferred in browserAuthMethodIDs where ids.contains(preferred) { return preferred }
        // 再认名字像登录流程的（cursor 的 cursor_login）
        for id in ids {
            let lower = id.lowercased()
            if lower.contains("login") || lower.contains("oauth")
                || lower.contains("sso") || lower.contains("device") {
                return id
            }
        }
        return nil
    }

    /// agent 声明的登录方式，用于提示文案。
    static func authMethodNames(from methods: [JSONValue]) -> [String] {
        methods.compactMap { $0["name"]?.string ?? $0["id"]?.string }
    }

    struct RefusalDetail: Equatable {
        var text: String
        var needsAuth: Bool
    }

    /// `session/prompt` 以 refusal 结束时，原因在 `_meta`，不在正文里。
    ///
    /// `stderrTail` 是 agent 进程最近几行 stderr。refusal 的 `_meta` 经常是空的，
    /// 真正原因（未登录、额度、模型不可用）只写在 stderr 里，带上一截总比只说
    /// 「没有可见回复」有用。
    static func refusalDetail(_ result: JSONValue, stderrTail: [String] = []) -> RefusalDetail {
        let meta = result["_meta"]
        let raw = meta?["codebuddy.ai/errorMessage"]?.string
            ?? meta?["errorMessage"]?.string
            ?? result["errorMessage"]?.string
        var message = ""
        var details = ""
        var category = ""
        if let raw {
            if let parsed = JSONValue.parse(line: raw), parsed.object != nil {
                message = parsed["message"]?.string ?? ""
                details = parsed["data"]?["details"]?.string ?? ""
                category = parsed["data"]?["category"]?.string ?? ""
            } else {
                message = raw
            }
        }
        let haystack = "\(message) \(details)"
        let needsAuth = category == "auth"
            || haystack.localizedCaseInsensitiveContains("authentication required")
            || haystack.localizedCaseInsensitiveContains("not logged in")
            || haystack.localizedCaseInsensitiveContains("sign in")
            || haystack.localizedCaseInsensitiveContains("unauthorized")
            || haystack.contains("/login")
        let text: String
        if needsAuth {
            text = "这个 agent 还没有登录。请在打开的页面里完成登录，登录后会自动再问一次。"
        } else if !details.isEmpty {
            text = details
        } else if !message.isEmpty {
            text = message
        } else {
            let reason = result["stopReason"]?.string ?? "refusal"
            var lines = ["Agent 以 \(reason) 结束了这一轮，没有可显示的回答。"]
            if let raw, !raw.isEmpty {
                lines.append("agent 返回：\(shorten(raw))")
            } else if let compact = compactJSON(meta), compact != "{}" {
                lines.append("返回字段：\(shorten(compact))")
            }
            if !stderrTail.isEmpty {
                lines.append("agent 日志：\(shorten(stderrTail.joined(separator: " | ")))")
            }
            text = lines.joined(separator: "\n")
        }
        return RefusalDetail(text: text, needsAuth: needsAuth)
    }

    /// 诊断信息塞进一行提示里，太长会把面板撑爆。
    static func shorten(_ text: String, limit: Int = 220) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    static func compactJSON(_ value: JSONValue?) -> String? {
        guard let value, let data = try? value.data() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func closeRequest(id: Int, sessionId: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("session/close"),
            "params": .object([
                "sessionId": .string(sessionId),
            ]),
        ])
    }

    static func permissionResult(id: JSONValue, outcome: AcpPermissionOutcome) -> JSONValue {
        let body: JSONValue
        switch outcome {
        case .selected(let optionId):
            body = .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(optionId),
                ]),
            ])
        case .cancelled:
            body = .object([
                "outcome": .object([
                    "outcome": .string("cancelled"),
                ]),
            ])
        }
        return .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": body,
        ])
    }

    static func methodNotFound(id: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(-32601),
                "message": .string("Method not found"),
            ]),
        ])
    }

    static func parseInbound(_ line: String) -> AcpInbound? {
        guard case .object(let fields) = JSONValue.parse(line: line) else { return nil }
        let root = JSONValue.object(fields)
        if let method = root["method"]?.string {
            let params = root["params"] ?? .object([:])
            if let id = root["id"]?.rpcID {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }
        guard let id = root["id"]?.rpcID else { return nil }
        if let error = root["error"] {
            // 没登录时 agent 有两种表达：`data.category = auth`（codebuddy），
            // 或者只把 "Authentication required" 写在 message 里（cursor）。
            let message = rpcErrorMessage(error)
            let needsAuth = error["data"]?["category"]?.string == "auth"
                || message.localizedCaseInsensitiveContains("authentication required")
                || message.localizedCaseInsensitiveContains("not logged in")
            return .failure(id: id, message: message, needsAuth: needsAuth)
        }
        return .result(id: id, result: root["result"] ?? .null)
    }

    /// `-32603` 的原因在 `error.data`，只读 `message` 会剩一句 Internal error。
    static func rpcErrorMessage(_ error: JSONValue) -> String {
        let message = error["message"]?.string ?? "Agent 返回错误"
        let kind = error["data"]?["errorKind"]?.string
        let detail = error["data"]?["message"]?.string
        let tail = [kind, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        if tail.isEmpty || tail == message { return message }
        return "\(message) — \(tail)"
    }

    static func foldUpdate(_ update: JSONValue) -> AcpFold {
        let kind = update["sessionUpdate"]?.string ?? ""
        switch kind {
        case "agent_message_chunk":
            let text = chunkText(update["content"])
            return text.isEmpty ? .ignore : .message(text)
        case "agent_thought_chunk":
            let text = chunkText(update["content"])
            return text.isEmpty ? .ignore : .thought(text)
        case "tool_call", "tool_call_update":
            let id = update["toolCallId"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else { return .ignore }
            return .tool(id: id, title: toolTitle(update))
        default:
            return .ignore
        }
    }

    static func parsePermission(_ params: JSONValue) -> AcpPermissionAsk? {
        let sessionId = params["sessionId"]?.string ?? ""
        guard !sessionId.isEmpty else { return nil }
        let tool = params["toolCall"] ?? .object([:])
        let options = (params["options"]?.array ?? []).compactMap { item -> AcpPermissionOption? in
            guard let id = item["optionId"]?.string, !id.isEmpty else { return nil }
            let name = item["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = item["kind"]?.string ?? ""
            let label = (name?.isEmpty == false) ? name! : kind.isEmpty ? id : kind
            return AcpPermissionOption(id: id, name: label, kind: kind)
        }
        return AcpPermissionAsk(
            sessionId: sessionId,
            title: toolTitle(tool),
            detail: toolDetail(tool),
            options: options
        )
    }

    static func chunkText(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        switch content {
        case .string(let value):
            return value
        case .array(let items):
            return items.map { chunkText($0) }.joined()
        case .object:
            if let text = content["text"]?.string { return text }
            if let nested = content["resource"]?["text"]?.string { return nested }
            return ""
        default:
            return ""
        }
    }

    private static func toolTitle(_ tool: JSONValue) -> String {
        if let title = tool["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let kind = tool["kind"]?.string, !kind.isEmpty { return kind }
        return "工具调用"
    }

    private static func toolDetail(_ tool: JSONValue) -> String {
        var parts: [String] = []
        if let locations = tool["locations"]?.array {
            for location in locations {
                if let path = location["path"]?.string, !path.isEmpty {
                    parts.append(path)
                    break
                }
            }
        }
        if let raw = tool["rawInput"] {
            if let text = raw.string, !text.isEmpty {
                parts.append(text)
            } else if let command = raw["command"]?.string ?? raw["cmd"]?.string ?? raw["path"]?.string, !command.isEmpty {
                parts.append(command)
            }
        }
        let joined = parts.joined(separator: " · ")
        if joined.count <= 160 { return joined }
        return String(joined.prefix(160)) + "…"
    }
}

public enum AcpEnvironment {
    public static func searchPath() -> String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let home = NSHomeDirectory()
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.local/bin",
            home + "/bin",
            home + "/.npm-global/bin",
        ]
        var parts = current.split(separator: ":").map(String.init)
        for extra in extras where !parts.contains(extra) {
            parts.append(extra)
        }
        // npx/node 装在 nvm 之类的目录里，菜单栏应用的 PATH 看不到它们。
        // 补法必须和启动子进程时一致，否则「能解析到」和「能跑起来」会对不上。
        return pathByPrependingNode(parts.joined(separator: ":"))
    }

    /// 命令行第一个词解析成绝对路径；找不到返回 nil。设置页拿它做行内诊断。
    public static func resolveProgram(in command: String) -> String? {
        guard let program = AcpCodec.tokenize(command).first, !program.isEmpty else { return nil }
        return AcpCodec.resolveExecutable(program, path: searchPath())
    }

    /// `#!/usr/bin/env node` 只在 PATH 里找 node。菜单栏应用的 PATH 没有 nvm，
    /// 这里把本机能执行的 node 目录补到最前面。
    ///
    /// node 目录按版本从新到旧整段放进去，并且先把 PATH 里已有的同名目录剔掉：
    /// 逐个 `insert(at: 0)` 会把旧版本顶到新版本前面（v25 已在 PATH 里时尤其明显）。
    static func pathByPrependingNode(_ path: String) -> String {
        let nodes = nodeBinDirectories()
        var parts = path.split(separator: ":").map(String.init)
            .filter { !$0.isEmpty && !nodes.contains($0) }
        parts.insert(contentsOf: nodes, at: 0)
        for directory in ["/usr/sbin", "/sbin"] where !parts.contains(directory) {
            parts.append(directory)
        }
        return parts.joined(separator: ":")
    }

    static func nodeBinDirectories() -> [String] {
        let manager = FileManager.default
        let home = NSHomeDirectory()
        var found: [(version: [Int], directory: String)] = []
        let nvm = (home as NSString).appendingPathComponent(".nvm/versions/node")
        if let versions = try? manager.contentsOfDirectory(atPath: nvm) {
            for version in versions {
                let directory = (nvm as NSString).appendingPathComponent("\(version)/bin")
                let node = (directory as NSString).appendingPathComponent("node")
                guard manager.isExecutableFile(atPath: node) else { continue }
                found.append((versionNumbers(version), directory))
            }
        }
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"] {
            let node = (directory as NSString).appendingPathComponent("node")
            if manager.isExecutableFile(atPath: node) {
                found.append(([], directory))
            }
        }
        return found.sorted(by: { lhs, rhs in
            if lhs.version != rhs.version { return versionIsNewer(lhs.version, than: rhs.version) }
            return lhs.directory < rhs.directory
        }).map(\.directory)
    }

    private static func versionIsNewer(_ lhs: [Int], than rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func versionNumbers(_ name: String) -> [Int] {
        let digits = name.drop { !$0.isNumber }
        return digits.split(separator: ".").compactMap { Int($0) }
    }

    /// WorkBuddy.app 里的 `codebuddy` 没有 `codebuddy-headless`，只写 `--acp` 会以
    /// MODULE_NOT_FOUND 退出，所以要走 lite 包（`CODEBUDDY_FORCE_LITE_WB_BUNDLE`）。
    ///
    /// `--serve` 和 `--port` 两个都不能省：只给 `--serve --acp` 时它自己挑的端口会跟
    /// 已经在跑的实例撞上，进程活着却一个帧都不回；显式给一个空闲端口才真的停在 stdio ACP 上。
    static func codebuddyLaunchAdjustment(executable: String, arguments: [String]) -> (arguments: [String], liteBundle: Bool) {
        let root = ((executable as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let headless = (root as NSString).appendingPathComponent("dist/codebuddy-headless")
        let manager = FileManager.default
        let hasHeadless = manager.fileExists(atPath: headless) || manager.fileExists(atPath: headless + ".js")
        let name = (executable as NSString).lastPathComponent
        guard name == "codebuddy" || name == "cbc", !hasHeadless else {
            return (arguments, false)
        }
        var adjusted = arguments
        if adjusted.contains("--acp") {
            if !adjusted.contains("--serve") {
                adjusted.insert("--serve", at: 0)
            }
            if !adjusted.contains("--port"), let port = freeLocalPort() {
                adjusted.append(contentsOf: ["--port", String(port)])
            }
        }
        return (adjusted, true)
    }

    /// 让系统分配一个空闲端口：bind 到 127.0.0.1:0 再读回来，随后立刻关掉。
    static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, size) == 0
            }
        }
        guard bound else { return nil }
        var assigned = sockaddr_in()
        var assignedSize = size
        let read = withUnsafeMutablePointer(to: &assigned) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &assignedSize) == 0
            }
        }
        guard read else { return nil }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    static func normalizeCwd(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Sprig/workspaces")
        let expanded = ((trimmed.isEmpty ? fallback : trimmed) as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return (NSHomeDirectory() as NSString).appendingPathComponent(expanded)
    }
}
