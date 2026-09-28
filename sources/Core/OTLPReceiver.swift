import CryptoKit
import Foundation
import Network

public struct TelemetryConfiguration: Codable, Sendable {
    public let version: Int
    public let token: String
    public var port: UInt16

    public init(port: UInt16 = 0) {
        version = 1
        token = SymmetricKey(size: .bits256).withUnsafeBytes {
            $0.map { String(format: "%02x", $0) }.joined()
        }
        self.port = port
    }

    public func validate() throws {
        guard version == 1, CopilotOTelNormalizer.validHex(token, count: 64) else { throw TelemetryError.invalid }
    }

    public func endpoint(_ source: UsageSource) -> String {
        "http://127.0.0.1:\(port)/\(token)/\(source.rawValue)"
    }
}

public struct OTLPRequest {
    public let source: UsageSource
    public let signal: String
    public let body: Data

    public static func parse(_ data: Data, configuration: TelemetryConfiguration) throws -> Self? {
        guard data.count <= CopilotOTelNormalizer.bodyLimit + 16_384 else { throw TelemetryError.capacity }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16_384 else { throw TelemetryError.capacity }
            return nil
        }
        guard boundary.lowerBound <= 16_384,
              let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw TelemetryError.invalid }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw TelemetryError.invalid }
        let words = first.split(separator: " ")
        guard words.count == 3, words[0] == "POST", words[2] == "HTTP/1.1" else { throw TelemetryError.unsupported }
        let path = words[1].split(separator: "/", omittingEmptySubsequences: false)
        guard path.count >= 3, path[0].isEmpty, path[1] == configuration.token,
              let source = UsageSource(rawValue: String(path[2])), source != .cli else {
            throw TelemetryError.unauthorized
        }
        // Agent Host can send both traces and metrics to the configured non-root URL.
        let directEndpoint = source == .vscodeCopilot && path.count == 3
        guard directEndpoint ||
              (path.count == 5 && path[3] == "v1" && ["traces", "metrics", "logs"].contains(path[4])) else {
            throw TelemetryError.unauthorized
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw TelemetryError.invalid }
            let key = line[..<colon].lowercased()
            guard fields[key] == nil else { throw TelemetryError.invalid }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["origin"] == nil, fields["trailer"] == nil,
              fields["content-encoding"] == nil || fields["content-encoding"] == "identity",
              fields["content-type"]?.split(separator: ";").first == "application/json"
        else { throw TelemetryError.unsupported }
        let body: Data
        if let encoding = fields["transfer-encoding"] {
            guard encoding.lowercased() == "chunked", fields["content-length"] == nil else {
                throw TelemetryError.unsupported
            }
            guard let decoded = try chunkedBody(data, start: boundary.upperBound) else { return nil }
            body = decoded
        } else {
            guard let lengthText = fields["content-length"], !lengthText.isEmpty,
                  lengthText.allSatisfy(\.isNumber), let length = Int(lengthText), length > 0 else {
                throw TelemetryError.unsupported
            }
            guard length <= CopilotOTelNormalizer.bodyLimit else { throw TelemetryError.capacity }
            let expected = boundary.upperBound + length
            guard data.count <= expected else { throw TelemetryError.invalid }
            guard data.count == expected else { return nil }
            body = data.subdata(in: boundary.upperBound..<expected)
        }
        let signal = try directEndpoint ? envelopeSignal(body) : String(path[4])
        return Self(source: source, signal: signal, body: body)
    }

    private static func chunkedBody(_ data: Data, start: Int) throws -> Data? {
        let crlf = Data([13, 10])
        var position = start
        var body = Data()
        var chunks = 0
        while true {
            guard let lineEnd = data.range(of: crlf, in: position..<data.endIndex) else {
                guard data.endIndex - position <= 16 else { throw TelemetryError.invalid }
                return nil
            }
            let line = data[position..<lineEnd.lowerBound]
            guard !line.contains(59) else { throw TelemetryError.unsupported }
            guard !line.isEmpty, line.count <= 16,
                  line.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let size = UInt64(String(decoding: line, as: UTF8.self), radix: 16) else {
                throw TelemetryError.invalid
            }
            position = lineEnd.upperBound
            if size == 0 {
                guard data.endIndex >= position + 2 else { return nil }
                guard data[position] == 13, data[position + 1] == 10 else { throw TelemetryError.unsupported }
                guard data.endIndex == position + 2 else { throw TelemetryError.invalid }
                guard !body.isEmpty else { throw TelemetryError.unsupported }
                return body
            }
            chunks += 1
            guard chunks <= 2048, size <= UInt64(CopilotOTelNormalizer.bodyLimit - body.count) else {
                throw TelemetryError.capacity
            }
            let end = position + Int(size)
            guard data.endIndex >= end + 2 else { return nil }
            guard data[end] == 13, data[end + 1] == 10 else { throw TelemetryError.invalid }
            body.append(data[position..<end])
            position = end + 2
        }
    }

    private static func envelopeSignal(_ body: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TelemetryError.unsupported
        }
        let signals = [("resourceSpans", "traces"), ("resourceMetrics", "metrics"), ("resourceLogs", "logs")]
            .filter { root[$0.0] != nil }
        guard signals.count == 1, let signal = signals.first,
              root[signal.0] is [[String: Any]] else { throw TelemetryError.unsupported }
        return signal.1
    }
}

