import Foundation
import TokenotchCore
import XCTest

final class CopilotUsageTests: XCTestCase {
    func testQuotaKeepsFractionalRequestsSeparateFromTokens() throws {
        let identity = Data(#"{"isAuthenticated":true,"login":"fixture","host":"https://github.com"}"#.utf8)
        let quota = Data(#"{"quotaSnapshots":{"premium_interactions":{"isUnlimitedEntitlement":false,"entitlementRequests":300,"usedRequests":58.5,"remainingPercentage":80.5}}}"#.utf8)
        let snapshot = try CopilotAccountSnapshot.parse(identity: identity, quota: quota, version: "fixture")
        XCTAssertEqual(snapshot.quotas.first?.usedRequests, Decimal(string: "58.5"))
        XCTAssertEqual(snapshot.quotas.first?.title, "Premium requests")
        XCTAssertNil(snapshot.quotas.first?.resetDate)
    }

    func testTokensAreDeduplicatedAndDoNotChangeSessionActivity() throws {
        let now = Date()
        let input = try JSONSerialization.data(withJSONObject: [
            "sessionId": "fixture", "eventId": "call", "timestamp": now.timeIntervalSince1970 * 1000,
            "usageContract": 1, "inputTokens": 200, "outputTokens": 30, "cacheReadTokens": 150, "prompt": "must not survive"
        ])
        let event = try HookNormalizer.normalize(input, source: .cli, hook: "usage", now: now)
        var ledger = TokenLedger()
        try ledger.observe(event, now: now)
        try ledger.observe(event, now: now)
        XCTAssertEqual(ledger.totals?.input, 50)
        XCTAssertEqual(ledger.totals?.output, 30)
        XCTAssertEqual(ledger.totals?.cacheInput, 150)
        XCTAssertEqual(ledger.totals?.total, 230)
        XCTAssertEqual(ledger.totals?.calls, 1)
        var activity = ActivityState()
        XCTAssertThrowsError(try activity.accept(event, now: now))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("must not survive"))
        ledger.expire(now: now.addingTimeInterval(86_401))
        XCTAssertNil(ledger.totals)
    }

    func testRPCFramesHandleSplitAndMultipleResponsesAndRejectOversize() throws {
        let first = try RPCFrames.encode(id: 1, method: "status.get")
        let second = try RPCFrames.encode(id: 2, method: "auth.getStatus")
        var decoder = RPCFrames()
        XCTAssertTrue(try decoder.append(first.prefix(8)).isEmpty)
        XCTAssertEqual(try decoder.append(first.dropFirst(8) + second).count, 2)
        XCTAssertThrowsError(try decoder.append(Data("Content-Length: 99999999\r\n\r\n".utf8)))
    }

    func testUnknownOrMismatchedQuotaIsNotShownAsZero() {
        let identity = Data(#"{"isAuthenticated":true,"login":"fixture"}"#.utf8)
        XCTAssertThrowsError(try CopilotAccountSnapshot.parse(identity: identity, quota: Data("{}".utf8), version: "fixture"))
        let bad = Data(#"{"quotaSnapshots":{"chat":{"isUnlimitedEntitlement":false,"entitlementRequests":-1,"usedRequests":0,"remainingPercentage":0}}}"#.utf8)
        XCTAssertThrowsError(try CopilotAccountSnapshot.parse(identity: identity, quota: bad, version: "fixture"))
    }
}
