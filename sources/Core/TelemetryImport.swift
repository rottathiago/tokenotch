import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import SQLite3

/// A transient preview: neither the selected URL nor export bytes belong in history storage.
public struct TelemetryImportPreview: Identifiable, Sendable {
    public let id: UUID
    public let source: UsageSource
    public let events: [ActivityEvent]
    public let filtered: Int
    public let rejected: Int
    public let unlinked: Int
    public let fileCount: Int?
    public let sourceURL: URL
    public let fingerprint: String

    public var callCount: Int { events.count }
    public var totalTokens: Int64 {
        events.reduce(0) { total, event in
            guard let tokens = event.tokens else { return total }
            return total + tokens.input + tokens.output + tokens.cacheInput + tokens.cacheWrite
        }
    }
    public var dateRange: ClosedRange<Date>? {
        guard let first = events.map(\.timestamp).min(), let last = events.map(\.timestamp).max() else { return nil }
        return first...last
    }
}

/// Export contracts pinned to VS Code 1.138.0 (7debcd0e2acdea1c52de81bf9ee1620444407dda):
/// OTLP JSON, FileSpanExporter (OTel SDK 2.x), FileForwarder, and OTelSqliteStore schema 1.
/// Missing resource provenance is unsupported, including Local SQLite exports that omit resources.
/// WAL-mode exports require both companions and a stable, exact committed WAL/SHM boundary;
/// missing companions, recovery journals, and ambiguous WAL tails are never silently ignored.
public enum TelemetryImport {
    public static let byteLimit = 64 * 1_048_576
    public static let recordLimit = 4 * 1_048_576
    public static let spanLimit = 100_000
    public static let eventLimit = 100_000

    public static func preview(_ url: URL, source: UsageSource, now: Date = Date()) throws -> TelemetryImportPreview {
        do {
            try Task.checkCancellation()
            guard source != .cli else { throw TelemetryError.unsupported }
            let selected = try selectedURL(url)
            let before = try snapshot(selected)
            var collector = Collector(source: source, now: now)
            if before.isSQLite {
                try readSQLite(before, url: selected, collector: &collector)
            } else {
                try readJSON(before.files[0].data, collector: &collector)
            }
            guard collector.spans > 0 else { throw TelemetryError.unsupported }
            let after = try snapshot(selected)
            guard before.fingerprint == after.fingerprint else { throw TelemetryError.changed }
            return TelemetryImportPreview(id: UUID(), source: source, events: collector.events,
                filtered: collector.filtered, rejected: collector.rejected,
                unlinked: collector.events.filter { $0.metricSessionReported == false }.count,
                fileCount: before.files.count, sourceURL: selected, fingerprint: before.fingerprint)
        } catch is CancellationError {
            throw TelemetryError.cancelled
        } catch let error as TelemetryError {
            throw error
        } catch {
            // Never expose parser, filesystem, or SQLite messages containing export content or paths.
            throw TelemetryError.invalid
        }
    }

    public static func validateUnchanged(_ preview: TelemetryImportPreview) throws {
        do {
            try Task.checkCancellation()
            guard try snapshot(selectedURL(preview.sourceURL)).fingerprint == preview.fingerprint else {
                throw TelemetryError.changed
            }
        } catch is CancellationError {
            throw TelemetryError.cancelled
        } catch TelemetryError.capacity {
            throw TelemetryError.capacity
        } catch {
            throw TelemetryError.changed
        }
    }

    private static let resourceKeys: Set<String> = ["service.name", "service.namespace"]
    private static let integerKeys: Set<String> = [
        "gen_ai.usage.input_tokens", "gen_ai.usage.output_tokens",
        "gen_ai.usage.cache_read.input_tokens", "gen_ai.usage.cache_creation.input_tokens"
    ]
    private static let latencyKey = "copilot_chat.time_to_first_token"
    private static let attributeKeys: Set<String> = integerKeys.union([
        "gen_ai.operation.name", "gen_ai.provider.name", "gen_ai.agent.name",
        "gen_ai.conversation.id", "gen_ai.request.model", "gen_ai.response.model", latencyKey
    ])
    private static let sqliteMagic = Data("SQLite format 3\0".utf8)

    private struct Collector {
        let source: UsageSource
        let now: Date
        var spans = 0
        var filtered = 0
        var rejected = 0
        var events: [ActivityEvent] = []
        var calls: [String: ActivityEvent] = [:]

