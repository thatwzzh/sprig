import Foundation

/// 流式解析器：把模型输出里的 ⟦术语⟧ 拆成结构化片段。
///
/// 为什么用 ⟦⟧ 而不是 [[ ]]：后者会和 Markdown 链接语法打架，模型也更容易写错。
/// 为什么要在流式过程中解析：术语必须「边出边可点」，不能等整段回答结束再抽取。
///
/// 契约：
/// - 未闭合的术语在流式过程中**留在缓冲区**，不提前吐出（否则会闪出半个词）。
/// - 流结束时调用 flush()，残留按普通文本吐出，且丢掉标记本身。
/// - 换行 / 超长 / 嵌套开始符 → 判定模型跑偏，退化为普通文本，并吞掉后到的 ⟧。
public enum StreamSegment: Equatable, Sendable {
    case text(String)
    case term(String)
}

public struct TermParser: Sendable {
    private var pending: String = ""
    private var insideTerm = false
    private var termBuffer: String = ""
    private var expectClosing = false
    private let maxTermLength: Int

    public init(maxTermLength: Int = 40) {
        self.maxTermLength = maxTermLength
    }

    public mutating func consume(_ chunk: String) -> [StreamSegment] {
        pending.append(chunk)
        var output: [StreamSegment] = []
        var plain = ""

        func flushPlain() {
            guard !plain.isEmpty else { return }
            output.append(.text(plain))
            plain = ""
        }

        while let ch = pending.first {
            pending.removeFirst()

            if insideTerm {
                if ch == "⟧" {
                    let term = termBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    termBuffer = ""
                    insideTerm = false
                    guard !term.isEmpty else { continue }
                    flushPlain()
                    output.append(.term(term))
                } else if ch == "⟦" {
                    // 嵌套开始符：前一个标记作废，重新开始
                    plain += termBuffer
                    termBuffer = ""
                } else if ch == "\n" || termBuffer.count >= maxTermLength {
                    // 模型跑偏：标记当普通文本，不再等闭合
                    plain += termBuffer
                    plain.append(ch)   // 长度溢出时这个字符是正文，不能丢
                    termBuffer = ""
                    insideTerm = false
                    expectClosing = true
                } else {
                    termBuffer.append(ch)
                }
            } else if ch == "⟦" {
                insideTerm = true
            } else if ch == "⟧" && expectClosing {
                expectClosing = false
            } else {
                plain.append(ch)
            }
        }

        flushPlain()
        return output
    }

    /// 流结束时调用：把没闭合的残留按普通文本吐出（丢掉标记本身）。
    public mutating func flush() -> [StreamSegment] {
        var output: [StreamSegment] = []
        var leftover = ""
        if insideTerm {
            leftover += termBuffer
            termBuffer = ""
            insideTerm = false
        }
        leftover += pending
        pending = ""
        expectClosing = false
        if !leftover.isEmpty { output.append(.text(leftover)) }
        return output
    }
}
