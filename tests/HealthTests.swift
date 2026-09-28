import Foundation
import TokenotchCore
import XCTest

final class HealthTests: XCTestCase {
    private func feed(status: String, affected: String = "copilot", include: Bool = true) throws -> [ServiceIncident] {
        let incident: [String: Any] = ["id": "incident", "status": status, "name": "untrusted text",
                                       "components": [["id": affected]]]
        return try HealthParser.parse(JSONSerialization.data(withJSONObject: [
            "components": [["id": "copilot", "name": "Copilot"], ["id": "git", "name": "Git Operations"]],
            "incidents": include ? [incident] : []
        ]))
    }
    func testOnlyCopilotIncidentsAndExplicitRecovery() throws {
        var ledger = HealthLedger()
        XCTAssertTrue(ledger.observe(try feed(status: "investigating", include: false)).isEmpty)
        XCTAssertTrue(ledger.observe(try feed(status: "investigating", affected: "git")).isEmpty)
        XCTAssertEqual(ledger.observe(try feed(status: "investigating")).map(\.category), [.incident])
        XCTAssertTrue(ledger.observe(try feed(status: "investigating")).isEmpty)
        XCTAssertTrue(ledger.observe(try feed(status: "investigating", include: false)).isEmpty)
        XCTAssertEqual(ledger.observe(try feed(status: "resolved")).map(\.category), [.recovery])
        XCTAssertTrue(ledger.observe(try feed(status: "resolved")).isEmpty)
    }
    func testNoOldIncidentBurstAtStartup() throws {
        var ledger = HealthLedger()
        XCTAssertTrue(ledger.observe(try feed(status: "investigating")).isEmpty)
    }
    func testUnknownSchemaIsNotHealthy() {
        XCTAssertThrowsError(try HealthParser.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try HealthParser.parse(Data(repeating: 32, count: 262_145)))
    }
}
