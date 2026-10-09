import AppKit
import CoreGraphics
import Darwin
import Foundation

@main
@MainActor
enum InstallerSmoke {
    enum Failure: Error {
        case check(String)
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.check(message) }
    }

    static func status(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let result = try status(executable, arguments)
        try require(result == 0, "\(executable) failed with exit \(result)")
    }

    static func verify(_ app: URL) throws {
        try run("/usr/bin/python3", ["scripts/verify-bundle.py", app.path, "--universal"])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    static func hasSettingsWindow(_ pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
            return bounds.width >= 780 && bounds.height >= 560
        }
    }

    static func processExists(_ pid: pid_t) throws -> Bool {
        try require(pid > 0, "Invalid test process identifier")
        if kill(pid, 0) == 0 { return true }
        let code = errno
        if code == ESRCH { return false }
        throw Failure.check("Could not observe test process \(pid): errno \(code)")
    }

    static func launchAndStop(_ app: URL) throws {
        var application: NSRunningApplication?
        do {
            try run("/usr/bin/open", ["-n", app.path])
            let launchDeadline = ProcessInfo.processInfo.systemUptime + 30
            while ProcessInfo.processInfo.systemUptime < launchDeadline {
                application = NSWorkspace.shared.runningApplications.first {
                    $0.bundleURL?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path
                }
                if let application, hasSettingsWindow(application.processIdentifier) { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            guard let application else { throw Failure.check("Installed app did not launch") }
            try require(hasSettingsWindow(application.processIdentifier), "First-run Settings window was not visible")
            print("Installed app launched and showed first-run Settings: \(app.lastPathComponent)")
            try require(application.forceTerminate(), "Could not stop the owned test process")
            let quitDeadline = ProcessInfo.processInfo.systemUptime + 10
            while try processExists(application.processIdentifier) && ProcessInfo.processInfo.systemUptime < quitDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            let exited = try !processExists(application.processIdentifier)
            try require(exited, "Owned test process did not exit (pid \(application.processIdentifier))")
            print("Owned test process stopped for cleanup; graceful/interactive quit is not an acceptance result.")
        } catch {
            if let application, !application.isTerminated, !application.forceTerminate() {
                fputs("Could not terminate the owned installer test process.\n", stderr)
            }
            throw error
        }
    }

    static func check() throws {
        let environment = ProcessInfo.processInfo.environment
        try require(environment["GITHUB_ACTIONS"] == "true" &&
                    environment["RUNNER_ENVIRONMENT"] == "github-hosted" &&
                    environment["RUNNER_OS"] == "macOS",
                    "Installer smoke is restricted to disposable GitHub-hosted macOS runners")
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath)
        let home = files.homeDirectoryForCurrentUser
        let installed = URL(fileURLWithPath: "/Applications/Tokenotch.app")
        let copied = home.appendingPathComponent("Applications/Tokenotch.app")
        for path in [installed, copied, home.appendingPathComponent(".tokenotch"),
                     home.appendingPathComponent(".tokenotch-launch.lock"),
                     home.appendingPathComponent("Library/Preferences/io.github.rottathiago.tokenotch.plist")] {
            try require(!files.fileExists(atPath: path.path), "Refusing to modify an existing installation or profile")
        }
        try require(!NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "io.github.rottathiago.tokenotch"
        }, "Tokenotch is already running")
        try run("/usr/bin/sudo", ["-n", "/usr/sbin/installer", "-pkg",
                                 root.appendingPathComponent("build/packages/Tokenotch.pkg").path, "-target", "/"])
        try verify(installed)
        try launchAndStop(installed)

        let mount = files.temporaryDirectory.appendingPathComponent("tokenotch-install-\(UUID().uuidString)")
        try files.createDirectory(at: mount, withIntermediateDirectories: false)
        try run("/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
                                   "-mountpoint", mount.path,
                                   root.appendingPathComponent("build/packages/Tokenotch.dmg").path])
        do {
            try files.createDirectory(at: copied.deletingLastPathComponent(), withIntermediateDirectories: true)
            try run("/usr/bin/ditto", [mount.appendingPathComponent("Tokenotch.app").path, copied.path])
            try verify(copied)
            try launchAndStop(copied)
        } catch {
            do { try run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) }
            catch { fputs("Could not detach the installer test disk image: \(error)\n", stderr) }
            throw error
        }
        try run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])
        try files.removeItem(at: mount)
        let assessment = try status("/usr/sbin/spctl", ["--assess", "--type", "execute", installed.path])
        print("Gatekeeper CLI assessment exit: \(assessment); unsigned, not notarized; browser-download behavior is not established.")
        #if arch(arm64)
        print("Native installer/first-launch checks passed on arm64.")
        #elseif arch(x86_64)
        print("Native installer/first-launch checks passed on x86_64.")
        #else
        throw Failure.check("Unsupported native acceptance architecture")
        #endif
    }

    static func main() {
        do { try check() }
        catch {
            fputs("Installer smoke failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
