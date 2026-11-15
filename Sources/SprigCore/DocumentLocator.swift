import Foundation

/// 配置里的 Obsidian 库（名称 + 根目录）。名称用于解析窗口标题里的「笔记名 - 库名」。
public struct ObsidianVault: Codable, Sendable, Equatable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct LocatedDocument: Sendable, Equatable {
    public var path: String
    public var vaultName: String?

    public init(path: String, vaultName: String? = nil) {
        self.path = path
        self.vaultName = vaultName
    }
}

/// 从窗口标题反查本地文档。
///
/// 只在配置了「文档文件夹 / Obsidian 库」时才工作；不自动扫描 ~/Documents。
/// 同一 basename 可能有多份，调用方必须在读到的文件里真的找到选区才采用（见 Resolver）。
public enum DocumentLocator {
    static let maxFiles = 20_000
    static let maxDepth = 8
    static let supportedExtensions: Set<String> = ["md", "markdown", "txt",
                                                    "pdf", "docx", "pptx", "xlsx"]

    public static func locate(title: String?,
                              documentFolders: [String],
                              vaults: [ObsidianVault]) -> LocatedDocument? {
        guard let title, !title.isEmpty else { return nil }
        let candidates = titleCandidates(from: title, vaults: vaults)
        guard !candidates.isEmpty else { return nil }

        // Obsidian 库优先：vault 名称本身是强线索
        for vault in vaults {
            let root = URL(fileURLWithPath: vault.path, isDirectory: true)
            for candidate in candidates {
                if let url = findFile(named: candidate, in: root) {
                    return LocatedDocument(path: url.path, vaultName: vault.name)
                }
            }
        }

        let indexed = indexFolders(documentFolders)
        for candidate in candidates {
            if let path = indexed[candidate.lowercased()]?.sorted().first {
                return LocatedDocument(path: path)
            }
        }
        return nil
    }

    /// 从窗口标题里拆出候选笔记名：
    /// 「RAG 笔记 - notes」→ ["RAG 笔记 - notes", "RAG 笔记"]；
    /// 「文件.md — 项目」→ ["文件.md — 项目", "文件.md", "文件", "项目"]。
    static func titleCandidates(from raw: String, vaults: [ObsidianVault]) -> [String] {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return [] }

        var result: [String] = [working]
        // 先剥掉「 - Obsidian」「 — Visual Studio Code」这类 App 后缀，再剥 vault 名
        let appSuffixes = ["Obsidian", "Typora", "Visual Studio Code", "VS Code",
                           "Cursor", "Sublime Text", "TextEdit", "Bear", "iA Writer"]
        for app in appSuffixes {
            for separator in [" - ", " — ", " | "] {
                let suffix = separator + app
                if working.hasSuffix(suffix) {
                    working = String(working.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    result.append(working)
                }
            }
        }
        for vault in vaults where !vault.name.isEmpty {
            for separator in [" - ", " — ", " | "] {
                let suffix = separator + vault.name
                if working.hasSuffix(suffix) {
                    working = String(working.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    result.append(working)
                }
            }
        }
        result.append((working as NSString).deletingPathExtension)
        for separator in [" - ", " — ", " | "] {
            result.append(contentsOf: working.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        result = result.filter { !$0.isEmpty && $0 != "." && $0 != "/" }
        var seen = Set<String>()
        return result.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - 扫描

    private static func indexFolders(_ folders: [String]) -> [String: [String]] {
        var index: [String: [String]] = [:]
        for folder in folders {
            let root = URL(fileURLWithPath: folder, isDirectory: true)
            enumerate(root) { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                index[name, default: []].append(url.path)
            }
        }
        return index
    }

    private static func findFile(named name: String, in root: URL) -> URL? {
        for ext in supportedExtensions {
            let direct = root.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        var found: URL?
        enumerate(root) { url in
            guard found == nil else { return }
            let base = url.deletingPathExtension().lastPathComponent
            if base.caseInsensitiveCompare(name) == .orderedSame {
                found = url
            }
        }
        return found
    }

    private static func enumerate(_ root: URL, _ visit: (URL) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return }

        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen > maxFiles { break }
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                let name = url.lastPathComponent.lowercased()
                if [".git", "node_modules", "dist", "build", ".build"].contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            visit(url)
        }
    }
}