public final class OTLPReceiver {
    public var onReady: ((TelemetryConfiguration) -> Void)?
    public var onBatch: ((UsageSource, TelemetryBatch, @escaping (Bool) -> Void) -> Void)?
    public var onFailure: ((TelemetryError) -> Void)?
    private let queue = DispatchQueue(label: "io.github.rottathiago.tokenotch.otel", qos: .utility)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var epoch = UUID()

    public init() {}

    public func start(_ configuration: TelemetryConfiguration) throws {
        try configuration.validate()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                     port: configuration.port == 0 ? .any : NWEndpoint.Port(rawValue: configuration.port)!)
        let server = try NWListener(using: parameters)
        queue.async { [self, server] in
            self.stopOnQueue()
            self.listener = server
            let epoch = self.epoch
            server.stateUpdateHandler = { [weak self, weak server] state in
                guard let self, let server, self.epoch == epoch else { return }
                switch state {
                case .ready:
                    guard let port = server.port else { self.onFailure?(.unavailable); return }
                    var ready = configuration
                    ready.port = port.rawValue
                    self.onReady?(ready)
                case .failed:
                    self.onFailure?(.unavailable)
                    self.stopOnQueue()
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                guard let self, self.epoch == epoch else { connection.cancel(); return }
                guard self.connections.count < 8 else {
                    self.onFailure?(.capacity)
                    connection.cancel()
                    return
                }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.connections[id] != nil else { return }
                    self.onFailure?(.capacity)
                    self.finish(id)
                }
                self.read(id, configuration: configuration, accumulated: Data())
            }
            server.start(queue: self.queue)
        }
    }

    public func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        epoch = UUID()
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }

    private func read(_ id: UUID, configuration: TelemetryConfiguration, accumulated: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, ended, error in
            guard let self, self.connections[id] != nil else { return }
            var data = accumulated
            if let bytes { data.append(bytes) }
            do {
                if let request = try OTLPRequest.parse(data, configuration: configuration) {
                    if request.signal != "traces" {
                        self.respond(id, code: 200, body: "{}")
                        return
                    }
                    let batch = try CopilotOTelNormalizer.decode(request.body, source: request.source)
                    guard let receive = self.onBatch else { throw TelemetryError.unavailable }
                    receive(request.source, batch) { [weak self] accepted in
                        guard let self else { return }
                        self.queue.async {
                            if !accepted { self.respond(id, code: 503, body: "{}"); return }
                            let body = batch.rejected == 0 ? "{}" :
                                "{\"partialSuccess\":{\"rejectedSpans\":\"\(batch.rejected)\",\"errorMessage\":\"Unsupported usage observations\"}}"
                            self.respond(id, code: 200, body: body)
                        }
                    }
                } else if ended || error != nil {
                    throw TelemetryError.invalid
                } else {
                    self.read(id, configuration: configuration, accumulated: data)
                }
            } catch {
                let failure = (error as? TelemetryError) ?? .invalid
                self.onFailure?(failure)
                self.respond(id, code: failure == .unauthorized ? 401 : (failure == .capacity ? 413 : 400), body: "{}")
            }
        }
    }

    private func respond(_ id: UUID, code: Int, body: String) {
        guard let connection = connections[id] else { return }
        let data = Data("HTTP/1.1 \(code) Result\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
    }

    private func finish(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}
