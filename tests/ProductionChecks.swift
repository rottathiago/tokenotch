import Darwin
import Foundation
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum ProductionChecks {
    struct Failure: Error { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }
    static func versions() throws {
        for invalid in ["", "1.0", "01.0.0", "1.0.0-", "1.0.0+", "1.0.0-01", "1.0.0-..",
                        "1.0.0/../../evil", "https://example.invalid", "1.0.0\n", "1.0.0+a+b"] {
            try require(ReleaseVersion(invalid) == nil, "Invalid version admitted: \(invalid)")
        }
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                       "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.2.0", "1.10.0", "2.0.0"]
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            guard let a = ReleaseVersion(left), let b = ReleaseVersion(right) else {
                throw Failure(description: "Valid version rejected")
            }
            try require(a < b, "Versions sorted lexically rather than by SemVer")
        }
        try require(ReleaseVersion("v1.0.0+build.2") == ReleaseVersion("1.0.0"), "Build metadata changed precedence")
        let release = try ReleaseInfo.parse(Data(#"{"tag_name":"v1.1.0","draft":false,"prerelease":false,"html_url":"https://evil.invalid"}"#.utf8))
        try require(release.url.host == "github.com" && release.url.path == "/\(TokenotchProduct.repository)/releases/tag/v1.1.0",
                    "Untrusted release URL escaped official repository")
        for data in [
            #"{"tag_name":"v1.1.0","draft":true,"prerelease":false}"#,
            #"{"tag_name":"v1.1.0-rc.1","draft":false,"prerelease":false}"#,
            #"{"tag_name":"v1.1.0","draft":false,"prerelease":true}"#,
            #"{"tag_name":"v1.1.0"}"#, "{}"
        ] {
            do {
                _ = try ReleaseInfo.parse(Data(data.utf8))
                throw Failure(description: "Invalid release response admitted")
            } catch is ReleaseCheckError {}
        }
    }

    static func accountLogin() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-account-\(UUID().uuidString)")
        try PrivateFiles.directory(root)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Could not remove isolated account fixture.\n", stderr) }
        }
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/fixture-copilot.py")
        for version in [2, 3] {
            let home = root.appendingPathComponent("protocol-\(version)")
            try PrivateFiles.directory(home)
            try PrivateFiles.write(Data((version == 3 ? "protocol-3" : "").utf8),
                                   to: home.appendingPathComponent("fixture-mode"))
            func requestedMethods() throws -> [String] {
                try JSONDecoder().decode([String].self, from: Data(contentsOf: home.appendingPathComponent("fixture-requests.json")))
            }
            do {
                _ = try CopilotRuntime(executable: fixture, home: home).snapshot()
                throw Failure(description: "A signed-out account refresh unexpectedly succeeded")
            } catch CopilotConnectionError.signIn {}
            let signedOutRequests = try requestedMethods()
            try require(signedOutRequests == ["status.get", "auth.getStatus"], "Signed-out polling must stop before quota")
            try require(!FileManager.default.fileExists(atPath: home.appendingPathComponent("fixture-signed-in").path),
                        "Polling must not start browser sign-in")

            try CopilotRuntime(executable: fixture, home: home).signIn()
            for _ in 0..<2 {
                let snapshot = try CopilotRuntime(executable: fixture, home: home).snapshot()
                try require(snapshot.identity.login == "fixture-user", "A fresh runtime must reuse the explicit sign-in")
                try require(snapshot.primaryQuota?.usedRequests == Decimal(string: "58.5"), "Signed-in quota must be available")
                let requests = try requestedMethods()
                try require(requests == ["status.get", "auth.getStatus", "account.getQuota", "auth.getStatus"],
                            "Every refresh must verify identity around the quota read")
            }
            try FileManager.default.removeItem(at: home.appendingPathComponent("fixture-signed-in"))
            do {
                _ = try CopilotRuntime(executable: fixture, home: home).snapshot()
                throw Failure(description: "A refresh reused an expired sign-in")
            } catch CopilotConnectionError.signIn {}
        }
        print("PASS: protocol 2/3 signed-out polling, explicit login, saved-login refresh, and expired credentials.")
    }

    static func applicationLock() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-launch-lock-\(UUID().uuidString)")
        try PrivateFiles.directory(root)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Could not remove isolated launch-lock fixture.\n", stderr) }
        }
        func reject(_ url: URL, with expected: ApplicationLockError) throws {
            do {
                let lock = try ApplicationLock(url: url)
                withExtendedLifetime(lock) {}
                throw Failure(description: "Unsafe or duplicate launch lock was accepted")
            } catch let error as ApplicationLockError {
                try require(error == expected, "Launch lock reported the wrong failure")
            }
        }
        let url = root.appendingPathComponent(".tokenotch-launch.lock")
        let dataRoot = root.appendingPathComponent("data")
        try PrivateFiles.directory(dataRoot)
        let savedData = dataRoot.appendingPathComponent("saved-data")
        let original = Data("existing-data".utf8)
        try PrivateFiles.write(original, to: savedData)
        do {
            let lock = try ApplicationLock(url: url)
            defer { withExtendedLifetime(lock) {} }
            var info = stat()
            try require(lstat(url.path, &info) == 0 && info.st_uid == getuid()
                        && info.st_mode & 0o777 == 0o600 && info.st_nlink == 1,
                        "Launch lock must be an owner-only file")
            try reject(url, with: .busy)
        }
        // An existing lock file is reusable after its owner releases the descriptor.
        do {
            let lock = try ApplicationLock(url: url)
            defer { withExtendedLifetime(lock) {} }
            try reject(url, with: .busy)
        }
        for mode: mode_t in [0o644, 0o660] {
            try require(chmod(url.path, mode) == 0, "Could not prepare unsafe lock permissions")
            try reject(url, with: .invalid)
        }
        try require(chmod(url.path, 0o600) == 0, "Could not restore fixture permissions")
        let symbolic = root.appendingPathComponent("symbolic.lock")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: url)
        try reject(symbolic, with: .invalid)
        let linked = root.appendingPathComponent("linked.lock")
        try FileManager.default.linkItem(at: url, to: linked)
        try reject(url, with: .invalid)
        try reject(linked, with: .invalid)
        try FileManager.default.removeItem(at: linked)
        try reject(dataRoot, with: .invalid)
        try reject(root.appendingPathComponent("missing/launch.lock"), with: .invalid)
        let preserved = try Data(contentsOf: savedData)
        try require(preserved == original, "Launch locking changed existing data")
        print("PASS: exclusive/reusable launch lock, private permissions, unsafe-path rejection, and data preservation.")
    }

    static func protocolGating() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-protocol-\(UUID().uuidString)")
        try PrivateFiles.directory(root)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Could not remove isolated protocol fixture.\n", stderr) }
        }
        let runtimeHome = root.appendingPathComponent("runtime")
        try PrivateFiles.directory(runtimeHome)
        try PrivateFiles.write(Data("incompatible".utf8), to: runtimeHome.appendingPathComponent("fixture-mode"))
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/fixture-copilot.py")
        let runtime = CopilotRuntime(executable: fixture, home: runtimeHome)
        do {
            _ = try runtime.snapshot()
            throw Failure(description: "Unsupported runtime protocol was used")
        } catch CopilotConnectionError.incompatible {}
        let requests = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: runtimeHome.appendingPathComponent("fixture-requests.json")))
        try require(requests == ["status.get"], "Unknown protocols must be rejected before auth or quota requests")
        print("PASS: unknown runtime protocols rejected before authentication or quota requests.")
    }
}
