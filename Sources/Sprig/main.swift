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
        let provider = OllamaProvider(baseURL: Settings.baseURL, model: Settings.model)
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
    let question = CommandLine.arguments[index + 1]
    let semaphore = DispatchSemaphore(value: 0)

    Task {
        var parser = TermParser()
        let provider = OllamaProvider(baseURL: Settings.baseURL, model: Settings.model)
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
