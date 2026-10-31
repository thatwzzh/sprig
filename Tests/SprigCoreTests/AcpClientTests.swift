import XCTest
@testable import SprigCore

final class AcpClientTests: XCTestCase {
    private let python = "/usr/bin/python3"

    func testCommandNotFound() async throws {
        let client = AcpClient()
        do {
            _ = try await client.probe(commandLine: "sprig-missing-acp-binary",
                                       cwd: NSTemporaryDirectory(),
                                       path: "/usr/bin:/bin")
            XCTFail("应该找不到命令")
        } catch let error as AcpError {
            guard case .commandNotFound(let name) = error else {
                return XCTFail("意外错误 \(error)")
            }
            XCTAssertEqual(name, "sprig-missing-acp-binary")
        }
        await client.shutdown()
    }

    func testMissingWorkspace() async throws {
        let client = AcpClient()
        do {
            _ = try await client.probe(commandLine: "/bin/echo",
                                       cwd: "/tmp/sprig-acp-missing-\(UUID().uuidString)",
                                       path: "/bin:/usr/bin")
            XCTFail("目录不存在时应该失败")
        } catch let error as AcpError {
            guard case .badWorkspace = error else {
                return XCTFail("意外错误 \(error)")
            }
        }
        await client.shutdown()
    }

    func testFakeAgentStreamsThePromptAndAToolLine() async throws {
        try await requirePython()
        let script = try writeFakeAgent()
        let client = AcpClient()
        let text = try await collect(client.ask(
            text: "什么是检索",
            commandLine: "\(python) -u \(script.path)",
            cwd: script.directory,
            path: "/usr/bin:/bin"
        ) { _ in .cancelled })
        await client.shutdown()
        XCTAssertTrue(text.contains("· 工具：查资料"), text)
        XCTAssertTrue(text.contains("答：什么是检索"), text)
        XCTAssertFalse(text.contains("系统提示"))
    }

    func testPermissionSelectionIsReturnedToTheAgent() async throws {
        try await requirePython()
        let script = try writeFakeAgent()
        let client = AcpClient()
        let text = try await collect(client.ask(
            text: "NEED-PERMISSION",
            commandLine: "\(python) -u \(script.path)",
            cwd: script.directory,
            path: "/usr/bin:/bin"
        ) { ask in
            XCTAssertEqual(ask.title, "读取 README")
            XCTAssertEqual(ask.options.map(\.id), ["allow", "deny"])
            return .selected("allow")
        })
        await client.shutdown()
        XCTAssertTrue(text.contains("许可=allow"), text)
    }

    func testProbeReportsTheAgentName() async throws {
        try await requirePython()
        let script = try writeFakeAgent()
        let client = AcpClient()
        let name = try await client.probe(commandLine: "\(python) -u \(script.path)",
                                          cwd: script.directory,
                                          path: "/usr/bin:/bin")
        let answer = try await collect(client.ask(
            text: "第二次",
            commandLine: "\(python) -u \(script.path)",
            cwd: script.directory,
            path: "/usr/bin:/bin"
        ) { _ in .cancelled })
        await client.shutdown()
        XCTAssertEqual(name, "fake-agent 0")
        XCTAssertTrue(answer.contains("答：第二次"), answer)
    }