        mutating func accept(_ span: [String: Any], resource: [[String: Any]]) throws {
            try Task.checkCancellation()
            spans += 1
            guard spans <= spanLimit else { throw TelemetryError.capacity }
            let identity = try TelemetryImport.resourceIdentity(resource)
            guard (source == .vscodeLocal && identity.service == "copilot-chat") ||
                  (source == .vscodeCopilot && identity.service == "github-copilot" &&
                   identity.namespace == "vscode.agent-host") else { throw TelemetryError.unsupported }
            let envelope: [String: Any] = ["resourceSpans": [[
                "resource": ["attributes": resource],
                "scopeSpans": [["spans": [span]]]
            ]]]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            guard data.count <= CopilotOTelNormalizer.bodyLimit else { throw TelemetryError.capacity }
            let batch = try CopilotOTelNormalizer.decode(data, source: source, now: now, importing: true)
            filtered += batch.filtered
            rejected += batch.rejected
            for event in batch.events {
                guard let call = event.tokens?.callID else { throw TelemetryError.invalid }
                if let previous = calls[call] {
                    guard previous == event else { throw TelemetryError.invalid }
                    filtered += 1
                    continue
                }
                guard events.count < eventLimit else { throw TelemetryError.capacity }
                calls[call] = event
                events.append(event)
            }
        }
    }

