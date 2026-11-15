import Foundation

/// 粗粒度 token 估算（不依赖模型分词器）。
///
/// 预算目前仍按字符数控制，这个估算只用于「告诉用户/调试」上下文大概占多少 token。
/// 系数按 tiktoken（cl100k/o200k）对中英混排的实测校准：
/// - CJK ≈ 0.9 token/字
/// - 其余（英文、标点、代码）≈ 1/3 token/字符
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value)
                || (0xF900...0xFAFF).contains(value) {
                cjk += 1
            } else {
                other += 1
            }
        }
        let tokens = Double(cjk) * 0.9 + Double(other) / 3.0
        return max(1, Int(tokens.rounded(.up)))
    }

    /// 给 UI / 调试用的短描述：`511 字 ≈ 212 tokens`
    public static func describe(_ text: String) -> String {
        "\(text.count) 字 ≈ \(estimate(text)) tokens"
    }
}
