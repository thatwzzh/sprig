import Foundation
import Network
import SprigCore

/// DSH 等外部宿主使用的本地 HTTP bridge。
///
/// 只监听 `127.0.0.1:53917`，提供 `POST /v1/explain`：
/// 宿主把「选区 + 对话上下文」直接 POST 进来，Sprig 建卡。
/// 浏览器侧请求会带 `Origin`，这里只放行本机页面（DSH Web GUI 也是 127.0.0.1）。
final class LocalBridge {
    static let shared = LocalBridge()
    static let port: UInt16 = 53_917

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.catking.sprig.bridge")

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: Self.port) else { return }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)

        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("[Sprig] bridge failed: \(error)")
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("[Sprig] bridge listening on 127.0.0.1:\(Self.port)")
        } catch {
            NSLog("[Sprig] bridge start failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP

    private struct Payload: Decodable {
        let selection: String
        let context: String?
        let question: String?
        let title: String?
        let appName: String?
        let sessionID: String?
        let messageRole: String?
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }
            if let error {
                NSLog("[Sprig] bridge read error: \(error)")
                connection.cancel()
                return
            }
            if let response = self.handleIfComplete(buffer: buffer) {
                self.send(response, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.read(connection, buffer: buffer)
        }
    }

    private func handleIfComplete(buffer: Data) -> Data? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return response(status: 400, json: ["ok": false, "error": "bad request"])
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return response(status: 400, json: ["ok": false, "error": "bad request"])
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return response(status: 400, json: ["ok": false, "error": "bad request"])
        }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let origin = headers["origin"]
        // DSH 在 Electron WebContentsView 里，Origin 可能是 127.0.0.1、localhost、null 或没有；
        // 这个 bridge 只能建解释卡、读不到本机数据，因此对来源不做拒绝，只做 CORS 放行。
        log("bridge request method=\(method) path=\(path) origin=\(origin ?? "nil")")

        if method == "OPTIONS" {
            log("bridge preflight allowed")
            return response(status: 204, json: [:], origin: origin, extra: preflightHeaders)
        }
        guard method == "POST", path == "/v1/explain" else {
            return response(status: 404, json: ["ok": false, "error": "not found"], origin: origin)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength > 0, contentLength <= 128 * 1_024 else {
            return response(status: 413, json: ["ok": false, "error": "payload too large"], origin: origin)
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= contentLength else { return nil }
        let body = buffer[bodyStart..<(bodyStart + contentLength)]
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else {
            return response(status: 400, json: ["ok": false, "error": "invalid json"], origin: origin)
        }
        let selection = payload.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else {
            return response(status: 400, json: ["ok": false, "error": "empty selection"], origin: origin)
        }

        var source = SelectionSource(kind: .agent,
                                     appName: payload.appName ?? "DeepSeek Harness",
                                     bundleID: "com.dsh.desktop",
                                     title: payload.title ?? "DSH 对话",
                                     conversation: ConversationRef(sessionID: payload.sessionID,
                                                                   messageRole: payload.messageRole))
        source.appName = payload.appName ?? source.appName
        let envelope = SelectionEnvelope(source: source,
                                         selection: selection,
                                         context: payload.context,
                                         question: payload.question)
        DispatchQueue.main.async {
            PanelController.shared.handleExternalSelection(envelope)
        }
        return response(status: 200, json: ["ok": true], origin: origin)
    }

    private func isAllowedOrigin(_ origin: String?) -> Bool { true }

    /// 调试用：bridge 请求写 /tmp，出问题时能确认到底有没有到知枝。
    private func log(_ line: String) {
        let path = "/tmp/sprig-bridge.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let value = "[\(stamp)] \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(value.utf8))
            try? handle.close()
        } else {
            try? value.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private var preflightHeaders: String {
        "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Content-Type\r\n"
            + "Access-Control-Max-Age: 86400\r\n"
    }

    private func response(status: Int,
                          json: [String: Any],
                          origin: String? = nil,
                          extra: String = "") -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : (status == 204 ? "No Content" : "Error")
        var allowOrigin = "*"
        if let origin, !origin.isEmpty, origin != "null" { allowOrigin = origin }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: \(allowOrigin)\r\n"
        head += "Access-Control-Allow-Private-Network: true\r\n"
        head += "Vary: Origin\r\n"
        head += "Connection: close\r\n"
        head += extra
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