    private static func selectedURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.path.utf8.contains(0) else { throw TelemetryError.unsupported }
        let requested = url.standardizedFileURL
        // Foundation canonicalizes /private/var back to /var, which SQLite NOFOLLOW rejects.
        // Resolve directory aliases with realpath, never the selected final component.
        guard let directory = realpath(requested.deletingLastPathComponent().path, nil) else {
            throw TelemetryError.unsupported
        }
        defer { free(directory) }
        let selected = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
            .appendingPathComponent(requested.lastPathComponent)
        let privateComponents: Set<String> = [".copilot", "chatstorage", "globalstorage", "workspacestorage"]
        guard !(requested.pathComponents + selected.pathComponents).contains(where: { privateComponents.contains($0.lowercased()) }),
              !["state.vscdb", "chatstorage.db", "chatstorage.sqlite"].contains(selected.lastPathComponent.lowercased())
        else { throw TelemetryError.unsupported }
        return selected
    }

    private struct FileImage {
        let suffix: String
        let data: Data
        let metadata: String
    }

    private struct Snapshot {
        let files: [FileImage]
        let isSQLite: Bool
        let fingerprint: String
        func data(_ suffix: String) -> Data? { files.first { $0.suffix == suffix }?.data }
    }

    private static func signature(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):" +
        "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):" +
        "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private static func metadata(_ path: String, optional: Bool = false) throws -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if optional && errno == ENOENT { return nil }
            throw TelemetryError.changed
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw TelemetryError.unsupported }
        return info
    }

    private static func readFile(_ path: String, suffix: String, budget: inout Int,
                                 optional: Bool = false) throws -> FileImage? {
        try Task.checkCancellation()
        guard let before = try metadata(path, optional: optional) else { return nil }
        guard before.st_size >= 0, before.st_size <= budget else { throw TelemetryError.capacity }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw TelemetryError.changed }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, signature(before) == signature(opened) else { throw TelemetryError.changed }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = read(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TelemetryError.changed }
                offset += count
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, signature(before) == signature(after),
              let current = try metadata(path), signature(before) == signature(current) else {
            throw TelemetryError.changed
        }
        budget -= data.count
        return FileImage(suffix: suffix, data: data, metadata: signature(before))
    }

    private static func snapshot(_ url: URL) throws -> Snapshot {
        var budget = byteLimit
        guard let main = try readFile(url.path, suffix: "", budget: &budget) else { throw TelemetryError.invalid }
        let sqlite = main.data.starts(with: sqliteMagic)
        var files = [main]
        if sqlite {
            // A rollback journal needs recovery; this reader never recovers a user's database.
            guard try metadata(url.path + "-journal", optional: true) == nil else { throw TelemetryError.unsupported }
            for suffix in ["-wal", "-shm"] {
                if let file = try readFile(url.path + suffix, suffix: suffix, budget: &budget, optional: true) {
                    files.append(file)
                }
            }
        }
        var hash = SHA256()
        for suffix in sqlite ? ["", "-wal", "-shm"] : [""] {
            try Task.checkCancellation()
            hash.update(data: Data(suffix.utf8))
            let current = try metadata(url.path + suffix, optional: suffix != "")
            if let file = files.first(where: { $0.suffix == suffix }) {
                guard let current, signature(current) == file.metadata else { throw TelemetryError.changed }
                hash.update(data: Data(file.metadata.utf8))
                hash.update(data: file.data)
            } else {
                guard current == nil else { throw TelemetryError.changed }
                hash.update(data: Data("absent".utf8))
            }
        }
        return Snapshot(files: files, isSQLite: sqlite,
                        fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func checkedRecord(_ record: [String: Any]) throws {
        guard try JSONSerialization.data(withJSONObject: record).count <= recordLimit else {
            throw TelemetryError.capacity
        }
    }

    private static func otlpAttributes(_ raw: Any?, keys: Set<String>) throws -> [[String: Any]] {
        guard let entries = raw as? [[String: Any]] else { throw TelemetryError.invalid }
        guard entries.count <= 512 else { throw TelemetryError.capacity }
        return try entries.filter {
            guard let key = $0["key"] as? String else { throw TelemetryError.invalid }
            return keys.contains(key)
        }
    }

    private static func resourceIdentity(_ entries: [[String: Any]]) throws -> (service: String?, namespace: String?) {
        var result: [String: String] = [:]
        for entry in entries {
            guard let key = entry["key"] as? String,
                  let value = entry["value"] as? [String: Any], value.count == 1,
                  let text = value["stringValue"] as? String, result[key] == nil else {
                throw TelemetryError.unsupported
            }
            result[key] = text
        }
        return (result["service.name"], result["service.namespace"])
    }

    private static func wireAttributes(_ values: [String: Any], keys: Set<String>) throws -> [[String: Any]] {
        guard values.count <= 512 else { throw TelemetryError.capacity }
        return try values.keys.sorted().filter { keys.contains($0) }.map { key in
            let value: [String: Any]
            if let text = values[key] as? String {
                value = ["stringValue": text]
            } else if let number = values[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                value = [key == latencyKey ? "doubleValue" : "intValue": number]
            } else {
                throw TelemetryError.invalid
            }
            return ["key": key, "value": value]
        }
    }

    private static func readJSON(_ data: Data, collector: inout Collector) throws {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["resourceSpans"] != nil {
            guard let resources = root["resourceSpans"] as? [[String: Any]] else { throw TelemetryError.unsupported }
            guard resources.count <= spanLimit else { throw TelemetryError.capacity }
            for resource in resources {
                try Task.checkCancellation()
                let attrs = try otlpAttributes((resource["resource"] as? [String: Any])?["attributes"], keys: resourceKeys)
                guard let scopes = resource["scopeSpans"] as? [[String: Any]] else { throw TelemetryError.invalid }
                guard scopes.count <= spanLimit else { throw TelemetryError.capacity }
                for scope in scopes {
                    guard let spans = scope["spans"] as? [[String: Any]] else { throw TelemetryError.invalid }
                    guard spans.count <= spanLimit - collector.spans else { throw TelemetryError.capacity }
                    for span in spans {
                        try Task.checkCancellation()
                        try checkedRecord(span)
                        var safe = span.filter { ["traceId", "spanId", "startTimeUnixNano", "endTimeUnixNano"].contains($0.key) }
                        safe["attributes"] = try otlpAttributes(span["attributes"], keys: attributeKeys)
                        try collector.accept(safe, resource: attrs)
                    }
                }
            }
            return
        }
        var start = data.startIndex
        while start < data.endIndex {
            try Task.checkCancellation()
            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
            guard end - start <= recordLimit else { throw TelemetryError.capacity }
            let line = data[start..<end]
            if !line.allSatisfy({ [9, 13, 32].contains($0) }) {
                guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw TelemetryError.unsupported
                }
                try readJSONLine(record, collector: &collector)
            }
            start = end == data.endIndex ? end : end + 1
        }
    }

    private static func readJSONLine(_ record: [String: Any], collector: inout Collector) throws {
        guard record["name"] is String, record["events"] is [Any],
              let status = record["status"] as? [String: Any], status["code"] is NSNumber,
              let attributes = record["attributes"] as? [String: Any] else { throw TelemetryError.unsupported }
        let resource: [[String: Any]]
        var span: [String: Any] = [:]
        if let context = (record["_spanContext"] ?? record["spanContext"]) as? [String: Any],
           let rawResource = (record["resource"] ?? record["_resource"]) as? [String: Any] {
            span["traceId"] = context["traceId"]
            span["spanId"] = context["spanId"]
            span["startTimeUnixNano"] = try hrtime(record["startTime"])
            span["endTimeUnixNano"] = try hrtime(record["endTime"])
            let values: [String: Any]
            if let direct = rawResource["attributes"] as? [String: Any] {
                values = direct
            } else if let pairs = rawResource["_rawAttributes"] as? [[Any]],
                      rawResource["_asyncAttributesPending"] as? Bool != true {
                guard pairs.count <= 512 else { throw TelemetryError.capacity }
                var raw: [String: Any] = [:]
                for pair in pairs {
                    guard pair.count == 2, let key = pair[0] as? String else { throw TelemetryError.unsupported }
                    // SDK 2.x ResourceImpl gives the first non-null value precedence.
                    if raw[key] == nil, !(pair[1] is NSNull) { raw[key] = pair[1] }
                }
                values = raw
            } else { throw TelemetryError.unsupported }
            resource = try wireAttributes(values, keys: resourceKeys)
        } else if record["traceId"] is String, record["spanId"] is String {
            span["traceId"] = record["traceId"]
            span["spanId"] = record["spanId"]
            span["startTimeUnixNano"] = try milliseconds(record["startTime"])
            span["endTimeUnixNano"] = try milliseconds(record["endTime"])
            resource = try wireAttributes(attributes, keys: resourceKeys)
        } else { throw TelemetryError.unsupported }
        span["attributes"] = try wireAttributes(attributes, keys: attributeKeys)
        try collector.accept(span, resource: resource)
    }

    private static func numeric(_ raw: Any?) throws -> Double {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw TelemetryError.invalid }
        return number.doubleValue
    }

    private static func milliseconds(_ raw: Any?) throws -> String {
        let value = try numeric(raw)
        guard value > 0, value < Double(UInt64.max) / 1_000_000 else { throw TelemetryError.invalid }
        return String(UInt64((value * 1_000_000).rounded(.down)))
    }

    private static func hrtime(_ raw: Any?) throws -> String {
        guard let values = raw as? [Any], values.count == 2 else { throw TelemetryError.unsupported }
        let seconds = try numeric(values[0]), nanos = try numeric(values[1])
        guard seconds >= 0, seconds <= Double(UInt64.max / 1_000_000_000 - 1),
              seconds.rounded() == seconds, (0..<1_000_000_000).contains(nanos), nanos.rounded() == nanos else {
            throw TelemetryError.invalid
        }
        return String(UInt64(seconds) * 1_000_000_000 + UInt64(nanos))
    }

    // SQLite files are never opened as writable. WAL is verified and replayed into a bounded
    // in-memory image, then deserialized read-only. SQLite never touches the user's WAL/SHM.
    private static func databaseImage(_ snapshot: Snapshot) throws -> Data {
        var image = snapshot.files[0].data
        guard image.count >= 100 else { throw TelemetryError.invalid }
        let encodedSize = Int(image[16]) << 8 | Int(image[17])
        let pageSize = encodedSize == 1 ? 65_536 : encodedSize
        guard (512...65_536).contains(pageSize), pageSize.nonzeroBitCount == 1,
              image.count % pageSize == 0, image[18] == image[19],
              [1, 2].contains(image[18]) else { throw TelemetryError.invalid }
        if image[18] == 2 {
            // A standalone WAL-mode file cannot prove that its required WAL was exported.
            guard let wal = snapshot.data("-wal"), let shm = snapshot.data("-shm") else {
                throw TelemetryError.unsupported
            }
            try replay(wal: wal, shm: shm, pageSize: pageSize, image: &image)
        } else {
            guard snapshot.data("-wal") == nil, snapshot.data("-shm") == nil else { throw TelemetryError.unsupported }
        }
        guard image.starts(with: sqliteMagic), Int(word(image, 28)) * pageSize == image.count else {
            throw TelemetryError.invalid
        }
        // sqlite3_deserialize does not support WAL-mode images. This changes only private RAM.
        image[18] = 1
        image[19] = 1
        return image
    }

    private static func word(_ data: Data, _ offset: Int, little: Bool = false) -> UInt32 {
        if little {
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
                UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func checksum(_ data: Data, range: Range<Int>, little: Bool,
                                 seed: (UInt32, UInt32) = (0, 0)) -> (UInt32, UInt32) {
        var (a, b) = seed
        for offset in stride(from: range.lowerBound, to: range.upperBound, by: 8) {
            a = a &+ word(data, offset, little: little) &+ b
            b = b &+ word(data, offset + 4, little: little) &+ a
        }
        return (a, b)
    }

    private static func replay(wal: Data, shm: Data, pageSize: Int, image: inout Data) throws {
        guard shm.count >= 32_768, shm.count % 32_768 == 0,
              shm[0..<48] == shm[48..<96], shm[12] == 1 else { throw TelemetryError.changed }
        let little = word(shm, 0, little: true) == 3_007_000
        guard word(shm, 0, little: little) == 3_007_000 else { throw TelemetryError.unsupported }
        let headerCheck = checksum(shm, range: 0..<40, little: little)
        guard headerCheck == (word(shm, 40, little: little), word(shm, 44, little: little)) else {
            throw TelemetryError.changed
        }
        let frames = Int(word(shm, 16, little: little))
        let shmPage = little ? Int(shm[14]) | Int(shm[15]) << 8 : Int(shm[14]) << 8 | Int(shm[15])
        guard shmPage == pageSize || (shmPage == 1 && pageSize == 65_536) else { throw TelemetryError.changed }
        guard word(shm, 96, little: little) <= frames,
              word(shm, 128, little: little) <= frames else { throw TelemetryError.changed }
        if wal.isEmpty {
            guard frames == 0 else { throw TelemetryError.changed }
            return
        }
        guard wal.count >= 32, [0x377f0682, 0x377f0683].contains(word(wal, 0)),
              word(wal, 4) == 3_007_000, Int(word(wal, 8)) == pageSize,
              wal[16..<24] == shm[32..<40],
              shm[13] == UInt8(word(wal, 0) & 1) else { throw TelemetryError.changed }
        let walLittle = word(wal, 0) == 0x377f0682
        var sum = checksum(wal, range: 0..<24, little: walLittle)
        guard sum == (word(wal, 24), word(wal, 28)),
              wal.count == 32 + frames * (pageSize + 24) else { throw TelemetryError.changed }
        let pages = Int(word(shm, 20, little: little))
        guard pages > 0 else { throw TelemetryError.changed }
        guard pages <= byteLimit / pageSize else { throw TelemetryError.capacity }
        let finalSize = pages * pageSize
        let originalSize = image.count
        if image.count < finalSize { image.append(Data(count: finalSize - image.count)) }
        var suppliedPages: Set<Int> = []
        for index in 0..<frames {
            try Task.checkCancellation()
            let offset = 32 + index * (pageSize + 24)
            let page = Int(word(wal, offset))
            guard page > 0, page <= byteLimit / pageSize else { throw TelemetryError.capacity }
            guard wal[(offset + 8)..<(offset + 16)] == wal[16..<24] else { throw TelemetryError.changed }
            sum = checksum(wal, range: offset..<(offset + 8), little: walLittle, seed: sum)
            sum = checksum(wal, range: (offset + 24)..<(offset + 24 + pageSize), little: walLittle, seed: sum)
            guard sum == (word(wal, offset + 16), word(wal, offset + 20)) else { throw TelemetryError.changed }
            if index == frames - 1 {
                guard Int(word(wal, offset + 4)) == pages,
                      sum == (word(shm, 24, little: little), word(shm, 28, little: little)) else {
                    throw TelemetryError.changed
                }
            }
            if page <= pages {
                image.replaceSubrange(((page - 1) * pageSize)..<(page * pageSize),
                                      with: wal[(offset + 24)..<(offset + 24 + pageSize)])
                suppliedPages.insert(page)
            }
        }
        // Ambiguous tails (uncommitted, torn, or old WAL-reset frames) are rejected above.
        if finalSize > originalSize {
            for page in (originalSize / pageSize + 1)...pages {
                guard suppliedPages.contains(page) else { throw TelemetryError.changed }
            }
        }
        if image.count > finalSize { image.removeSubrange(finalSize..<image.count) }
    }

    private static let spanColumns: [(String, String)] = [
        ("operation_name", "gen_ai.operation.name"), ("provider_name", "gen_ai.provider.name"),
        ("agent_name", "gen_ai.agent.name"), ("conversation_id", "gen_ai.conversation.id"),
        ("request_model", "gen_ai.request.model"), ("response_model", "gen_ai.response.model"),
        ("input_tokens", "gen_ai.usage.input_tokens"), ("output_tokens", "gen_ai.usage.output_tokens"),
        ("cached_tokens", "gen_ai.usage.cache_read.input_tokens"), ("ttft_ms", latencyKey)
    ]

    private static func readSQLite(_ snapshot: Snapshot, url: URL, collector: inout Collector) throws {
        let image = try databaseImage(snapshot)
        guard let buffer = sqlite3_malloc64(UInt64(image.count))?.assumingMemoryBound(to: UInt8.self) else {
            throw TelemetryError.capacity
        }
        defer { sqlite3_free(buffer) }
        image.copyBytes(to: buffer, count: image.count)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components?.url?.absoluteString else { throw TelemetryError.unsupported }
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(uri, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw TelemetryError.invalid
        }
        defer { sqlite3_close(db) }
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(recordLimit))
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 16_384)
        sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 128)
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        try rows(db, "PRAGMA trusted_schema=OFF") { _ in }
        let deserializeStatus = sqlite3_deserialize(db, "main", buffer, Int64(image.count), Int64(image.count),
                                                   UInt32(SQLITE_DESERIALIZE_READONLY))
        guard deserializeStatus == SQLITE_OK else {
            throw TelemetryError.invalid
        }
        // Install after deserialize's internal ATTACH, before examining any untrusted schema.
        // Extension loading stays disabled; SQL functions, attachments, and writes are denied.
        guard sqlite3_set_authorizer(db, { _, action, _, _, _, _ in
            switch action {
            case SQLITE_READ, SQLITE_SELECT, SQLITE_PRAGMA: return SQLITE_OK
            default: return SQLITE_DENY
            }
        }, nil) == SQLITE_OK else { throw TelemetryError.unsupported }
        try rows(db, "PRAGMA query_only=ON") { _ in }
        try rows(db, "PRAGMA temp_store=MEMORY") { _ in }
        try verifySchema(db, image: image)

        let attrKeys = attributeKeys.union(resourceKeys).sorted()
        let attrSQL = "SELECT key,value FROM span_attributes WHERE span_id=? AND key IN (" +
            attrKeys.map { "'\($0)'" }.joined(separator: ",") + ")"
        let attrs = try statement(db, attrSQL)
        defer { sqlite3_finalize(attrs) }
        let columns = ["span_id", "trace_id", "start_time_ms", "end_time_ms"] + spanColumns.map(\.0)
        try rows(db, "SELECT \(columns.joined(separator: ",")) FROM spans") { row in
            try Task.checkCancellation()
            guard collector.spans < spanLimit else { throw TelemetryError.capacity }
            guard let id = try text(row, 0), let trace = try text(row, 1) else { throw TelemetryError.invalid }
            let start = try sqlValue(row, 2), end = try sqlValue(row, 3)
            var values: [String: Any] = [:]
            for (index, column) in spanColumns.enumerated() {
                values[column.1] = try sqlValue(row, Int32(index + 4))
            }
            sqlite3_reset(attrs)
            sqlite3_clear_bindings(attrs)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(attrs, 1, id, -1, transient) == SQLITE_OK else { throw TelemetryError.invalid }
            var bytes = 0
            var count = 0
            while try step(attrs) {
                try Task.checkCancellation()
                count += 1
                guard count <= attrKeys.count else { throw TelemetryError.invalid }
                guard let key = try text(attrs, 0), let value = try text(attrs, 1) else { throw TelemetryError.invalid }
                bytes += key.utf8.count + value.utf8.count
                guard bytes <= recordLimit else { throw TelemetryError.capacity }
                // The pinned stores use String(value) for scalars, JSON.stringify only for arrays.
                if let old = values[key] {
                    let equivalent: Bool
                    if integerKeys.contains(key) || key == latencyKey {
                        equivalent = Double(value).map { ($0.isFinite && (old as? NSNumber)?.doubleValue == $0) } ?? false
                    } else { equivalent = old as? String == value }
                    guard equivalent else { throw TelemetryError.invalid }
                } else if integerKeys.contains(key) {
                    guard !value.isEmpty, value.count <= 10, value.allSatisfy(\.isNumber),
                          let number = Int64(value) else { throw TelemetryError.invalid }
                    values[key] = NSNumber(value: number)
                } else if key == latencyKey {
                    guard let number = Double(value), number.isFinite else { throw TelemetryError.invalid }
                    values[key] = number
                } else { values[key] = value }
            }
            let span: [String: Any] = [
                "spanId": id, "traceId": trace,
                "startTimeUnixNano": try milliseconds(start), "endTimeUnixNano": try milliseconds(end),
                "attributes": try wireAttributes(values, keys: attributeKeys)
            ]
            try checkedRecord(span)
            try collector.accept(span, resource: wireAttributes(values, keys: resourceKeys))
        }
    }

    private static func statement(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &result, nil)
        guard code == SQLITE_OK, let result else {
            if let result { sqlite3_finalize(result) }
            try sqlError(code)
            throw TelemetryError.invalid
        }
        return result
    }

    private static func sqlError(_ code: Int32) throws {
        try Task.checkCancellation()
        if code == SQLITE_TOOBIG || code == SQLITE_NOMEM || code == SQLITE_FULL { throw TelemetryError.capacity }
        throw TelemetryError.invalid
    }

    private static func step(_ stmt: OpaquePointer) throws -> Bool {
        let code = sqlite3_step(stmt)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        try sqlError(code)
        return false
    }

    private static func rows(_ db: OpaquePointer, _ sql: String, body: (OpaquePointer) throws -> Void) throws {
        let stmt = try statement(db, sql)
        defer { sqlite3_finalize(stmt) }
        while try step(stmt) {
            try Task.checkCancellation()
            try body(stmt)
        }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) throws -> String? {
        if sqlite3_column_type(stmt, column) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(stmt, column) == SQLITE_TEXT else { throw TelemetryError.invalid }
        let size = Int(sqlite3_column_bytes(stmt, column))
        guard size <= recordLimit else { throw TelemetryError.capacity }
        guard let pointer = sqlite3_column_text(stmt, column),
              let text = String(bytes: UnsafeBufferPointer(start: pointer, count: size), encoding: .utf8),
              !text.utf8.contains(0) else { throw TelemetryError.invalid }
        return text
    }

    private static func sqlValue(_ stmt: OpaquePointer, _ column: Int32) throws -> Any? {
        switch sqlite3_column_type(stmt, column) {
        case SQLITE_NULL: return nil
        case SQLITE_TEXT: return try text(stmt, column)
        case SQLITE_INTEGER: return NSNumber(value: sqlite3_column_int64(stmt, column))
        case SQLITE_FLOAT: return NSNumber(value: sqlite3_column_double(stmt, column))
        default: throw TelemetryError.invalid
        }
    }

    private static func verifySchema(_ db: OpaquePointer, image: Data) throws {
        let tables: [(String, String, [String])] = [
            ("schema_version", "version:INTEGER", ["version"]),
            ("spans", """
                span_id:TEXT trace_id:TEXT parent_span_id:TEXT name:TEXT start_time_ms:INTEGER end_time_ms:INTEGER \
                status_code:INTEGER status_message:TEXT operation_name:TEXT provider_name:TEXT agent_name:TEXT \
                conversation_id:TEXT request_model:TEXT response_model:TEXT input_tokens:INTEGER output_tokens:INTEGER \
                cached_tokens:INTEGER reasoning_tokens:INTEGER tool_name:TEXT tool_call_id:TEXT tool_type:TEXT \
                chat_session_id:TEXT turn_index:INTEGER ttft_ms:REAL
                """, ["span_id"]),
            ("span_attributes", "span_id:TEXT key:TEXT value:TEXT", ["span_id", "key"]),
            ("span_events", "id:INTEGER span_id:TEXT name:TEXT timestamp_ms:INTEGER attributes:TEXT", ["id"])
        ]
        for (table, columns, primaryKeys) in tables {
            let expected = Set(columns.split(separator: " ").map(String.init))
            var foundTable = false
            // table_list can resolve unrelated views. Inspect only these named real tables.
            try rows(db, "SELECT type,sql,rootpage FROM sqlite_schema WHERE name='\(table)'") { row in
                guard try text(row, 0) == "table", let definition = try text(row, 1),
                      definition.uppercased().hasPrefix("CREATE TABLE "), !foundTable else {
                    throw TelemetryError.unsupported
                }
                foundTable = true
                if table == "spans" || table == "span_attributes" {
                    guard sqlite3_column_type(row, 2) == SQLITE_INTEGER else { throw TelemetryError.unsupported }
                    try checkRecordSizes(image, root: Int(sqlite3_column_int64(row, 2)))
                }
            }
            guard foundTable else { throw TelemetryError.unsupported }
            var found: Set<String> = []
            try rows(db, "PRAGMA table_info('\(table)')") { row in
                guard let name = try text(row, 1), let type = try text(row, 2) else { throw TelemetryError.unsupported }
                found.insert(name + ":" + type.uppercased())
                let primary = primaryKeys.firstIndex(of: name).map { $0 + 1 } ?? 0
                guard sqlite3_column_int(row, 5) == primary else { throw TelemetryError.unsupported }
            }
            guard found == expected else { throw TelemetryError.unsupported }
            var allColumns = 0
            try rows(db, "PRAGMA table_xinfo('\(table)')") { row in
                allColumns += 1
                guard sqlite3_column_int(row, 6) == 0 else { throw TelemetryError.unsupported }
            }
            guard allColumns == expected.count else { throw TelemetryError.unsupported }
        }
        var versions = 0
        try rows(db, "SELECT version FROM schema_version") { row in
            versions += 1
            guard versions == 1, sqlite3_column_type(row, 0) == SQLITE_INTEGER,
                  sqlite3_column_int64(row, 0) == 1 else { throw TelemetryError.unsupported }
        }
        guard versions == 1 else { throw TelemetryError.unsupported }
    }

    /// SQLITE_LIMIT_LENGTH does not bound unselected columns. Inspect only table B-tree
    /// payload lengths, not raw names/messages/attribute values, to enforce the record cap.
    private static func checkRecordSizes(_ image: Data, root: Int) throws {
        let encoded = Int(image[16]) << 8 | Int(image[17])
        let pageSize = encoded == 1 ? 65_536 : encoded
        let usable = pageSize - Int(image[20])
        var pending = [root]
        var visited: Set<Int> = []
        while let page = pending.popLast() {
            try Task.checkCancellation()
            guard page > 0, page <= image.count / pageSize, visited.insert(page).inserted else {
                throw TelemetryError.invalid
            }
            let base = (page - 1) * pageSize
            let header = base + (page == 1 ? 100 : 0)
            let end = base + usable
            guard header + 12 <= end else { throw TelemetryError.invalid }
            let leaf = image[header] == 13
            guard leaf || image[header] == 5 else { throw TelemetryError.unsupported }
            let count = Int(image[header + 3]) << 8 | Int(image[header + 4])
            let pointers = header + (leaf ? 8 : 12)
            guard pointers + count * 2 <= end else { throw TelemetryError.invalid }
            if !leaf { pending.append(Int(word(image, header + 8))) }
            for index in 0..<count {
                let pointer = pointers + index * 2
                let cell = base + (Int(image[pointer]) << 8 | Int(image[pointer + 1]))
                guard cell >= pointers + count * 2, cell < end else { throw TelemetryError.invalid }
                if leaf {
                    var length: UInt64 = 0
                    var complete = false
                    for byte in 0..<9 {
                        guard cell + byte < end else { throw TelemetryError.invalid }
                        let value = image[cell + byte]
                        if byte == 8 {
                            length = length << 8 | UInt64(value)
                            complete = true
                        } else {
                            length = length << 7 | UInt64(value & 127)
                            complete = value & 128 == 0
                        }
                        if complete { break }
                    }
                    guard complete else { throw TelemetryError.invalid }
                    guard length <= recordLimit else { throw TelemetryError.capacity }
                } else {
                    guard cell + 4 <= end else { throw TelemetryError.invalid }
                    pending.append(Int(word(image, cell)))
                }
            }
        }
    }
}
