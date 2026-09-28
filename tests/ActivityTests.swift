import Foundation
import TokenotchCore
import XCTest

final class ActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func payload(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testCLIStripsAllContentAndHashesSession() throws {
        let data = try payload(["sessionId": "/secret/account", "timestamp": now.timeIntervalSince1970 * 1000,
                                "cwd": "/secret/project", "prompt": "sensitive", "transcriptPath": "/secret/transcript"])
        let event = try HookNormalizer.normalize(data, source: .cli, hook: "userPromptSubmitted", now: now)
        XCTAssertEqual(event.kind, .working)
        XCTAssertEqual(event.session.count, 64)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("sensitive"))
        XCTAssertFalse(encoded.contains("cwd"))
    }

    func testVSCodeRequiresIdentityAndMatchingHook() throws {
        let object: [String: Any] = ["session_id": "opaque", "timestamp": ISO8601DateFormatter().string(from: now),
                                     "hook_event_name": "Stop", "stop_hook_active": false]
        let event = try HookNormalizer.normalize(payload(object), source: .vscode, hook: "Stop", now: now)
        XCTAssertEqual(event.kind, .stopped)
        XCTAssertThrowsError(try HookNormalizer.normalize(payload(object), source: .vscode, hook: "SessionStart", now: now))
        var missing = object
        missing.removeValue(forKey: "session_id")
        XCTAssertThrowsError(try HookNormalizer.normalize(payload(missing), source: .vscode, hook: "Stop", now: now))
    }

    func testErrorsAndSubagentsCannotInventTaskCompletion() throws {
        let object: [String: Any] = ["sessionId": "opaque", "timestamp": now.timeIntervalSince1970 * 1000]
        for hook in ["errorOccurred", "postToolUseFailure", "subagentStop", "PreToolUse"] {
            XCTAssertThrowsError(try HookNormalizer.normalize(payload(object), source: .cli, hook: hook, now: now))
        }
        var ended = object
        ended["reason"] = "error"
        XCTAssertEqual(try HookNormalizer.normalize(payload(ended), source: .cli, hook: "sessionEnd", now: now).kind, .failed)
        ended["reason"] = "abort"
        XCTAssertEqual(try HookNormalizer.normalize(payload(ended), source: .cli, hook: "sessionEnd", now: now).kind, .cancelled)
    }

    func testMalformedOversizedAndExpiredInputs() throws {
        XCTAssertThrowsError(try HookNormalizer.normalize(Data(repeating: 32, count: 65_537), source: .cli, hook: "sessionStart"))
        XCTAssertThrowsError(try HookNormalizer.normalize(Data("[]".utf8), source: .cli, hook: "sessionStart"))
        let object: [String: Any] = ["sessionId": "id", "timestamp": (now.timeIntervalSince1970 - 121) * 1000]
        XCTAssertThrowsError(try HookNormalizer.normalize(payload(object), source: .cli, hook: "sessionStart", now: now))
    }

    func testDuplicateOutOfOrderAndConcurrentSources() throws {
        var state = ActivityState()
        let key = ActivityEvent.digest("same")
        let event = ActivityEvent(source: .cli, session: key, kind: .working, timestamp: now)
        XCTAssertTrue(try state.accept(event, now: now))
        XCTAssertFalse(try state.accept(event, now: now))
        XCTAssertFalse(try state.accept(ActivityEvent(source: .cli, session: key, kind: .stopped,
                                                      timestamp: now.addingTimeInterval(-1)), now: now))
        XCTAssertTrue(try state.accept(ActivityEvent(source: .vscode, session: key, kind: .working, timestamp: now), now: now))
        XCTAssertEqual(state.sessions.count, 2)
        XCTAssertTrue(state.sessions.values.allSatisfy { $0.label(now: now.addingTimeInterval(301)) == "No recent activity updates" })
        state.remove(.cli)
        state.expire(now: now)
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.sessions.values.first?.source, .vscode)
    }

    func testLiveActivitySnapshots() throws { try ActivityChecks.run() }
}
