import XCTest
@testable import SprigCore

final class AcpCodecTests: XCTestCase {
    func testWorkBuddyAcpUsesLiteBundleWhenHeadlessIsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-cbc-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("bin/codebuddy")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let adjusted = AcpEnvironment.codebuddyLaunchAdjustment(executable: executable.path, arguments: ["--acp"])
        // `--serve` 和 `--port` 缺一不可：少了端口它就不走 stdio，一个帧都不回。
        XCTAssertEqual(adjusted.arguments.first, "--serve")
        XCTAssertTrue(adjusted.arguments.contains("--acp"))
        XCTAssertTrue(adjusted.arguments.contains("--port"))
        XCTAssertTrue(adjusted.liteBundle)

        // 用户自己写了 --port 就不再插手
        let explicit = AcpEnvironment.codebuddyLaunchAdjustment(executable: executable.path,
                                                                arguments: ["--acp", "--port", "65000"])
        XCTAssertEqual(explicit.arguments.filter { $0 == "--port" }.count, 1)
        XCTAssertTrue(explicit.arguments.contains("65000"))

        try FileManager.default.createDirectory(at: root.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("dist/codebuddy-headless.js"))
        let full = AcpEnvironment.codebuddyLaunchAdjustment(executable: executable.path, arguments: ["--acp"])
        XCTAssertEqual(full.arguments, ["--acp"])
        XCTAssertFalse(full.liteBundle)
        try? FileManager.default.removeItem(at: root)
    }

    func testRefusalDetailReadsAuthErrorFromMeta() {
        let raw = #"{"code":-32000,"message":"Authentication required","data":{"details":"Authentication required. Please use /login command to sign in to your account","category":"auth"}}"#
        let result = JSONValue.object([
            "stopReason": .string("refusal"),
            "_meta": .object(["codebuddy.ai/errorMessage": .string(raw)]),
        ])
        let detail = AcpCodec.refusalDetail(result)
        XCTAssertTrue(detail.needsAuth)
        XCTAssertTrue(detail.text.contains("登录"))
    }

    /// 空 `_meta` 是常态：真实原因只在 agent 的 stderr 里，提示里必须带出来。
    func testRefusalDetailFallsBackToAgentStderr() {
        let result = JSONValue.object(["stopReason": .string("refusal")])
        let detail = AcpCodec.refusalDetail(result,
                                            stderrTail: ["Authentication required. Please use /login"])
        XCTAssertFalse(detail.needsAuth)
        XCTAssertTrue(detail.text.contains("refusal"))
        XCTAssertTrue(detail.text.contains("Authentication required"))
    }

    func testRefusalDetailHasNoDiagnosticsWhenNothingIsKnown() {
        let result = JSONValue.object(["stopReason": .string("refusal")])
        let detail = AcpCodec.refusalDetail(result)
        XCTAssertEqual(detail.text, "Agent 以 refusal 结束了这一轮，没有可显示的回答。")
    }

    /// 没有 `_meta`、只在 message 里写了 not logged in，也要认成鉴权问题。
    func testRefusalDetailRecognizesPlainNotLoggedInMessage() {
        let raw = #"{"message":"not logged in"}"#
        let result = JSONValue.object([
            "stopReason": .string("refusal"),
            "_meta": .object(["errorMessage": .string(raw)]),
        ])
        XCTAssertTrue(AcpCodec.refusalDetail(result).needsAuth)
    }

    /// 菜单栏应用的 PATH 里没有 nvm，`npx` 这类工具必须靠 searchPath 补进来，
    /// 否则解析不到就直接报「找不到 npx」。
    func testSearchPathCoversNodeDirectories() {
        let path = AcpEnvironment.searchPath().split(separator: ":").map(String.init)
        for directory in AcpEnvironment.nodeBinDirectories() {
            XCTAssertTrue(path.contains(directory), "searchPath 少了 node 目录 \(directory)")
        }
        let bare = "/usr/bin:/bin"
        let patched = AcpEnvironment.pathByPrependingNode(bare)
        XCTAssertTrue(patched.hasSuffix(bare) || patched.contains(bare), patched)
        if !AcpEnvironment.nodeBinDirectories().isEmpty {
            XCTAssertNotEqual(patched, bare, "没有把 node 目录补进去")
        }
    }

    /// 只认浏览器登录那几种 id：codex 的 api-key 不能被猜成 internal。
    func testBrowserAuthMethodOnlyPicksKnownBrowserFlows() {
        let codebuddy: [JSONValue] = [
            .object(["id": .string("external")]),
            .object(["id": .string("internal")]),
        ]
        XCTAssertEqual(AcpCodec.browserAuthMethod(from: codebuddy), "internal")

        let codex: [JSONValue] = [
            .object(["id": .string("api-key"), "name": .string("API Key")]),
            .object(["id": .string("chat-gpt"), "name": .string("ChatGPT")]),
        ]
        XCTAssertNil(AcpCodec.browserAuthMethod(from: codex))
        XCTAssertEqual(AcpCodec.authMethodNames(from: codex), ["API Key", "ChatGPT"])

        // cursor 只声明 cursor_login：名字像登录流程，应该认
        let cursor: [JSONValue] = [.object(["id": .string("cursor_login"), "name": .string("Cursor Login")])]
        XCTAssertEqual(AcpCodec.browserAuthMethod(from: cursor), "cursor_login")
    }

    /// 真实 `session/new` 返回的形状：models.availableModels + currentModelId。
    func testParseSessionStartReadsModels() throws {
        let raw = """
        {"sessionId":"s1","models":{"currentModelId":"fast-model","availableModels":[
          {"modelId":"fast-model","name":"快速","_meta":{"credits":"x0.15","maxInputTokens":300000}},
          {"modelId":"deep-model","name":"极致","_meta":{"credits":"x1.00"}}
        ]}}
        """
        let start = try XCTUnwrap(AcpCodec.parseSessionStart(XCTUnwrap(JSONValue.parse(line: raw))))
        XCTAssertEqual(start.sessionId, "s1")
        XCTAssertEqual(start.currentModelID, "fast-model")
        XCTAssertEqual(start.models.map(\.id), ["fast-model", "deep-model"])
        XCTAssertEqual(start.models[0].detail, "x0.15 · 300k")
        XCTAssertEqual(start.models[1].detail, "x1.00")
        XCTAssertEqual(start.modelConfigID, "model")
    }

    /// 会话选项里能认出「思考强度」（codebuddy 的 thought_level / codex 的 reasoning_effort）
    func testParseSessionStartReadsOptions() throws {
        let raw = """
        {"sessionId":"s3","configOptions":[
          {"id":"thought_level","name":"Thought","category":"thought_level","currentValue":"medium",
           "options":[{"value":"low","name":"低"},{"value":"high","name":"高"}]},
          {"id":"mode","name":"Mode","category":"mode","currentValue":"default","options":[]}
        ]}
        """
        let start = try XCTUnwrap(AcpCodec.parseSessionStart(XCTUnwrap(JSONValue.parse(line: raw))))
        XCTAssertEqual(start.options.count, 2)
        let thought = try XCTUnwrap(start.options.first { $0.isThoughtLevel })
        XCTAssertEqual(thought.id, "thought_level")
        XCTAssertEqual(thought.choices.map(\.value), ["low", "high"])
        XCTAssertFalse(start.options[1].isThoughtLevel)

        let reasoning = AcpConfigOption(id: "reasoning_effort", name: "Reasoning", category: "reasoning",
                                        currentValue: "medium", choices: [])
        XCTAssertTrue(reasoning.isThoughtLevel)
    }

    /// 只有 configOptions 的老形状也要认出来。
    func testParseSessionStartFallsBackToConfigOptions() throws {
        let raw = """
        {"sessionId":"s2","configOptions":[
          {"id":"mode","category":"mode","currentValue":"default","options":[]},
          {"id":"model","category":"model","currentValue":"balanced-model","options":[
            {"value":"balanced-model","name":"均衡","description":"x0.50"}
          ]}
        ]}
        """
        let start = try XCTUnwrap(AcpCodec.parseSessionStart(XCTUnwrap(JSONValue.parse(line: raw))))
        XCTAssertEqual(start.models.map(\.id), ["balanced-model"])
        XCTAssertEqual(start.models[0].name, "均衡")
        XCTAssertEqual(start.models[0].detail, "x0.50")
        XCTAssertEqual(start.currentModelID, "balanced-model")
    }

    func testSetConfigOptionRequestShape() throws {
        let request = AcpCodec.setConfigOptionRequest(id: 7, sessionId: "s1", configId: "model", value: "deep-model")
        XCTAssertEqual(request["method"]?.string, "session/set_config_option")
        XCTAssertEqual(request["params"]?["sessionId"]?.string, "s1")
        XCTAssertEqual(request["params"]?["configId"]?.string, "model")
        XCTAssertEqual(request["params"]?["value"]?.string, "deep-model")
    }

    func testTokenizeKeepsQuotedArgument() {
        XCTAssertEqual(AcpCodec.tokenize("agent acp"), ["agent", "acp"])
        XCTAssertEqual(AcpCodec.tokenize("codebuddy --acp"), ["codebuddy", "--acp"])
        XCTAssertEqual(AcpCodec.tokenize("\"my agent\" --acp"), ["my agent", "--acp"])
        XCTAssertEqual(AcpCodec.tokenize("a \"\" b"), ["a", "", "b"])
        XCTAssertEqual(AcpCodec.tokenize("say \"a \\\"b\\\"\""), ["say", "a \"b\""])
    }

    func testProgramNameSkipsNpx() {
        XCTAssertEqual(AcpCodec.programName(commandLine: "agent acp"), "agent")
        XCTAssertEqual(
            AcpCodec.programName(commandLine: "npx -y @agentclientprotocol/claude-agent-acp"),
            "claude-agent-acp"
        )
    }

    func testForwardTextKeepsOnlyTheLastUserMessage() {
        let messages = [
            ChatMessage.system("系统提示，不要转发"),
            ChatMessage.user("第一问"),
            ChatMessage.assistant("回答"),
            ChatMessage.user("   "),
            ChatMessage.user("真正要问的"),
        ]
        XCTAssertEqual(AcpCodec.forwardText(from: messages), "真正要问的")
        XCTAssertNil(AcpCodec.forwardText(from: [ChatMessage.system("只有系统")]))
    }

    func testInitializeAndPromptFrames() throws {
        let initLine = try String(data: AcpCodec.initializeRequest(id: 1).data(), encoding: .utf8)
        XCTAssertTrue(initLine?.contains("\"method\":\"initialize\"") == true)
        XCTAssertTrue(initLine?.contains("\"protocolVersion\":1") == true)

        let prompt = try JSONValue.parse(data: AcpCodec.promptRequest(id: 2, sessionId: "sess", text: "你好").data())
        XCTAssertEqual(prompt?["method"]?.string, "session/prompt")
        XCTAssertEqual(prompt?["params"]?["prompt"]?.array?.first?["text"]?.string, "你好")
        XCTAssertEqual(prompt?["params"]?["prompt"]?.array?.first?["type"]?.string, "text")
    }

    func testPermissionResultMatchesTheProtocolShape() throws {
        let selected = try JSONValue.parse(data: AcpCodec.permissionResult(id: .number(7), outcome: .selected("allow")).data())
        XCTAssertEqual(selected?["result"]?["outcome"]?["outcome"]?.string, "selected")
        XCTAssertEqual(selected?["result"]?["outcome"]?["optionId"]?.string, "allow")

        let cancelled = try JSONValue.parse(data: AcpCodec.permissionResult(id: .string("p"), outcome: .cancelled).data())
        XCTAssertEqual(cancelled?["id"]?.string, "p")
        XCTAssertEqual(cancelled?["result"]?["outcome"]?["outcome"]?.string, "cancelled")
        XCTAssertNil(cancelled?["result"]?["outcome"]?["optionId"])
    }

    func testRpcErrorPrefersData() {
        let error = JSONValue.object([
            "code": .number(-32603),
            "message": .string("Internal error"),
            "data": .object([
                "errorKind": .string("billing_error"),
                "message": .string("quota exceeded"),
            ]),
        ])
        XCTAssertEqual(AcpCodec.rpcErrorMessage(error), "Internal error — billing_error: quota exceeded")
    }

    func testMessageChunkReadsStringObjectAndArray() throws {
        let object = JSONValue.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("你好")]),
        ])
        XCTAssertEqual(AcpCodec.foldUpdate(object), .message("你好"))

        let plain = JSONValue.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .string("直出"),
        ])
        XCTAssertEqual(AcpCodec.foldUpdate(plain), .message("直出"))

        let parts = JSONValue.object([
            "sessionUpdate": .string("agent_thought_chunk"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("先")]),
                .object(["type": .string("text"), "text": .string("想")]),
            ]),
        ])
        XCTAssertEqual(AcpCodec.foldUpdate(parts), .thought("先想"))

        let usage = JSONValue.object(["sessionUpdate": .string("usage_update"), "used": .number(1)])
        XCTAssertEqual(AcpCodec.foldUpdate(usage), .ignore)
    }

    func testToolCallAndPermissionAsk() {
        let update = JSONValue.object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("call-1"),
            "title": .string("读取 README"),
            "kind": .string("read"),
        ])
        XCTAssertEqual(AcpCodec.foldUpdate(update), .tool(id: "call-1", title: "读取 README"))

        let ask = AcpCodec.parsePermission(.object([
            "sessionId": .string("sess-1"),
            "toolCall": .object([
                "toolCallId": .string("call-1"),
                "title": .string("读取 README"),
                "locations": .array([.object(["path": .string("/tmp/README")])]),
            ]),
            "options": .array([
                .object(["optionId": .string("allow"), "name": .string("允许一次"), "kind": .string("allow_once")]),
                .object(["optionId": .string("deny"), "name": .string("拒绝"), "kind": .string("reject_once")]),
            ]),
        ]))
        XCTAssertEqual(ask?.title, "读取 README")
        XCTAssertEqual(ask?.detail, "/tmp/README")
        XCTAssertEqual(ask?.options.map(\.id), ["allow", "deny"])
    }

    func testInboundSplitsResultNotificationAndRequest() {
        let result = AcpCodec.parseInbound("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"sess-1\"}}")
        guard case .result(_, let value) = result else {
            return XCTFail("不是响应")
        }
        XCTAssertEqual(value["sessionId"]?.string, "sess-1")

        let note = AcpCodec.parseInbound("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-1\"}}")
        guard case .notification(let method, _) = note else {
            return XCTFail("不是通知")
        }
        XCTAssertEqual(method, "session/update")

        let request = AcpCodec.parseInbound("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"session/request_permission\",\"params\":{}}")
        guard case .request(let id, let method, _) = request else {
            return XCTFail("不是请求")
        }
        XCTAssertEqual(id, .number(9))
        XCTAssertEqual(method, "session/request_permission")
    }
}
