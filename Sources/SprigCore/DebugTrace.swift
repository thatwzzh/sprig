import Foundation

/// 轻量调试追踪：写到 /tmp/sprig-trace.log。
/// 用于排查「卡片一直生成中」这类只在 app 内出现、CLI 复现不了的问题。
public enum DebugTrace {
    private static let path = "/tmp/sprig-trace.log"
    private static let lock = NSLock()

    public static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
