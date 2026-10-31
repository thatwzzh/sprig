import Foundation

/// 设置页里一条 agent 的测试结果。三种状态分开，用户才知道该去登录还是该修命令。
public enum AcpProbeStatus: Sendable, Equatable {
    case running
    case ok(String)
    case needsLogin(String)
    case failed(String)

    public var label: String {
        switch self {
        case .running: return "测试中…"
        case .ok(let name): return "成功 · \(name)"
        case .needsLogin(let methods): return "未登录 · \(methods)"
        case .failed(let reason): return "失败 · \(reason)"
        }
    }
}

public enum AcpError: LocalizedError, Sendable {    case notConfigured
    case commandNotFound(String)
    case badWorkspace(String)
    case launch(String)
    case timeout(String)
    case agent(String)
    case authRequired(String)
    case disconnected(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填写 Agent 启动命令。打开设置，填一整行，例如 agent acp。"
        case .commandNotFound(let name):
            return "找不到「\(name)」。菜单栏应用用不到终端里临时加的 PATH，"
                + "把程序放到 /opt/homebrew/bin 或 ~/.local/bin，或者直接填绝对路径。"
        case .badWorkspace(let path):
            return "Agent 的工作目录不存在：\(path)"
        case .launch(let message):
            return "Agent 启动失败：\(message)"
        case .timeout(let what):
            return "Agent 没有在时限内响应（\(what)）。"
        case .agent(let message):
            return message
        case .authRequired(let message):
            return "这个 agent 还没有登录：\(message)"
        case .disconnected(let reason):
            return "和 Agent 的连接断了：\(reason)"
        }
    }
}