    private func requirePython() throws {
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("没有 \(python)，跳过 ACP 进程测试")
        }
    }

    private func writeFakeAgent() throws -> (path: String, directory: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprig-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake_agent.py")
        try Self.fakeAgentSource.write(to: script, atomically: true, encoding: .utf8)
        return (script.path, directory.path)
    }

    /// 没登录的 agent 在 `session/new` 就回 `data.category = auth`，
    /// 设置页的「测试全部」要能把这种情况标成「未登录」而不是「失败」。
    func testProbeStatusReportsNeedsLogin() async throws {
        try await requirePython()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("auth_agent.py")
        try Self.authAgentSource.write(to: script, atomically: true, encoding: .utf8)

        let client = AcpClient()
        let status = await client.probeStatus(commandLine: "\(python) -u \(script.path)",
                                              cwd: directory.path,
                                              path: "/usr/bin:/bin")
        await client.shutdown()
        guard case .needsLogin(let methods) = status else {
            return XCTFail("应该判成未登录，实际 \(status)")
        }
        XCTAssertTrue(methods.contains("网页登录"), methods)
    }

    private static let authAgentSource = """
    import json, sys

    def send(obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

    while True:
        line = sys.stdin.readline()
        if line == "":
            raise SystemExit(0)
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": 1,
                "agentCapabilities": {},
                "agentInfo": {"name": "auth-agent", "version": "0"},
                "authMethods": [{"id": "internal", "name": "网页登录"}],
            }})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": mid, "error": {
                "code": -32000,
                "message": "Authentication required",
                "data": {"category": "auth"},
            }})
        elif method == "authenticate":
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": "登录被拒绝"}})
    """

    /// `set_config_option` 被拒时要退到 legacy 的 `session/set_model`。
    /// 这两种实现在本机都真实存在（codebuddy / codex-acp），服务端行为照抄。
    func testModelSwitchFallsBackToLegacySetModel() async throws {
        try await requirePython()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("model_agent.py")
        try Self.modelAgentSource.write(to: script, atomically: true, encoding: .utf8)

        let client = AcpClient()
        let text = try await collect(client.ask(
            text: "换模型",
            commandLine: "\(python) -u \(script.path)",
            cwd: directory.path,
            path: "/usr/bin:/bin",
            model: "deep-model"
        ) { _ in .cancelled })
        await client.shutdown()
        XCTAssertTrue(text.contains("legacy:deep-model"), text)
    }

    private static let modelAgentSource = """
    import json, sys

    def send(obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

    while True:
        line = sys.stdin.readline()
        if line == "":
            raise SystemExit(0)
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": 1, "agentCapabilities": {},
                "agentInfo": {"name": "model-agent", "version": "0"},
            }})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "sessionId": "sess-m",
                "configOptions": [{"id": "model", "category": "model", "currentValue": "fast-model",
                                   "options": [{"value": "fast-model", "name": "快速"},
                                               {"value": "deep-model", "name": "极致"}]}],
            }})
        elif method == "session/set_config_option":
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "Invalid params"}})
        elif method == "session/set_model":
            model = msg["params"]["modelId"]
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sess-m",
                "update": {"sessionUpdate": "agent_message_chunk",
                           "content": {"type": "text", "text": "legacy:" + model}},
            }})
        elif method == "session/prompt":
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    """

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for try await chunk in stream {
                    text += chunk
                }
                return text
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw AcpError.timeout("测试")
            }
            let text = try await group.next() ?? ""
            group.cancelAll()
            return text
        }
    }

    private static let fakeAgentSource = """
    import json, sys

    def send(obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

    def recv():
        while True:
            line = sys.stdin.readline()
            if line == "":
                raise SystemExit(0)
            line = line.strip()
            if line:
                return json.loads(line)

    while True:
        msg = recv()
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": 1,
                "agentCapabilities": {},
                "agentInfo": {"name": "fake-agent", "version": "0"},
            }})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "sess-1"}})
        elif method == "session/prompt":
            text = msg["params"]["prompt"][0]["text"]
            if "NEED-PERMISSION" in text:
                send({"jsonrpc": "2.0", "id": 42, "method": "session/request_permission", "params": {
                    "sessionId": "sess-1",
                    "toolCall": {"toolCallId": "call-1", "title": "读取 README", "kind": "read"},
                    "options": [
                        {"optionId": "allow", "name": "允许一次", "kind": "allow_once"},
                        {"optionId": "deny", "name": "拒绝", "kind": "reject_once"},
                    ],
                }})
                reply = recv()
                chosen = reply.get("result", {}).get("outcome", {}).get("optionId", "cancelled")
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": "sess-1",
                    "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "许可=" + str(chosen)}},
                }})
            else:
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": "sess-1",
                    "update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "查资料", "kind": "search", "status": "pending"},
                }})
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": "sess-1",
                    "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "答：" + text}},
                }})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        elif method == "session/cancel":
            pass
        elif method == "session/close":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif method is not None and mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    """
}
