import Foundation

/// 通过 `acp-host` 守护进程和本机 agent 对话。
///
/// 和 `AcpClient` 的区别：这里不碰 ACP 协议本身，只跟一个子进程收发**一行一个 JSON**。
/// 登录、换模型、各家 agent 的脾气都收在守护进程里，app 这层不用再跟着协议改。
///
/// 关键点：守护进程**常驻**，而且**所有会话共用一条读取线程**。
/// 早先每个提问各建一个 readabilityHandler，第二个问题会把第一个的回调顶掉，
/// 结果旧答案画到新卡片上——现在按 `session` 字段分流。
public actor AcpHostClient {
    public static let shared = AcpHostClient()

    private var daemon: Daemon?
    private var nextSession = 0

    /// 启动时预热：把守护进程和会话先建起来。
    /// - Parameter warmModel: 顺便发一句极短的请求，把模型连接也焐热（会消耗一次极小额度）
    public func prewarm(agent: String, cwd: String, warmModel: Bool = false) async {
        guard let daemon = try? ensureDaemon() else { return }
        let session = allocateSession()
        let stream = daemon.open(session: session)

        daemon.send(["id": "1", "method": "session.start",
                     "params": ["agent": agent, "cwd": cwd]])

        let deadline = Date().addingTimeInterval(30)
        var prompted = false
        for await line in stream {
            if Date() > deadline { break }
            guard let event = Self.event(from: line) else { continue }
            switch event["event"] as? String {
            case "ready":
                guard warmModel else { daemon.close(session: session); return }
                if !prompted {
                    prompted = true
                    daemon.send(["id": "2", "method": "session.prompt",
                                 "params": ["session": session, "text": "ok"]])
                }
            case "done", "error":
                daemon.close(session: session)
                return
            default:
                continue
            }
        }
        daemon.close(session: session)
    }

    /// 让守护进程列出本机真的装了的 agent（预设和探测规则都在它那边）
    public func detectAgents() async -> [(id: String, name: String, command: String)] {
        guard let binary = Self.locateBinary() else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AcpEnvironment.searchPath()
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        defer { if process.isRunning { process.terminate() } }

        input.fileHandleForWriting.write(Data("{\"id\":\"1\",\"method\":\"agents.detect\"}\n".utf8))
        let data = output.fileHandleForReading.availableData
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return [] }
        return agents.compactMap { agent in
            guard let id = agent["id"] as? String,
                  let name = agent["name"] as? String,
                  let command = agent["command"] as? String else { return nil }
            return (id, name, command)
        }
    }

    /// 一轮对话产出的文本块（和 `AcpClient.ask` 同形，方便上层替换）
    public func ask(text: String,
                    agent: String,
                    cwd: String,
                    timeout: TimeInterval = 180,
                    onActivity: (@Sendable (String) -> Void)? = nil,
                    permission: @escaping @Sendable (AcpPermissionAsk) async -> AcpPermissionOutcome)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { outer in
            let task = Task {
                do {
                    try await self.run(text: text, agent: agent, cwd: cwd,
                                       timeout: timeout, permission: permission,
                                       activity: onActivity,
                                       yield: { outer.yield($0) })
                    outer.finish()
                } catch {
                    outer.finish(throwing: error)
                }
            }
            outer.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - 一轮对话

    private func run(text: String,
                     agent: String,
                     cwd: String,
                     timeout: TimeInterval,
                     permission: @escaping @Sendable (AcpPermissionAsk) async -> AcpPermissionOutcome,
                     activity: (@Sendable (String) -> Void)?,
                     yield: @escaping (String) -> Void) async throws
    {
        let daemon = try ensureDaemon()
        let session = allocateSession()
        let stream = daemon.open(session: session)
        defer { daemon.close(session: session) }

        daemon.send(["id": "1", "method": "session.start",
                     "params": ["agent": agent, "cwd": cwd]])

        let deadline = Date().addingTimeInterval(timeout)
        var prompted = false

        for await line in stream {
            if Task.isCancelled { return }
            if Date() > deadline {
                throw AcpError.agent("agent 超过 \(Int(timeout)) 秒没有结束。")
            }
            guard let event = Self.event(from: line) else { continue }

            switch event["event"] as? String {
            case "ready":
                if !prompted {
                    prompted = true
                    daemon.send(["id": "2", "method": "session.prompt",
                                 "params": ["session": session, "text": text]])
                }
            case "text":
                if let text = event["text"] as? String, !text.isEmpty { yield(text) }

            // 等待期的反馈：模型在想什么、打算跑什么工具
            case "thought":
                if let text = event["text"] as? String, !text.isEmpty {
                    activity?(String(text.prefix(60)))
                }
            case "tool":
                let title = event["title"] as? String ?? "工具调用"
                let status = event["status"] as? String ?? ""
                activity?(status.isEmpty ? title : "\(title)（\(status)）")
            case "permission":
                let request = event["request"] as? String ?? ""
                let title = event["title"] as? String ?? "请求权限"
                let options = (event["options"] as? [[String: Any]] ?? []).map {
                    AcpPermissionOption(id: $0["optionId"] as? String ?? "",
                                        name: $0["name"] as? String ?? "",
                                        kind: $0["kind"] as? String ?? "")
                }
                let ask = AcpPermissionAsk(sessionId: session, title: title, detail: "", options: options)
                Task { [weak daemon] in
                    let outcome = await permission(ask)
                    let option: String
                    switch outcome {
                    case .selected(let chosen): option = chosen
                    case .cancelled: option = "reject"
                    }
                    // 原样回传 optionId，"总是允许"才生效
                    daemon?.send(["id": "3", "method": "permission",
                                  "params": ["session": session, "request": request, "option": option]])
                }
            case "done":
                return
            case "error":
                let message = event["message"].map { "\($0)" } ?? "未知错误"
                throw AcpError.agent(message)
            default:
                continue
            }
        }

        stopDaemon()
        if Task.isCancelled { return }
        throw AcpError.launch("acp-host 提前退出了。")
    }

    // MARK: - 守护进程

    private func allocateSession() -> String {
        nextSession += 1
        return "s\(nextSession)"
    }

    private func ensureDaemon() throws -> Daemon {
        if let daemon, daemon.isRunning { return daemon }
        guard let binary = Self.locateBinary() else {
            throw AcpError.launch("找不到 acp-host。设置里填它的路径，或先在 acp-host 里 cargo build --release。")
        }
        let daemon = try Daemon(binary: binary,
                                environment: ProcessInfo.processInfo.environment,
                                traceToStderr: ProcessInfo.processInfo.environment["ACP_HOST_TRACE"] != nil)
        self.daemon = daemon
        return daemon
    }

    private func stopDaemon() {
        daemon?.terminate()
        daemon = nil
    }

    /// 守护进程路径：设置里优先（直接读 UserDefaults，Core 不依赖 app 层的 Settings）
    public static func locateBinary(configured: String? = nil) -> String? {
        let configured = configured ?? (UserDefaults.standard.string(forKey: "acpHostPath") ?? "")
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        let home = NSHomeDirectory()
        return ["\(home)/code/acp-host/target/release/acp-host",
                "/usr/local/bin/acp-host",
                "/opt/homebrew/bin/acp-host"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func event(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}

/// 一个常驻子进程 + 一条读取线程 + 按 session 分流
private final class Daemon {
    private let process: Process
    private let writer: FileHandle
    private var buffer = Data()
    private var routes: [String: AsyncStream<String>.Continuation] = [:]
    private let lock = NSLock()

    var isRunning: Bool { process.isRunning }

    init(binary: String, environment: [String: String], traceToStderr: Bool) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: binary)

        var env = environment
        env["PATH"] = AcpEnvironment.searchPath()
        // 免打扰模式：让守护进程给 CLI 补 --dangerously-skip-permissions
        if UserDefaults.standard.bool(forKey: "skipAgentPermissions") {
            env["ACP_HOST_SKIP_PERMISSIONS"] = "1"
        }
        process.environment = env

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = traceToStderr ? FileHandle.standardError : FileHandle.nullDevice

        try process.run()
        writer = input.fileHandleForWriting

        let reader = output.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data)
        }
    }

    func open(session: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            lock.lock()
            routes[session] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.routes[session] = nil
                self?.lock.unlock()
            }
        }
    }

    func close(session: String) {
        lock.lock()
        let route = routes.removeValue(forKey: session)
        lock.unlock()
        route?.finish()
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        lock.lock()
        writer.write(data)
        writer.write(Data([0x0A]))
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let all = routes
        routes.removeAll()
        lock.unlock()
        all.values.forEach { $0.finish() }
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let slice = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let text = String(data: slice, encoding: .utf8), !text.isEmpty { lines.append(text) }
        }
        let table = routes
        lock.unlock()

        for line in lines {
            // 每条事件都带 session；对不上就不认
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let session = object["session"] as? String, let route = table[session] else { continue }
            route.yield(line)
        }
    }
}