/// 一个 ACP agent 进程。知枝把问题送进去，把 `session/update` 里的文字流出来。
///
/// 进程按启动命令和工作目录复用。每一问单独 `session/new`，因为卡片树会分叉，
/// 不能把兄弟卡塞进同一条线性会话。
public actor AcpClient {
    public static let shared = AcpClient()

    public init() {}

    private struct Waiter {
        var resume: @Sendable (Result<JSONValue, Error>) -> Void
        var timeout: Task<Void, Never>?
    }

    private final class Child {
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let stderrHandle: FileHandle
        let commandLine: String
        let cwd: String
        var agentName: String
        var authMethodId: String?
        var authMethods: [String] = []
        var authMethodNames: [String] = []
        var isolatedHome: String?
        var stderr: [String] = []

        init(process: Process,
             stdin: FileHandle,
             stdout: FileHandle,
             stderrHandle: FileHandle,
             commandLine: String,
             cwd: String,
             agentName: String) {
            self.process = process
            self.stdin = stdin
            self.stdout = stdout
            self.stderrHandle = stderrHandle
            self.commandLine = commandLine
            self.cwd = cwd
            self.agentName = agentName
        }
    }

    /// 退出时主线程不能等 actor，否则正停在权限弹层上会卡住。
    private nonisolated let processes = ProcessBox()

    private var child: Child?
    private var authURLHook: (@Sendable (String) -> Void)?
    private var epoch = 0
    private var idCounter = 0
    private var pending: [String: Waiter] = [:]
    private var sinks: [String: @Sendable (JSONValue) -> Void] = [:]
    private var permissions: [String: @Sendable (AcpPermissionAsk) async -> AcpPermissionOutcome] = [:]
    private var permissionTasks: [String: Task<Void, Never>] = [:]
    private var answeredPermissions: Set<String> = []
    private var starting: Task<String, Error>?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    public func shutdown() {
        stopChild("已关闭")
    }

    /// 拉起进程并完成 `initialize`，返回 agent 自己报的名字。
    public func probe(commandLine: String, cwd: String, path: String) async throws -> String {
        try await ensureReady(commandLine: commandLine, cwd: cwd, path: path)
    }

    /// 设置页「读取模型」用：开一个会话拿到模型清单和会话选项，随即关掉。
    public func discover(commandLine: String, cwd: String, path: String) async throws -> AcpSessionStart {
        _ = try await ensureReady(commandLine: commandLine, cwd: cwd, path: path)
        do {
            let start = try await newSession(cwd: child?.cwd ?? cwd)
            await closeQuietly(start.sessionId)
            return start
        } catch AcpError.authRequired {
            throw AcpError.agent("这个 agent 还没登录，登录之后才能读到模型清单。")
        }
    }

    @available(*, deprecated, message: "用 discover(...) 拿完整信息")
    public func discoverModels(commandLine: String, cwd: String, path: String) async throws -> [AcpModel] {
        try await discover(commandLine: commandLine, cwd: cwd, path: path).models
    }

    /// 设置页「测试」用：握手 + 试开一个会话，能区分「没登录」和「真的坏了」。
    public func probeStatus(commandLine: String, cwd: String, path: String) async -> AcpProbeStatus {
        do {
            let name = try await ensureReady(commandLine: commandLine, cwd: cwd, path: path)
            do {
                let start = try await newSession(cwd: child?.cwd ?? cwd)
                await closeQuietly(start.sessionId)
                return .ok(name)
            } catch AcpError.authRequired {
                // 有的 agent（cursor）即使已经登录，也要先 authenticate 一次才允许开会话。
                // 这里替它做掉这次握手：能过就是「成功」，过不了才算没登录。
                guard let method = child?.authMethodId else { return notLoggedIn() }
                do {
                    _ = try await rpc(AcpCodec.authenticateRequest(id: allocate(), methodId: method),
                                      timeoutNanoseconds: 30_000_000_000,
                                      label: "登录")
                } catch {
                    return notLoggedIn()
                }
                guard let start = try? await newSession(cwd: child?.cwd ?? cwd) else {
                    return notLoggedIn()
                }
                await closeQuietly(start.sessionId)
                return .ok(name)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func notLoggedIn() -> AcpProbeStatus {
        let methods = child?.authMethodNames ?? []
        return .needsLogin(methods.isEmpty ? "需要登录" : methods.joined(separator: "、"))
    }

    /// `model` 为空表示不干预，用 agent 自己的默认模型。
    public func ask(text: String,
                    commandLine: String,
                    cwd: String,
                    path: String,
                    model: String? = nil,
                    thoughtLevel: String? = nil,
                    permission: @escaping @Sendable (AcpPermissionAsk) async -> AcpPermissionOutcome,
                    onAuthURL: (@Sendable (URL) -> Void)? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let gate = FinishBox()
            let task = Task {
                await self.runTurn(text: text,
                                   commandLine: commandLine,
                                   cwd: cwd,
                                   path: path,
                                   model: model,
                                   thoughtLevel: thoughtLevel,
                                   permission: permission,
                                   onAuthURL: onAuthURL,
                                   yield: { gate.yield($0, continuation) },
                                   finish: { gate.finish($0, continuation) })
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func runTurn(text: String,
                         commandLine: String,
                         cwd: String,
                         path: String,
                         model: String?,
                         thoughtLevel: String?,
                         permission: @escaping @Sendable (AcpPermissionAsk) async -> AcpPermissionOutcome,
                         onAuthURL: (@Sendable (URL) -> Void)?,
                         yield: @escaping @Sendable (String) -> Void,
                         finish: @escaping @Sendable (Error?) -> Void) async {
        let state = TurnState()
        var sessionId: String?
        // codebuddy 在启动阶段、prompt 之前就会推登录链接，而且只推一次。
        // 所以钩子要整轮挂着，而不是只在 login() 里等 —— 之前链接就是这样被丢掉的。
        authURLHook = { url in
            state.sawAuthURL = true
            yield("\n需要登录：\(url)\n")
            if let link = URL(string: url) { onAuthURL?(link) }
        }
        defer { authURLHook = nil }

        func attachSink(_ sid: String) {
            sinks[sid] = { update in
                switch AcpCodec.foldUpdate(update) {
                case .message(let chunk):
                    state.sawMessage = true
                    state.sawVisible = true
                    yield(chunk)
                case .thought(let chunk):
                    state.thoughts += chunk
                case .tool(let id, let title):
                    guard state.tools.insert(id).inserted else { return }
                    state.sawVisible = true
                    yield("\n· 工具：\(title)\n")
                case .ignore:
                    break
                }
            }
        }

        /// 只说了想法、一个字没答时，把想法当正文，别让面板空着。
        func surfaceThoughts() {
            if !state.sawMessage, !state.thoughts.isEmpty {
                state.sawVisible = true
                yield(state.thoughts)
            }
        }

        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AcpError.agent("没有要转发的问题。") }
            _ = try await ensureReady(commandLine: commandLine, cwd: cwd, path: path)
            try Task.checkCancellation()

            // 隔离的 HOME 里还没有凭据，而且这个 agent 支持浏览器登录：先把登录做完，
            // 别先失败一轮再补。其他情况交给 session/new 的 authRequired 分支。
            if !hasStoredCredential(), child?.authMethodId != nil {
                yield("\n第一次用这个 agent，需要先在浏览器里登录一次。\n")
                guard await login(yield: yield) else {
                    throw AcpError.agent("登录没有完成。登录好之后再问一次就行。")
                }
            }

            let start = try await openSession(cwd: child?.cwd ?? cwd, yield: yield)
            let sid = start.sessionId
            sessionId = sid
            permissions[sid] = permission
            attachSink(sid)

            // 每一问都是新会话，所以选中的模型必须在这里重新设一次，否则下一问又回到默认。
            if let thought = thoughtLevel, !thought.isEmpty,
               let option = start.options.first(where: { $0.isThoughtLevel }),
               option.currentValue != thought {
                do {
                    _ = try await rpc(AcpCodec.setConfigOptionRequest(id: allocate(),
                                                                      sessionId: sid,
                                                                      configId: option.id,
                                                                      value: thought),
                                      timeoutNanoseconds: 15_000_000_000,
                                      label: "设置思考强度")
                    trace("--", "\(option.id) -> \(thought)")
                } catch {
                    // 设不上不影响提问
                }
            }

            if let model, model != start.currentModelID {
                do {
                    _ = try await rpc(AcpCodec.setConfigOptionRequest(id: allocate(),
                                                                      sessionId: sid,
                                                                      configId: start.modelConfigID,
                                                                      value: model),
                                      timeoutNanoseconds: 15_000_000_000,
                                      label: "设置模型")
                    trace("--", "model -> \(model)")
                } catch {
                    // 有的 agent（codex-acp）只实现了 legacy 的 session/set_model
                    do {
                        _ = try await rpc(AcpCodec.setModelRequest(id: allocate(),
                                                                   sessionId: sid,
                                                                   modelId: model),
                                          timeoutNanoseconds: 15_000_000_000,
                                          label: "设置模型（legacy）")
                        trace("--", "model -> \(model) (legacy)")
                    } catch {
                        // 两条路都不通不该挡住提问，说明一下继续
                        yield("\n（没能切到 \(model)，这一轮仍用 agent 的默认模型）\n")
                    }
                }
            }

            var settled: JSONValue
            do {
                settled = try await sendPrompt(sid: sid, text: trimmed)
            } catch AcpError.authRequired {
                // 会话中途掉登录态（token 过期）时也补一次，而不是把错误甩给用户。
                guard await login(yield: yield) else {
                    throw AcpError.agent("登录没有完成。登录好之后再问一次就行。")
                }
                settled = try await sendPrompt(sid: sid, text: trimmed)
            }
            sinks[sid] = nil
            permissions[sid] = nil
            try Task.checkCancellation()

            surfaceThoughts()
            if !state.sawVisible {
                let atFirst = Array((child?.stderr.suffix(3)) ?? [])
                let detail = AcpCodec.refusalDetail(settled, stderrTail: atFirst)
                if detail.needsAuth || state.sawAuthURL {
                    // 已经推过链接就不再重复一遍原因，免得同一段话说两遍。
                    if !state.sawAuthURL {
                        yield("\n\n\(detail.text)\n")
                    }
                    state.sawVisible = true
                    if await self.login(yield: yield) {
                        state.sawMessage = false
                        state.sawVisible = false
                        state.thoughts = ""
                        attachSink(sid)
                        settled = try await sendPrompt(sid: sid, text: trimmed)
                        sinks[sid] = nil
                        surfaceThoughts()
                    }
                }
                if !state.sawVisible {
                    let tail = Array((child?.stderr.suffix(3)) ?? [])
                    yield("\n\n⚠️ \(AcpCodec.refusalDetail(settled, stderrTail: tail).text)\n")
                }
            }
            finish(nil)
            await closeQuietly(sid)
        } catch is CancellationError {
            tearDownSession(sessionId)
            finish(nil)
        } catch {
            tearDownSession(sessionId)
            if let sessionId {
                cancelSession(sessionId, promptKey: nil)
            }
            finish(error)
        }
    }

    /// `session/new`。没登录时 agent 直接回 `category=auth` 的错误，登录后重来一次。
    private func openSession(cwd: String,
                             yield: @escaping @Sendable (String) -> Void) async throws -> AcpSessionStart {
        do {
            return try await newSession(cwd: cwd)
        } catch AcpError.authRequired {
            guard await login(yield: yield) else {
                throw AcpError.agent("登录没有完成。登录好之后再问一次就行。")
            }
            return try await newSession(cwd: cwd)
        }
    }

    private func newSession(cwd: String) async throws -> AcpSessionStart {
        let created = try await rpc(AcpCodec.newSessionRequest(id: allocate(), cwd: cwd),
                                    timeoutNanoseconds: 20_000_000_000,
                                    label: "session/new")
        guard let start = AcpCodec.parseSessionStart(created) else {
            throw AcpError.agent("session/new 没有返回 sessionId。")
        }
        return start
    }

    private func sendPrompt(sid: String, text: String) async throws -> JSONValue {
        let promptID = allocate()
        let key = JSONValue.number(Double(promptID)).canonicalID ?? String(promptID)
        return try await withTaskCancellationHandler {
            try await self.rpc(AcpCodec.promptRequest(id: promptID, sessionId: sid, text: text),
                               timeoutNanoseconds: 600_000_000_000,
                               label: "session/prompt",
                               existingKey: key)
        } onCancel: {
            Task { await self.cancelSession(sid, promptKey: key) }
        }
    }

    private func tearDownSession(_ sessionId: String?) {
        guard let sessionId else { return }
        sinks[sessionId] = nil
        permissions[sessionId] = nil
        permissionTasks[sessionId]?.cancel()
        permissionTasks[sessionId] = nil
    }

    private func ensureReady(commandLine: String, cwd: String, path: String) async throws -> String {
        let command = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = AcpEnvironment.normalizeCwd(cwd)
        if let child, child.commandLine == command, child.cwd == directory, child.process.isRunning {
            return child.agentName
        }
        if let starting {
            return try await starting.value
        }
        let task = Task { try await self.launch(commandLine: command, cwd: directory, path: path) }
        starting = task
        do {
            let name = try await task.value
            starting = nil
            return name
        } catch {
            starting = nil
            throw error
        }
    }

    /// 给 agent 单独的 HOME。
    ///
    /// codebuddy 的 ACP `authenticate` 第一步就是「已登录就先 logout」——它写到
    /// `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/` 的那份
    /// 凭据和桌面端是同一份，共用就会把桌面端登录态顶掉。子进程换成自己的 HOME 后，
    /// 它读写的 `~/.codebuddy`、`~/Library/Application Support/CodeBuddyExtension`
    /// 都落在自己目录里，登录、退出都只影响它自己。
    static func agentHome() -> String? {
        // 排查用：SPRIG_AGENT_HOME=none 关掉隔离，=路径 换个别的位置。
        if let override = ProcessInfo.processInfo.environment["SPRIG_AGENT_HOME"] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "none" { return nil }
            if !trimmed.isEmpty { return trimmed }
        }
        let base = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Sprig/agent-home")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: base, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? base : nil
        }
        do {
            try FileManager.default.createDirectory(atPath: base,
                                                    withIntermediateDirectories: true)
            return base
        } catch {
            return nil
        }
    }

    /// agent 的独立 HOME 里是否已经有凭据。没有就说明这台机器上它还没登录过。
    /// 只有 codebuddy/cbc 需要隔离 HOME：它和 WorkBuddy 桌面端共用同一份凭据，
    /// 而 ACP 的 `authenticate` 第一步就是 logout。别的 agent（claude/codex/gemini…）
    /// 用自己正常的 HOME 登录一次就行，隔离只会让用户莫名其妙地重登。
    static func shouldIsolateHome(executable: String) -> Bool {
        let name = (executable as NSString).lastPathComponent
        return name == "codebuddy" || name == "cbc"
    }

    /// agent 的 HOME 里有没有凭据。没隔离的 agent 一律当作「已有」，
    /// 免得替用户跳过一次本来就不需要的登录。
    private func hasStoredCredential() -> Bool {
        guard let home = child?.isolatedHome else { return true }
        let auth = (home as NSString).appendingPathComponent(
            "Library/Application Support/CodeBuddyExtension/Data/Public/auth")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: auth) else {
            return false
        }
        return files.contains { $0.hasSuffix(".info") }
    }

    private func launch(commandLine: String, cwd: String, path: String) async throws -> String {
        guard !commandLine.isEmpty else { throw AcpError.notConfigured }
        let tokens = AcpCodec.tokenize(commandLine)
        guard let program = tokens.first, !program.isEmpty else { throw AcpError.notConfigured }
        guard let executable = AcpCodec.resolveExecutable(program, path: path) else {
            throw AcpError.commandNotFound(program)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AcpError.badWorkspace(cwd)
        }

        stopChild("更换 agent 进程")

        let process = Process()
        let adjustment = AcpEnvironment.codebuddyLaunchAdjustment(executable: executable,
                                                                 arguments: Array(tokens.dropFirst()))
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = adjustment.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = AcpEnvironment.pathByPrependingNode(path)
        // 登录态隔离：见 shouldIsolateHome()。拿不到目录就维持原样，至少不挡住启动。
        let isolatedHome = AcpClient.shouldIsolateHome(executable: executable) ? AcpClient.agentHome() : nil
        if let isolatedHome {
            environment["HOME"] = isolatedHome
        }
        if adjustment.liteBundle {
            environment["CODEBUDDY_FORCE_LITE_WB_BUNDLE"] = "1"
        }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw AcpError.launch(error.localizedDescription)
        }
        processes.store(process)

        let seen = epoch
        let stdin = input.fileHandleForWriting
        let stdout = output.fileHandleForReading
        let stderr = errors.fileHandleForReading
        child = Child(process: process,
                      stdin: stdin,
                      stdout: stdout,
                      stderrHandle: stderr,
                      commandLine: commandLine,
                      cwd: cwd,
                      agentName: (program as NSString).lastPathComponent)
        child?.isolatedHome = isolatedHome
        // `FileHandle.bytes.lines` 在管道上经常只吐出第一行，后面的 session/new
        // 响应会一直停在缓冲区里。readabilityHandler 才能把后续帧读出来。
        stdout.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { await self.readerEnded(seen, reason: "进程已退出") }
                return
            }
            let copy = Data(data)
            Task { await self.consumeStdout(copy, epoch: seen) }
        }
        stderr.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let copy = Data(data)
            Task { await self.consumeStderr(copy, epoch: seen) }
        }
        process.terminationHandler = { _ in
            Task { await self.readerEnded(seen, reason: "进程已退出") }
        }

        do {
            // `npx -y <包>` 第一次要下载安装，20 秒根本不够。
            let coldStart = (program as NSString).lastPathComponent == "npx"
            let ready = try await rpc(AcpCodec.initializeRequest(id: allocate()),
                                     timeoutNanoseconds: coldStart ? 120_000_000_000 : 20_000_000_000,
                                     label: "initialize")
            guard isProtocolOne(ready["protocolVersion"]) else {
                let found = ready["protocolVersion"]?.canonicalID ?? "未知"
                throw AcpError.agent("这个 agent 的 ACP 版本是 \(found)，知枝只接版本 1。")
            }
            let info = ready["agentInfo"]
            let name = info?["title"]?.string ?? info?["name"]?.string ?? (program as NSString).lastPathComponent
            let version = info?["version"]?.string
            let label = version.map { "\(name) \($0)" } ?? name
            child?.agentName = label
            let methods = ready["authMethods"]?.array ?? []
            child?.authMethods = methods.compactMap { $0["id"]?.string }
            child?.authMethodNames = AcpCodec.authMethodNames(from: methods)
            child?.authMethodId = AcpCodec.browserAuthMethod(from: methods)
            return label
        } catch {
            let tail = child?.stderr.suffix(4).joined(separator: " | ") ?? ""
            stopChild("initialize 失败")
            if tail.isEmpty { throw error }
            throw AcpError.launch("\(error.localizedDescription) \(tail)")
        }
    }

    /// 发起登录并等到 `authenticate` 返回。登录没完成就返回 false。
    ///
    /// 登录页 URL 由 `_codebuddy.ai/authUrl` 通知推过来，runTurn 里的钩子负责打开，
    /// 这里只等 `authenticate` 兑现。
    private func login(yield: @escaping @Sendable (String) -> Void) async -> Bool {
        guard let method = child?.authMethodId else {
            // api-key / oauth 这类方法没法在面板里走完，别硬猜，直接告诉用户去终端登录。
            let names = (child?.authMethodNames).flatMap { $0.isEmpty ? nil : $0.joined(separator: "、") }
                ?? "它自己的登录命令"
            yield("\n这个 agent 还没有登录（它支持：\(names)）。"
                + "先在终端用它自己的方式登录一次，再问一次就行。\n")
            return false
        }
        yield("\n正在唤起登录，完成后会自动重试这一问。\n\n")
        do {
            _ = try await rpc(AcpCodec.authenticateRequest(id: allocate(), methodId: method),
                             timeoutNanoseconds: 180_000_000_000,
                             label: "登录")
            yield("登录完成，正在重新提问。\n\n")
            return true
        } catch {
            yield("\n登录没有完成：\(error.localizedDescription)\n"
                + "在打开的页面里登录成功后，再问一次就行。\n")
            return false
        }
    }

    private func closeQuietly(_ sessionId: String) async {
        guard child != nil else { return }
        do {
            _ = try await rpc(AcpCodec.closeRequest(id: allocate(), sessionId: sessionId),
                             timeoutNanoseconds: 5_000_000_000,
                             label: "session/close")
        } catch {
            return
        }
    }

    private func cancelSession(_ sessionId: String, promptKey: String?) {
        permissionTasks[sessionId]?.cancel()
        guard child != nil else { return }
        try? write(AcpCodec.cancelNotification(sessionId: sessionId))
        guard let promptKey else { return }
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await self.failPending(promptKey, AcpError.timeout("取消后 agent 没有结束这一轮"))
        }
    }

    private func rpc(_ payload: JSONValue,
                     timeoutNanoseconds: UInt64,
                     label: String,
                     existingKey: String? = nil) async throws -> JSONValue {
        let id = payload["id"] ?? .number(Double(allocate()))
        let key = existingKey ?? id.canonicalID ?? UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                let detail = await self.timeoutDetail(label)
                await self.failPending(key, AcpError.timeout(detail))
            }
            pending[key] = Waiter(resume: { continuation.resume(with: $0) }, timeout: timeout)
            do {
                try write(payload)
            } catch {
                pending.removeValue(forKey: key)?.timeout?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func consumeStdout(_ data: Data, epoch seen: Int) {
        guard seen == epoch else { return }
        stdoutBuffer.append(data)
        drain(&stdoutBuffer) { receive($0, epoch: seen) }
    }

    private func consumeStderr(_ data: Data, epoch seen: Int) {
        guard seen == epoch else { return }
        stderrBuffer.append(data)
        drain(&stderrBuffer) { noteStderr($0, epoch: seen) }
    }

    private func drain(_ buffer: inout Data, _ deliver: (String) -> Void) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(buffer.startIndex..<buffer.index(after: newline))
            guard let text = String(data: lineData, encoding: .utf8) else { continue }
            deliver(text)
        }
    }

    private func receive(_ line: String, epoch seen: Int) {
        guard seen == epoch, child != nil else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        trace("<<", trimmed)
        guard let inbound = AcpCodec.parseInbound(trimmed) else { return }
        switch inbound {
        case .result(let id, let result):
            succeed(id, result)
        case .failure(let id, let message, let needsAuth):
            if let key = id.canonicalID {
                failPending(key, needsAuth ? AcpError.authRequired(message) : AcpError.agent(message))
            }
        case .notification(let method, let params):
            if method == "_codebuddy.ai/authUrl", let url = params["authUrl"]?.string, !url.isEmpty {
                authURLHook?(url)
                return
            }
            guard method == "session/update",
                  let sessionId = params["sessionId"]?.string,
                  let update = params["update"] else { return }
            sinks[sessionId]?(update)
        case .request(let id, let method, let params):
            if method == "session/request_permission" {
                handlePermission(id: id, params: params)
            } else {
                try? write(AcpCodec.methodNotFound(id: id))
            }
        }
    }

    private func handlePermission(id: JSONValue, params: JSONValue) {
        guard let ask = AcpCodec.parsePermission(params) else {
            try? write(AcpCodec.permissionResult(id: id, outcome: .cancelled))
            return
        }
        let handler = permissions[ask.sessionId]
        let task = Task {
            let outcome: AcpPermissionOutcome
            if Task.isCancelled || ask.options.isEmpty {
                outcome = .cancelled
            } else if let handler {
                outcome = await handler(ask)
            } else {
                outcome = .cancelled
            }
            await self.replyPermission(id: id, outcome: outcome)
        }
        permissionTasks[ask.sessionId] = task
    }

    private func replyPermission(id: JSONValue, outcome: AcpPermissionOutcome) {
        let key = id.canonicalID ?? UUID().uuidString
        guard answeredPermissions.insert(key).inserted else { return }
        try? write(AcpCodec.permissionResult(id: id, outcome: outcome))
    }

    private func succeed(_ id: JSONValue, _ result: JSONValue) {
        guard let key = id.canonicalID, let waiter = pending.removeValue(forKey: key) else { return }
        waiter.timeout?.cancel()
        waiter.resume(.success(result))
    }

    private func timeoutDetail(_ label: String) -> String {
        let tail = child?.stderr.suffix(4).joined(separator: " | ") ?? ""
        return tail.isEmpty ? label : "\(label)；\(tail)"
    }

    private func failPending(_ key: String, _ error: Error) {
        guard let waiter = pending.removeValue(forKey: key) else { return }
        waiter.timeout?.cancel()
        waiter.resume(.failure(error))
    }

    private func failAll(_ reason: String) {
        let waiters = pending
        pending.removeAll()
        for (_, waiter) in waiters {
            waiter.timeout?.cancel()
            waiter.resume(.failure(AcpError.disconnected(reason)))
        }
    }

    private func noteStderr(_ line: String, epoch seen: Int) {
        guard seen == epoch, !line.isEmpty else { return }
        child?.stderr.append(line)
        if let count = child?.stderr.count, count > 40 {
            child?.stderr.removeFirst(count - 40)
        }
    }

    private func readerEnded(_ seen: Int, reason: String) {
        guard seen == epoch, child != nil else { return }
        let tail = child?.stderr.suffix(5).joined(separator: " | ") ?? ""
        let detail = tail.isEmpty ? reason : "\(reason)；\(tail)"
        stopChild(detail)
    }

    private func stopChild(_ reason: String) {
        epoch += 1
        let running = child
        child = nil
        sinks.removeAll()
        permissions.removeAll()
        for task in permissionTasks.values { task.cancel() }
        permissionTasks.removeAll()
        running?.process.terminationHandler = nil
        running?.stdout.readabilityHandler = nil
        running?.stderrHandle.readabilityHandler = nil
        if running?.process.isRunning == true {
            running?.process.terminate()
        }
        try? running?.stdin.close()
        processes.clear()
        answeredPermissions.removeAll()
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        failAll(reason)
    }

    /// 退出时调用。不等 actor，避免主线程正卡在权限询问上。
    public nonisolated func killForQuit() {
        processes.terminate()
    }

    private func write(_ value: JSONValue) throws {
        guard let child else { throw AcpError.disconnected("agent 没有在运行") }
        var data = try value.data()
        data.append(0x0A)
        do {
            try child.stdin.write(contentsOf: data)
        } catch {
            throw AcpError.disconnected(error.localizedDescription)
        }
        if let text = String(data: data, encoding: .utf8) {
            trace(">>", text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 抓 ACP 原始帧。`SPRIG_ACP_TRACE=/tmp/acp.log` 启动就能把收发两边都落到文件里，
    /// agent 答非所问或者干脆不答时，先看这个比看界面快。
    private func trace(_ direction: String, _ text: String) {
        guard let path = ProcessInfo.processInfo.environment["SPRIG_ACP_TRACE"] else { return }
        let line = "\(Self.traceClock.string(from: Date())) \(direction) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static let traceClock: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withFractionalSeconds]
        return formatter
    }()

    private func allocate() -> Int {
        idCounter += 1
        return idCounter
    }

    private func isProtocolOne(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if case .number(let number) = value, Int(number) == 1 { return true }
        if case .string(let text) = value, text == "1" { return true }
        return false
    }
}

private final class TurnState: @unchecked Sendable {
    var sawMessage = false
    var sawVisible = false
    var sawAuthURL = false
    var thoughts = ""
    var tools = Set<String>()
}

private final class FinishBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func yield(_ text: String, _ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        lock.lock()
        let closed = done
        lock.unlock()
        guard !closed, !text.isEmpty else { return }
        continuation.yield(text)
    }

    func finish(_ error: Error?, _ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func store(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let current = process
        lock.unlock()
        if current?.isRunning == true {
            current?.terminate()
        }
    }
}
