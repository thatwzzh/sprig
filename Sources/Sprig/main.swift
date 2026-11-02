import AppKit
import SprigCore

extension StreamSegment {
    var debugLine: String {
        switch self {
        case .text(let value): return "TEXT:\(value)"
        case .term(let value): return "TERM:\(value)"
        }
    }
}

// 无界面通道：验证 provider + 解析器，不需要窗口和屏幕录制权限
if CommandLine.arguments.contains("--headless-child") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let context = """
        RAG（Retrieval-Augmented Generation）是结合检索与生成的 AI 方法，通过从外部知识库检索相关信息，再基于这些信息生成回答。
        它解决了大语言模型知识更新慢、幻觉问题的问题。
        典型流程：查询 → 检索相关文档 → 生成回答。
        """
        let message = Prompt.childMessage(context: context, selection: "幻觉", question: nil)
        let provider = Settings.provider
        do {
            for try await chunk in provider.stream(messages: [
                .system(Prompt.contextual),
                .user(message),
            ]) {
                print(chunk, terminator: "")
            }
            print("")
        } catch {
            print("ERROR:\(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--headless"), index + 1 < CommandLine.arguments.count {
    // 后面所有参数都当作问题，方便一次量多轮的耗时
    let questions = Array(CommandLine.arguments[(index + 1)...])
    let question = questions[0]
    let semaphore = DispatchSemaphore(value: 0)

    Task {
        var parser = TermParser()
        let provider = Settings.provider
        do {
            let messages: [ChatMessage] = [.system(Prompt.answer), .user(question)]
            for try await chunk in provider.stream(messages: messages) {
                for segment in parser.consume(chunk) {
                    print(segment.debugLine)
                }
            }
            for segment in parser.flush() {
                print(segment.debugLine)
            }
        } catch {
            print("ERROR:\(error.localizedDescription)")
        }
        semaphore.signal()
    }

    semaphore.wait()
    exit(0)
}

// 打印实际用到的 acp-host 路径和它自报的版本（排查「装的是旧版」用）
if CommandLine.arguments.contains("--acp-host-info") {
    guard let binary = AcpHostClient.locateBinary() else {
        print("没找到 acp-host")
        exit(1)
    }
    print("路径: \(binary)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try? process.run()
    input.fileHandleForWriting.write(Data("{\"id\":\"1\",\"method\":\"version\"}\n".utf8))
    let data = output.fileHandleForReading.availableData
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let result = object["result"] as? [String: Any],
       let version = result["version"] as? String {
        print("版本: \(version)")
    } else {
        print("版本: 取不到")
    }
    exit(0)
}

// 让 daemon 列出本机装了哪些 agent
if CommandLine.arguments.contains("--host-agents") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let agents = await AcpHostClient.shared.detectAgents()
        for agent in agents { print("\(agent.id)\t\(agent.name)\t\(agent.command.prefix(80))") }
        print("共 \(agents.count) 个")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// 走 acp-host 守护进程跑一轮，验证 daemon 链路（不经过 UI）
if let index = CommandLine.arguments.firstIndex(of: "--acp-host-probe"),
   index + 1 < CommandLine.arguments.count {
    // 后面所有参数都当作问题，方便一次量多轮的耗时
    let questions = Array(CommandLine.arguments[(index + 1)...])
    let question = questions[0]
    let agent = CommandLine.arguments.firstIndex(of: "--agent").flatMap { i -> String? in
        i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
    } ?? "workbuddy"
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let cwd = Settings.acpWorkspacePath
        let stream = await AcpHostClient.shared.ask(text: question, agent: agent, cwd: cwd,
                                                    permission: { _ in .selected("allow") })
        if CommandLine.arguments.contains("--prewarm") {
            await AcpHostClient.shared.prewarm(agent: agent, cwd: cwd)
        }
        var first = true
        for question in questions {
            let started = Date()
            var firstChar: Date?
            let stream = await AcpHostClient.shared.ask(text: question, agent: agent, cwd: cwd,
                                                        permission: { _ in .selected("allow") })
            do {
                for try await chunk in stream {
                    if firstChar == nil { firstChar = Date() }
                    print(chunk, terminator: "")
                }
                print("")
                let head = firstChar.map { String(format: "%.2f", $0.timeIntervalSince(started)) } ?? "-"
                let total = String(format: "%.2f", Date().timeIntervalSince(started))
                print("[\(first ? "冷" : "热")] 首字 \(head)s  总计 \(total)s")
                first = false
            } catch {
                print("ERROR: \(error.localizedDescription)")
                break
            }
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// 让 daemon 列出本机装了哪些 agent
if CommandLine.arguments.contains("--host-agents") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let agents = await AcpHostClient.shared.detectAgents()
        for agent in agents { print("\(agent.id)\t\(agent.name)\t\(agent.command.prefix(80))") }
        print("共 \(agents.count) 个")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// 走 acp-host 守护进程跑一轮，验证 daemon 链路（不经过 UI）
if let index = CommandLine.arguments.firstIndex(of: "--acp-host-probe"),
   index + 1 < CommandLine.arguments.count {
    // 后面所有参数都当作问题，方便一次量多轮的耗时
    let questions = Array(CommandLine.arguments[(index + 1)...])
    let question = questions[0]
    let agent = CommandLine.arguments.firstIndex(of: "--agent").flatMap { i -> String? in
        i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
    } ?? "workbuddy"
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let cwd = Settings.acpWorkspacePath
        let stream = await AcpHostClient.shared.ask(text: question, agent: agent, cwd: cwd,
                                                    permission: { _ in .selected("allow") })
        if CommandLine.arguments.contains("--prewarm") {
            await AcpHostClient.shared.prewarm(agent: agent, cwd: cwd)
        }
        var first = true
        for question in questions {
            let started = Date()
            var firstChar: Date?
            let stream = await AcpHostClient.shared.ask(text: question, agent: agent, cwd: cwd,
                                                        permission: { _ in .selected("allow") })
            do {
                for try await chunk in stream {
                    if firstChar == nil { firstChar = Date() }
                    print(chunk, terminator: "")
                }
                print("")
                let head = firstChar.map { String(format: "%.2f", $0.timeIntervalSince(started)) } ?? "-"
                let total = String(format: "%.2f", Date().timeIntervalSince(started))
                print("[\(first ? "冷" : "热")] 首字 \(head)s  总计 \(total)s")
                first = false
            } catch {
                print("ERROR: \(error.localizedDescription)")
                break
            }
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
