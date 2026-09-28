import Foundation
import SQLite3
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum TelemetryImportChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_002)
    private static let trace = "11111111111111111111111111111111"
    private static let call = "2222222222222222"
    private static let parent = "3333333333333333"
    private static let sensitive = "private-prompt-credential-path-never-retain"

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try check("JSON contracts") { try jsonChecks(root) }
        try check("Bounds and files") { try boundsAndFiles(root) }
        try check("SQLite schema") { try sqliteChecks(root) }
        try check("SQLite WAL") { try walChecks(root) }
    }

    private static func check(_ name: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { throw Failure(description: "\(name): \(error)") }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    private static func rejects(_ expected: TelemetryError, _ body: () throws -> Void) throws {
        do {
            try body()
            throw Failure(description: "Expected telemetry error: \(expected)")
        } catch let error as TelemetryError {
            try require(error == expected, "Wrong telemetry error: \(error), expected \(expected)")
            try require(!error.localizedDescription.contains(sensitive), "Error retained raw input")
        }
    }

    private static func attributes(read: Any? = 20, write: Any? = 10) -> [String: Any] {
        var result: [String: Any] = [
            "gen_ai.operation.name": "chat", "gen_ai.provider.name": "github",
            "gen_ai.request.model": "test-model", "gen_ai.conversation.id": sensitive,
            "gen_ai.usage.input_tokens": 100, "gen_ai.usage.output_tokens": 7,
            "copilot_chat.time_to_first_token": 12.5, "gen_ai.input.messages": sensitive
        ]
        result["gen_ai.usage.cache_read.input_tokens"] = read
        result["gen_ai.usage.cache_creation.input_tokens"] = write
        return result
    }

    private static func wire(_ values: [String: Any]) -> [[String: Any]] {
        values.keys.sorted().map { key in
            let value = values[key]!
            let type = key.hasPrefix("gen_ai.usage.") ? "intValue" :
                (value is String ? "stringValue" : (key == "copilot_chat.time_to_first_token" ? "doubleValue" : "intValue"))
            return ["key": key, "value": [type: value]]
        }
    }

    private static func span(_ id: String = call, operation: String = "chat",
                             values: [String: Any]? = nil) -> [String: Any] {
        var attrs = values ?? attributes()
        attrs["gen_ai.operation.name"] = operation
        return [
            "traceId": trace, "spanId": id, "parentSpanId": parent, "name": sensitive,
            "startTimeUnixNano": "1700000000000000000", "endTimeUnixNano": "1700000001000000000",
            "attributes": wire(attrs), "events": [["name": sensitive]]
        ]
    }

    private static func resource(_ source: UsageSource) -> [String: Any] {
        source == .vscodeLocal ? ["service.name": "copilot-chat"] :
            ["service.name": "github-copilot", "service.namespace": "vscode.agent-host"]
    }

    private static func envelope(_ spans: [[String: Any]], source: UsageSource = .vscodeLocal) -> [String: Any] {
        ["resourceSpans": [[
            "resource": ["attributes": wire(resource(source))],
            "scopeSpans": [["spans": spans]]
        ]]]
    }

    private static func write(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private static func preview(_ url: URL, source: UsageSource = .vscodeLocal) throws -> TelemetryImportPreview {
        try TelemetryImport.preview(url, source: source, now: now)
    }

    private static func jsonChecks(_ root: URL) throws {
        let file = root.appendingPathComponent("not-a-schema-by-name.bin")
        let child = span()
        var parentValues = attributes()
        parentValues["gen_ai.usage.input_tokens"] = 999_999
        let aggregate = span(parent, operation: "invoke_agent", values: parentValues)
        try write(envelope([aggregate, child, child]), to: file)
        let imported = try preview(file)
        let live = try CopilotOTelNormalizer.decode(JSONSerialization.data(withJSONObject: envelope([aggregate, child])),
                                                   source: .vscodeLocal, now: now)
        try require(imported.events == live.events && imported.events.count == 1, "Live/import identity mismatch")
        try require(imported.totalTokens == 107 && imported.filtered == 2 && imported.rejected == 0,
                    "Parent or repeated call double-counted")
        try require(imported.fileCount == 1 && imported.callCount == 1 && imported.unlinked == 0 &&
                    imported.dateRange?.lowerBound == live.events[0].timestamp, "Preview metadata")
        try require(imported.events[0].tokens?.input == 70, "Cache buckets overlap")
        let saved = String(decoding: try JSONEncoder().encode(imported.events), as: UTF8.self)
        try require(!saved.contains(sensitive) && !saved.contains(file.path), "Normalized output retained raw text")
        try TelemetryImport.validateUnchanged(imported)
        try rejects(.unsupported) { _ = try preview(file, source: .cli) }
        try rejects(.unsupported) { _ = try preview(file, source: .vscodeCopilot) }

        for (read, writeValue) in [(nil, nil), (0, nil), (nil, 0), (0, 0)] as [(Int?, Int?)] {
            try write(envelope([span(values: attributes(read: read, write: writeValue))]), to: file)
            let tokens = try preview(file).events.first?.tokens
            try require(tokens?.input == 100 && tokens?.cacheInputReported == (read != nil) &&
                        tokens?.cacheWriteReported == (writeValue != nil), "Optional zero presence lost")
        }
        for invalid in [true, -1, 1.5, 1_000_000_001, NSNull()] as [Any] {
            try write(envelope([span(values: attributes(read: invalid))]), to: file)
            let result = try preview(file)
            try require(result.events.isEmpty && result.rejected == 1, "Invalid integer accepted")
        }
        var unlinked = attributes(read: "20", write: "10")
        unlinked.removeValue(forKey: "gen_ai.conversation.id")
        try write(envelope([span(values: unlinked)]), to: file)
        let unlinkedResult = try preview(file)
        try require(unlinkedResult.unlinked == 1 && unlinkedResult.totalTokens == 107, "Unlinked/string integers")
        var missingInput = attributes()
        missingInput.removeValue(forKey: "gen_ai.usage.input_tokens")
        try write(envelope([span(values: missingInput)]), to: file)
        let missingResult = try preview(file)
        try require(missingResult.callCount == 0 && missingResult.rejected == 1, "Absent input invented")

        let node: [String: Any] = [
            "_spanContext": ["traceId": trace, "spanId": call], "name": sensitive, "status": ["code": 1],
            "startTime": [1_700_000_000, 0], "endTime": [1_700_000_001, 0],
            "attributes": attributes(), "events": [], "resource": [
                "_rawAttributes": [["service.name", "copilot-chat"]],
                "_asyncAttributesPending": false
            ]
        ]
        try write(node, to: file)
        try require(try preview(file).events == live.events, "SDK 2.x JSONL identity mismatch")
        var maximumLine = node
        maximumLine["ignored"] = ""
        let baseSize = try JSONSerialization.data(withJSONObject: maximumLine, options: [.sortedKeys]).count
        maximumLine["ignored"] = String(repeating: "x", count: TelemetryImport.recordLimit - baseSize)
        try write(maximumLine, to: file)
        try require(try Data(contentsOf: file).count == TelemetryImport.recordLimit &&
                    preview(file).events == live.events, "Exact JSONL record limit rejected")
        var alternateNode = node
        alternateNode["spanContext"] = alternateNode.removeValue(forKey: "_spanContext")
        alternateNode["_resource"] = ["attributes": resource(.vscodeLocal)]
        alternateNode.removeValue(forKey: "resource")
        try write(alternateNode, to: file)
        try require(try preview(file).events == live.events, "Public ReadableSpan representation")

        let forwarded: [String: Any] = [
            "traceId": trace, "spanId": call, "parentSpanId": parent,
            "name": sensitive, "status": ["code": 1],
            "startTime": 1_700_000_000_000, "endTime": 1_700_000_001_000,
            "attributes": attributes().merging(resource(.vscodeCopilot)) { _, rhs in rhs }, "events": []
        ]
        try write(forwarded, to: file)
        let copilotLive = try CopilotOTelNormalizer.decode(
            JSONSerialization.data(withJSONObject: envelope([child], source: .vscodeCopilot)),
            source: .vscodeCopilot, now: now)
        try require(try preview(file, source: .vscodeCopilot).events == copilotLive.events &&
                    !copilotLive.events.isEmpty, "AgentHost JSONL/live identity mismatch")
        let line = try JSONSerialization.data(withJSONObject: forwarded)
        try (line + Data("\n".utf8) + line + Data("\n".utf8)).write(to: file)
        let repeats = try preview(file, source: .vscodeCopilot)
        try require(repeats.callCount == 1 && repeats.filtered == 1, "JSONL repeats counted")
        var terminal = forwarded
        terminal["attributes"] = attributes().merging(["service.name": "github-copilot"]) { _, rhs in rhs }
        try write(terminal, to: file)
        try rejects(.unsupported) { _ = try preview(file, source: .vscodeCopilot) }
        try write(["resourceSpans": [], "prompt": sensitive], to: file)
        try rejects(.unsupported) { _ = try preview(file) }
        for unknown: [String: Any] in [
            ["messages": [sensitive]], ["name": "logs", "body": sensitive],
            ["version": 999, "spans": [child]], ["schemaVersion": 1, "data": child]
        ] {
            try write(unknown, to: file)
            try rejects(.unsupported) { _ = try preview(file) }
        }
        try (line + Data("\n{\"unknown\":\"\(sensitive)\"}\n".utf8)).write(to: file)
        try rejects(.unsupported) { _ = try preview(file, source: .vscodeCopilot) }
    }

    private static func boundsAndFiles(_ root: URL) throws {
        let file = root.appendingPathComponent("bounded.json")
        try write(envelope(Array(repeating: span(), count: CopilotOTelNormalizer.spanLimit + 1)), to: file)
        let many = try preview(file)
        try require(many.callCount == 1 && many.filtered == CopilotOTelNormalizer.spanLimit, "Live batch limit leaked into import")

        let smallSpan: [String: Any] = ["attributes": wire(["gen_ai.operation.name": "execute_tool"])]
        try write(envelope(Array(repeating: smallSpan, count: TelemetryImport.spanLimit + 1)), to: file)
        try rejects(.capacity) { _ = try preview(file) }
        try write(envelope(Array(repeating: smallSpan, count: TelemetryImport.spanLimit)), to: file)
        let boundary = try preview(file)
        try require(boundary.filtered == TelemetryImport.spanLimit, "Exact span limit was truncated")

        var oversized = span()
        oversized["name"] = String(repeating: "x", count: TelemetryImport.recordLimit + 1)
        try write(envelope([oversized]), to: file)
        try rejects(.capacity) { _ = try preview(file) }
        try Data(repeating: 32, count: TelemetryImport.recordLimit + 1).write(to: file)
        try rejects(.capacity) { _ = try preview(file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(TelemetryImport.byteLimit + 1))
        try handle.close()
        try rejects(.capacity) { _ = try preview(file) }

        var maximum = try JSONSerialization.data(withJSONObject: envelope([span()]))
        maximum.append(Data(repeating: 32, count: TelemetryImport.byteLimit - maximum.count))
        try maximum.write(to: file)
        try require(try preview(file).callCount == 1, "Exact byte limit rejected")
        try write(envelope([span()]), to: file)
        let original = try preview(file)
        try write(envelope([span("4444444444444444")]), to: file)
        try rejects(.changed) { try TelemetryImport.validateUnchanged(original) }
        let replacement = try preview(file)
        let sameData = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try sameData.write(to: file)
        try rejects(.changed) { try TelemetryImport.validateUnchanged(replacement) }
        let symlink = root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        try rejects(.unsupported) { _ = try preview(symlink) }
        try rejects(.unsupported) { _ = try preview(root) }
        try rejects(.unsupported) { _ = try preview(URL(string: "https://example.invalid/\(sensitive)")!) }
        try rejects(.unsupported) { _ = try preview(root.appendingPathComponent(".copilot/session-state/x.jsonl")) }
        try Data("{\"secret\":\"\(sensitive)\"".utf8).write(to: file)
        try rejects(.invalid) { _ = try preview(file) }
    }

    private static let schema = """
        CREATE TABLE schema_version(version INTEGER PRIMARY KEY);
        INSERT INTO schema_version VALUES(1);
        CREATE TABLE spans(
          span_id TEXT PRIMARY KEY,trace_id TEXT NOT NULL,parent_span_id TEXT,name TEXT NOT NULL,
          start_time_ms INTEGER NOT NULL,end_time_ms INTEGER NOT NULL,status_code INTEGER NOT NULL DEFAULT 0,
          status_message TEXT,operation_name TEXT,provider_name TEXT,agent_name TEXT,conversation_id TEXT,
          request_model TEXT,response_model TEXT,input_tokens INTEGER,output_tokens INTEGER,cached_tokens INTEGER,
          reasoning_tokens INTEGER,tool_name TEXT,tool_call_id TEXT,tool_type TEXT,chat_session_id TEXT,turn_index INTEGER,ttft_ms REAL);
        CREATE TABLE span_attributes(span_id TEXT NOT NULL,key TEXT NOT NULL,value TEXT,PRIMARY KEY(span_id,key));
        CREATE TABLE span_events(id INTEGER PRIMARY KEY AUTOINCREMENT,span_id TEXT NOT NULL,name TEXT NOT NULL,
          timestamp_ms INTEGER NOT NULL,attributes TEXT);
        CREATE VIEW sessions AS SELECT load_extension('never-load') AS forbidden;
        """

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(description: "Synthetic SQLite fixture failed") }
    }

    private static func database(_ file: URL, wal: Bool = false) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_open(file.path, &result) == SQLITE_OK, let db = result else {
            if let result { sqlite3_close(result) }
            throw Failure(description: "Fixture open failed")
        }
        do {
            if wal { try exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;") }
            try exec(db, schema)
            return db
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    private static func insert(_ db: OpaquePointer, id: String = call, operation: String = "chat",
                               cached: String = "20", input: String = "100", resources: Bool = true,
                               source: UsageSource = .vscodeLocal) throws {
        try exec(db, """
            INSERT INTO spans(span_id,trace_id,parent_span_id,name,start_time_ms,end_time_ms,operation_name,
              provider_name,conversation_id,request_model,input_tokens,output_tokens,cached_tokens,ttft_ms)
            VALUES('\(id)','\(trace)','\(parent)','\(sensitive)',1700000000000,1700000001000,'\(operation)',
              'github','\(sensitive)','test-model',\(input),7,\(cached),12.5);
            INSERT INTO span_attributes VALUES('\(id)','gen_ai.usage.cache_creation.input_tokens','10');
            INSERT INTO span_attributes VALUES('\(id)','gen_ai.input.messages','\(sensitive)');
            INSERT INTO span_events(span_id,name,timestamp_ms,attributes) VALUES('\(id)','\(sensitive)',1700000000000,'\(sensitive)');
            """)
        if resources {
            for (key, value) in resource(source) {
                try exec(db, "INSERT INTO span_attributes VALUES('\(id)','\(key)','\(value)');")
            }
        }
    }

    private static func sqliteChecks(_ root: URL) throws {
        let file = root.appendingPathComponent("schema-one.anything")
        let db = try database(file)
        defer { sqlite3_close(db) }
        try insert(db)
        try insert(db, id: parent, operation: "invoke_agent", input: "999999")
        let original = try Data(contentsOf: file)
        let result = try preview(file)
        let live = try CopilotOTelNormalizer.decode(JSONSerialization.data(withJSONObject: envelope([span()])),
                                                   source: .vscodeLocal, now: now)
        try require(result.events == live.events && result.filtered == 1, "SQLite accounting/identity mismatch")
        try require(try Data(contentsOf: file) == original, "SQLite modified selected file")
        try TelemetryImport.validateUnchanged(result)
        try exec(db, "BEGIN;")
        for index in 1...256 {
            try insert(db, id: String(format: "%016x", index), operation: "execute_tool")
        }
        try exec(db, "COMMIT;")
        try require(try preview(file).filtered == 257, "Interior B-tree traversal lost records")
        try exec(db, "UPDATE spans SET cached_tokens=NULL WHERE span_id='\(call)'; DELETE FROM span_attributes WHERE key='gen_ai.usage.cache_creation.input_tokens';")
        try rejects(.changed) { try TelemetryImport.validateUnchanged(result) }
        let optional = try preview(file).events.first?.tokens
        try require(optional?.cacheInputReported == false && optional?.cacheWriteReported == false && optional?.input == 100,
                    "SQLite NULL became a reported zero")
        try exec(db, "UPDATE spans SET cached_tokens=0 WHERE span_id='\(call)';")
        try require(try preview(file).events.first?.tokens?.cacheInputReported == true, "SQLite integer zero disappeared")
        try exec(db, "UPDATE spans SET input_tokens=1.5 WHERE span_id='\(call)';")
        try require(try preview(file).rejected == 1, "Fractional SQLite token count accepted")
        try exec(db, "UPDATE spans SET input_tokens=100,name=CAST(zeroblob(\(TelemetryImport.recordLimit + 1)) AS TEXT) WHERE span_id='\(call)';")
        try rejects(.capacity) { _ = try preview(file) }
        try exec(db, "UPDATE spans SET name='span'; UPDATE schema_version SET version=2;")
        try rejects(.unsupported) { _ = try preview(file) }
        try exec(db, "UPDATE schema_version SET version=1; DELETE FROM span_attributes WHERE key='service.name';")
        try rejects(.unsupported) { _ = try preview(file) }
        try exec(db, "ALTER TABLE spans RENAME TO real_spans; CREATE VIEW spans AS SELECT * FROM real_spans;")
        try rejects(.unsupported) { _ = try preview(file) }

        let unknown = root.appendingPathComponent("unknown.sqlite")
        var raw: OpaquePointer?
        guard sqlite3_open(unknown.path, &raw) == SQLITE_OK, let raw else { throw Failure(description: "Unknown fixture") }
        defer { sqlite3_close(raw) }
        try exec(raw, "CREATE TABLE private_chat(text TEXT);")
        try rejects(.unsupported) { _ = try preview(unknown) }
    }

    private static func walChecks(_ root: URL) throws {
        let file = root.appendingPathComponent("export.sqlite")
        let writer = root.appendingPathComponent("synthetic-writer.sqlite")
        let db = try database(writer, wal: true)
        defer { sqlite3_close(db) }
        try insert(db, source: .vscodeCopilot)
        try insert(db, id: parent, operation: "invoke_agent", source: .vscodeCopilot)
        let suffixes = ["", "-wal", "-shm"]
        for suffix in suffixes {
            try FileManager.default.copyItem(atPath: writer.path + suffix, toPath: file.path + suffix)
        }
        let before = try suffixes.map { try Data(contentsOf: URL(fileURLWithPath: file.path + $0)) }
        let result = try preview(file, source: .vscodeCopilot)
        try require(result.callCount == 1 && result.totalTokens == 107 && result.filtered == 1 &&
                    result.fileCount == 3, "WAL-only rows not imported")
        try TelemetryImport.validateUnchanged(result)
        let after = try suffixes.map { try Data(contentsOf: URL(fileURLWithPath: file.path + $0)) }
        try require(before == after, "Export trio changed during read")

        let wal = URL(fileURLWithPath: file.path + "-wal")
        let shm = URL(fileURLWithPath: file.path + "-shm")
        var damaged = before[1]
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: wal)
        try rejects(.changed) { try TelemetryImport.validateUnchanged(result) }
        try rejects(.changed) { _ = try preview(file, source: .vscodeCopilot) }
        try before[1].write(to: wal)
        var changedSHM = before[2]
        changedSHM[100] ^= 1
        try changedSHM.write(to: shm)
        try rejects(.changed) { try TelemetryImport.validateUnchanged(result) }
        try before[2].write(to: shm)
        try (before[1] + Data([0])).write(to: wal)
        try rejects(.changed) { _ = try preview(file, source: .vscodeCopilot) }
        try before[1].write(to: wal)
        try FileManager.default.removeItem(at: wal)
        try rejects(.unsupported) { _ = try preview(file, source: .vscodeCopilot) }
        try rejects(.changed) { try TelemetryImport.validateUnchanged(result) }
        try FileManager.default.removeItem(at: shm)
        try rejects(.unsupported) { _ = try preview(file, source: .vscodeCopilot) }
        try before[1].write(to: wal)
        try FileManager.default.createSymbolicLink(at: shm, withDestinationURL: writer)
        try rejects(.unsupported) { _ = try preview(file, source: .vscodeCopilot) }
    }
}

#if canImport(XCTest) && canImport(TokenotchCore)
import XCTest

final class TelemetryImportTests: XCTestCase {
    func testExportContracts() throws { try TelemetryImportChecks.run() }
}
#endif
