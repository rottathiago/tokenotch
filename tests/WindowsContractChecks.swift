import Foundation
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum WindowsContractChecks {
    struct Failure: Error { let message: String }

    static func run() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/hooks.json"))
        guard let corpus = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              corpus["version"] as? Int == 1,
              let now = corpus["nowUnixMs"] as? Double,
              let cases = corpus["cases"] as? [[String: Any]] else {
            throw Failure(message: "Invalid shared hook corpus")
        }
        for fixture in cases {
            guard let name = fixture["name"] as? String,
                  let source = (fixture["source"] as? String).flatMap(Client.init(rawValue:)),
                  let hook = fixture["hook"] as? String,
                  let payload = fixture["payload"] as? [String: Any],
                  ["expected", "error", "filtered"].filter({ fixture[$0] != nil }).count == 1 else {
                throw Failure(message: "Invalid shared hook fixture")
            }
            let result: ActivityEvent?
            do {
                result = try HookNormalizer.normalizeObservation(
                    JSONSerialization.data(withJSONObject: payload), source: source, hook: hook,
                    now: Date(timeIntervalSince1970: now / 1000))
            } catch let error as TokenotchError {
                let actual = error == .metricUpgrade ? "metricUpgrade" : "invalidEvent"
                guard fixture["error"] as? String == actual else { throw Failure(message: name) }
                continue
            }
            guard fixture["error"] == nil else { throw Failure(message: "\(name): expected rejection") }
            if fixture["filtered"] as? Bool == true {
                guard result == nil else { throw Failure(message: name) }
                continue
            }
            guard let event = result, let expected = fixture["expected"] as? [String: Any] else {
                throw Failure(message: name)
            }
            let encoded = try JSONEncoder().encode(event)
            guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  event.session == ActivityEvent.digest("synthetic-session") else {
                throw Failure(message: name)
            }
            object["timestampUnixMs"] = event.timestamp.timeIntervalSince1970 * 1000
            try compare(object, expected, name: name)
            let text = String(decoding: encoded, as: UTF8.self)
            guard !text.contains("CONTENT-MUST-NOT-SURVIVE"), !text.contains("synthetic-session") else {
                throw Failure(message: "\(name): content was not stripped")
            }
        }
        try liveState(root: root)
    }

    private static func liveState(root: URL) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/live-state.json"))
        guard let corpus = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              corpus["version"] as? Int == 1,
              let base = corpus["baseUnixMs"] as? Double,
              let cases = corpus["cases"] as? [[String: Any]] else {
            throw Failure(message: "Invalid shared live-state corpus")
        }
        for fixture in cases {
            guard let name = fixture["name"] as? String,
                  let steps = fixture["steps"] as? [[String: Any]],
                  let inspectAt = fixture["inspectAtMs"] as? Double,
                  let expected = fixture["expected"] as? [String: Any] else {
                throw Failure(message: "Invalid shared live-state fixture")
            }
            var activity = ActivityState()
            var ledger = TokenLedger()
            for step in steps {
                guard let at = step["atMs"] as? Double, let hook = step["hook"] as? String,
                      var fields = step["fields"] as? [String: Any] else { throw Failure(message: name) }
                fields["sessionId"] = "one"
                fields["timestamp"] = base + at
                let date = Date(timeIntervalSince1970: (base + at) / 1000)
                let event = try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: fields),
                    source: .cli, hook: hook, now: date)
                if event.kind.isMetric {
                    try ledger.observe(event, now: date)
                } else {
                    _ = try activity.accept(event, now: date)
                }
            }
            let now = Date(timeIntervalSince1970: (base + inspectAt) / 1000)
            activity.expire(now: now)
            ledger.expire(now: now)
            var actual: [String: Any] = [
                "sessionCount": activity.sessions.count,
                "workingCount": activity.sessions.values.filter { $0.isWorking(now: now) }.count,
                "label": NSNull(), "total": NSNull(), "calls": NSNull(), "contextCurrent": NSNull()
            ]
            if let session = activity.sessions.values.first { actual["label"] = session.label(now: now) }
            if let totals = ledger.totals {
                actual["total"] = String(totals.total)
                actual["calls"] = String(totals.calls)
            }
            if let context = ledger.bySession.first(where: { $0.id == ActivityEvent.digest("one") })?.context {
                actual["contextCurrent"] = context.usage.currentTokens
            }
            try compare(actual, expected, name: name)
        }
    }

    private static func compare(_ actual: [String: Any], _ expected: [String: Any], name: String) throws {
        for (key, value) in expected {
            if let nested = value as? [String: Any] {
                guard let received = actual[key] as? [String: Any] else { throw Failure(message: "\(name): \(key)") }
                try compare(received, nested, name: name)
            } else {
                guard let received = actual[key] as? NSObject, received.isEqual(value) else {
                    throw Failure(message: "\(name): \(key)")
                }
            }
        }
    }
}
