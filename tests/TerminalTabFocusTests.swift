import TokenotchCore
import XCTest

final class TerminalTabFocusTests: XCTestCase {
    func testFocusUsesOnlyAllowlistedApplicationsNotEventPathsOrCommands() {
        XCTAssertEqual(Client.cli.bundleID, "com.apple.Terminal")
        XCTAssertEqual(Client.vscode.bundleID, "com.microsoft.VSCode")
        XCTAssertNil(Client(rawValue: "vscode://untrusted/path"))
    }
    func testStoppedNeverClaimsSuccess() {
        let event = ActivityEvent(source: .cli, session: ActivityEvent.digest("test"), kind: .stopped, timestamp: Date())
        let notice = Notice.activity(event)
        XCTAssertEqual(notice?.title, "Copilot execution stopped")
        XCTAssertTrue(notice?.body.contains("does not establish task success") == true)
        XCTAssertNil(Notice.activity(ActivityEvent(source: .cli, session: event.session, kind: .cancelled, timestamp: Date())))
    }
}
