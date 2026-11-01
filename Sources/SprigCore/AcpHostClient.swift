import Foundation

/// 通过 `acp-host` 守护进程和本机 agent 对话。
///
/// 和 `AcpClient` 的区别：这里不碰 ACP 协议本身，只跟一个子进程收发**一行一个 JSON**。
/// 登录、换模型、各家 agent 的脾气都收在守护进程里，app 这层不用再跟着协议改。
public actor AcpHostClient {
    public static let shared = AcpHostClient()

    /// 常驻的守护进程：每问一次都重起 node CLI 要多花 1~2 秒，这里复用
    private var daemon: (process: Process, input: Pipe, output: Pipe)?

    /// 守护进程路径：设置里优先（直接读 UserDefaults，Core 不依赖 app 层的 Settings），
    /// 其次是仓库里的构建产物和 PATH。
    public static func locateBinary(configured: String? = nil) -> String? {
        let configured = configured ?? (UserDefaults.standard.string(forKey: "acpHostPath") ?? "")
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/code/acp-host/target/release/acp-host",
            "/usr/local/bin/acp-host",
            "/opt/homebrew/bin/acp-host",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 一轮对话产出的文本块（和 `AcpClient.ask` 同形，方便上层替换）
    public func ask(text: String,
                    agent: String,
                    cwd: String,
                    timeout: TimeInterval = 180,
                    permission: @escaping @Sendable (AcpPermissionAsk) async -> AcpPermissionOutcome)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(text: text, agent: agent, cwd: cwd,
                                       timeout: timeout, permission: permission,
                                       yield: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// 启动时预热：把守护进程和会话先建起来，第一问不用再等冷启动
    public func prewarm(agent: String, cwd: String) async {
        guard let (input, output, _) = try? ensureDaemon() else { return }
        let lines = LineFeed(handle: output.fileHandleForReading)
        defer { lines.stop() }

        let payload: [String: Any] = ["id": "1", "method": "session.start",
                                      "params": ["agent": agent, "cwd": cwd]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))

        let deadline = Date().addingTimeInterval(20)
        for await line in lines.stream {
            if Date() > deadline { break }
            guard let raw = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { continue }
            if object["event"] as? String == "ready" { return }
        }
    }

    // MARK: - 一轮对话

    private func run(text: String,
                     agent: String,
                     cwd: String,
                     timeout: TimeInterval,
                     permission: @escaping @Sendable (AcpPermissionAsk) async -> AcpPermissionOutcome,
                     yield: @escaping (String) -> Void) async throws
    {
        let (input, output, process) = try ensureDaemon()
        defer { /* 进程常驻，不在这里收尾 */ }

        let writer = input.fileHandleForWriting
        let session = "s1"
        let lock = NSLock()
        func send(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            lock.lock()
            writer.write(data)
            writer.write(Data([0x0A]))
            lock.unlock()
        }

        let lines = LineFeed(handle: output.fileHandleForReading)
        defer { lines.stop() }

        send(["id": "1", "method": "session.start",
              "params": ["agent": agent, "cwd": cwd]])

        let deadline = Date().addingTimeInterval(timeout)
        var prompted = false

        for await line in lines.stream {
            if Task.isCancelled { return }
            if Date() > deadline {
                throw AcpError.agent("agent 超过 \(Int(timeout)) 秒没有结束。")
            }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            switch object["event"] as? String {
            case "ready":
                if !prompted {
                    prompted = true
                    send(["id": "2", "method": "session.prompt",
                          "params": ["session": session, "text": text]])
                }
            case "authenticated":
                continue
            case "text":
                if let text = object["text"] as? String, !text.isEmpty { yield(text) }
            case "permission":
                let request = object["request"] as? String ?? ""
                let title = object["title"] as? String ?? "请求权限"
                let options = (object["options"] as? [[String: Any]] ?? []).map {
                    AcpPermissionOption(id: $0["optionId"] as? String ?? "",
                                        name: $0["name"] as? String ?? "",
                                        kind: $0["kind"] as? String ?? "")
                }
                let ask = AcpPermissionAsk(sessionId: session, title: title, detail: "", options: options)
                Task {
                    let outcome = await permission(ask)
                    let option: String
                    switch outcome {
                    case .selected(let chosen): option = chosen
                    case .cancelled: option = "reject"
                    }
                    // 原样回传 optionId，"总是允许"才生效
                    send(["id": "3", "method": "permission",
                          "params": ["session": session, "request": request, "option": option]])
                }
            case "done":
                return
            case "error":
                let message = object["message"].map { "\($0)" } ?? "未知错误"
                throw AcpError.agent(message)
            default:
                continue
            }
        }

        // 进程没了但没收到 done：下次提问重起
        stopDaemon()
        if Task.isCancelled { return }
        throw AcpError.launch("acp-host 提前退出了。")
    }
}

private extension AcpHostClient {
    func ensureDaemon() throws -> (Pipe, Pipe, Process) {
        if let daemon, daemon.process.isRunning {
            return (daemon.input, daemon.output, daemon.process)
        }
        guard let binary = Self.locateBinary() else {
            throw AcpError.launch("找不到 acp-host。设置里填它的路径，或先在 acp-host 里 cargo build --release。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = AcpEnvironment.searchPath()
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // 排查时把子进程 stderr 透出来（ACP_HOST_TRACE=1）
        process.standardError = ProcessInfo.processInfo.environment["ACP_HOST_TRACE"] != nil
            ? FileHandle.standardError : FileHandle.nullDevice

        try process.run()
        daemon = (process, input, output)
        return (input, output, process)
    }

    func stopDaemon() {
        if let daemon, daemon.process.isRunning { daemon.process.terminate() }
        daemon = nil
    }
}

/// 把子进程 stdout 按行切出来（readabilityHandler 在后台线程，用 AsyncStream 转交给上层）
private final class LineFeed {
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private var buffer = Data()
    private var handle: FileHandle?

    init(handle: FileHandle) {
        var escape: AsyncStream<String>.Continuation!
        stream = AsyncStream { escape = $0 }
        continuation = escape
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                self.finish()
                return
            }
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                if let text = String(data: lineData, encoding: .utf8), !text.isEmpty {
                    self.continuation.yield(text)
                }
            }
        }
    }

    func stop() {
        handle?.readabilityHandler = nil
        handle = nil
        continuation.finish()
    }

    private func finish() {
        handle?.readabilityHandler = nil
        continuation.finish()
    }
}
