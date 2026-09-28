import Foundation
import TokenotchCore
import XCTest

final class BridgeTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-\(UUID().uuidString.prefix(8))")
        try PrivateFiles.directory(root)
        return root
    }
    func testOwnedInstallationCoexistsAndUninstallRefusesEditedFiles() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("copilot")
        let installer = HookInstallation(root: root, cliHome: home)
        let helper = root.appendingPathComponent("bundled-helper")
        try PrivateFiles.write(Data("fake helper".utf8), to: helper)
        try installer.install(.cli, bundledHelper: helper)
        let unrelated = home.appendingPathComponent("hooks/other.json")
        try Data("unrelated".utf8).write(to: unrelated)
        try installer.install(.cli, bundledHelper: helper)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
        try Data("edited".utf8).write(to: installer.hookURL(.cli))
        XCTAssertThrowsError(try installer.uninstall(.cli))
        XCTAssertEqual(try Data(contentsOf: installer.hookURL(.cli)), Data("edited".utf8))
        XCTAssertNil(try PrivateFiles.read(root.appendingPathComponent("cli.registration")))
    }
    func testSeparateConfigurationPreventsCrossClientDoubleRegistration() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstallation(root: root, cliHome: root.appendingPathComponent("copilot"))
        let helper = root.appendingPathComponent("helper with ' quote")
        let cli = String(decoding: try installer.configuration(.cli, helper: helper), as: UTF8.self)
        let vscode = String(decoding: try installer.configuration(.vscode, helper: helper), as: UTF8.self)
        XCTAssertTrue(cli.contains("\"exec\""))
        XCTAssertFalse(cli.contains("\"Stop\""))
        XCTAssertFalse(vscode.contains("\"agentStop\""))
        XCTAssertNotEqual(installer.hookURL(.cli).deletingLastPathComponent(), installer.hookURL(.vscode).deletingLastPathComponent())
    }
    func testBridgeDeliversSanitizedEventAndRejectsSecondListener() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = LocalBridge(root: root)
        let delivered = expectation(description: "delivered")
        delivered.expectedFulfillmentCount = 8
        let event = ActivityEvent(source: .cli, session: ActivityEvent.digest("opaque"), kind: .stopped, timestamp: Date())
        let usage = ActivityEvent(source: .cli, session: event.session, kind: .usage, timestamp: Date(),
                                 tokens: TokenUsage(callID: ActivityEvent.digest("call"), input: 10, output: 2,
                                                    model: "fixture-model"))
        let context = ActivityEvent(source: .cli, session: event.session, kind: .context, timestamp: Date(),
                                   context: ContextUsage(currentTokens: 80, tokenLimit: 100))
        let active = ActivityEvent(source: .cli, session: event.session, kind: .active, timestamp: Date())
        let idle = ActivityEvent(source: .cli, session: event.session, kind: .idle, timestamp: Date())
        let attention = [EventKind.inputRequested, .approvalRequested, .unrecoverableError].map {
            ActivityEvent(source: .cli, session: event.session, kind: $0, timestamp: Date())
        }
        bridge.onEvent = { value in
            XCTAssertTrue(([event, usage, context, active, idle] + attention).contains(value))
            delivered.fulfill()
        }
        try PrivateFiles.write(Data("registration".utf8), to: root.appendingPathComponent("cli.registration"))
        try bridge.start()
        defer { bridge.stop() }
        XCTAssertThrowsError(try LocalBridge(root: root).start())
        try LocalBridge.send(event, root: root)
        try LocalBridge.send(usage, root: root)
        try LocalBridge.send(context, root: root)
        try LocalBridge.send(active, root: root)
        try LocalBridge.send(idle, root: root)
        for report in attention { try LocalBridge.send(report, root: root) }
        wait(for: [delivered], timeout: 2)
    }
    func testSymlinksAndUnregisteredSendAreRejected() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other")
        try PrivateFiles.write(Data("untouched".utf8), to: other)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertThrowsError(try PrivateFiles.write(Data("bad".utf8), to: link))
        XCTAssertThrowsError(try PrivateFiles.read(link))
        let event = ActivityEvent(source: .cli, session: ActivityEvent.digest("id"), kind: .working, timestamp: Date())
        XCTAssertThrowsError(try LocalBridge.send(event, root: root))
    }
}
