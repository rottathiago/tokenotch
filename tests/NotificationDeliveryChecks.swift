import AppKit
import TokenotchCore
import UserNotifications
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum NotificationDeliveryChecks {
    static func channels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-delivery-\(UUID().uuidString)")
        let suite = "tokenotch-delivery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        var sounds = 0
        var expansions = 0
        var permissionChecks = 0
        var allowed = true
        var soundWorks = true
        var postingWorks = true
        var requests: [UNNotificationRequest] = []
        let model = TokenotchModel(defaults: defaults, root: root, playNotificationSound: {
            sounds += 1
            return soundWorks
        }, desktopNotificationsAllowed: {
            permissionChecks += 1
            return allowed
        }, postNotification: {
            requests.append($0)
            if !postingWorks { throw TokenotchError.unavailable }
        })
        model.expandNotch = { expansions += 1 }
        model.clearLocalHistory()
        try NotchChecks.require(model.errorMessage == nil, "Delivery fixture storage must be ready")
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        for desktop in [false, true] {
            for sound in [false, true] {
                for expand in [false, true] {
                    for permission in [false, true] {
                        allowed = permission
                        var preferences = NotificationPreferences()
                        preferences.enabled = true
                        preferences.desktop = desktop
                        preferences.sound = sound
                        preferences.expandNotch = expand
                        model.options.notifications = preferences
                        sounds = 0; expansions = 0; permissionChecks = 0; requests = []
                        model.testNotification()
                        settle()
                        try NotchChecks.require(sounds == (sound ? 1 : 0),
                                                "Sound is independent of banners and their permission")
                        try NotchChecks.require(expansions == (expand ? 1 : 0),
                                                "Session cards are independent of banner permission")
                        try NotchChecks.require(permissionChecks == (desktop ? 1 : 0),
                                                "Sound-only delivery must not request desktop permission")
                        try NotchChecks.require(requests.count == (desktop && permission ? 1 : 0),
                                                "Desktop delivery must respect its own control and permission")
                        try NotchChecks.require(requests.allSatisfy { $0.content.sound == nil },
                                                "Native banners cannot play a duplicate chime")
                    }
                }
            }
        }
        allowed = true
        postingWorks = false
        sounds = 0
        model.testNotification()
        settle()
        try NotchChecks.require(sounds == 1 && model.notificationStatus == "Desktop delivery failed",
                                "Failed banners must not silence opted-in sound or hide delivery errors")
        model.options.notifications.desktop = false
        soundWorks = false
        model.testNotification()
        try NotchChecks.require(model.notificationSoundError == "Sound playback failed",
                                "Audio failure must be reported explicitly")
        soundWorks = true
        model.testNotification()
        try NotchChecks.require(model.notificationSoundError == nil, "Successful audio must clear an earlier playback failure")

        for mode in 0..<4 {
            var preferences = NotificationPreferences()
            preferences.enabled = true
            preferences.sound = true
            preferences.expandNotch = true
            switch mode {
            case 0: preferences.enabled = false
            case 1: preferences.categories = []
            case 2: preferences.snoozedUntil = Date().addingTimeInterval(3600)
            default:
                preferences.quietEnabled = true
                preferences.quietStart = 0
                preferences.quietEnd = 0
            }
            model.options.notifications = preferences
            sounds = 0; expansions = 0; permissionChecks = 0; requests = []
            model.testNotification()
            settle()
            try NotchChecks.require(sounds == 0 && expansions == 0 && permissionChecks == 0 && requests.isEmpty,
                                    "Mute, categories, snooze and quiet hours suppress every channel")
        }

        var preferences = NotificationPreferences()
        preferences.enabled = true
        preferences.desktop = false
        preferences.sound = true
        preferences.expandNotch = true
        model.options.notifications = preferences
        let notice = Notice(id: "delivery", category: .stopped, title: "Stopped", body: "Observed")
        sounds = 0; expansions = 0
        model.deliver(notice)
        model.deliver(notice)
        try NotchChecks.require(sounds == 1 && expansions == 1, "Duplicate observations cannot repeat audio or cards")
        preferences.categories = []
        model.options.notifications = preferences
        let muted = Notice(id: "muted-delivery", category: .stopped, title: "Stopped", body: "Observed")
        model.deliver(muted)
        model.options.notifications.categories.insert(.stopped)
        model.deliver(muted)
        try NotchChecks.require(sounds == 1 && expansions == 1, "Unmuting cannot replay a consumed notice")

        var ledger = NotificationLedger()
        preferences.categories.insert(.stopped)
        try NotchChecks.require(ledger.evaluate(Notice(id: "managed", category: .stopped, title: "", body: ""),
            preferences: preferences, now: Date(), managedMute: true) == nil,
            "Managed mute must suppress sound and all other delivery")

        guard let chime = NSSound(named: "Glass") else {
            throw NotchCheckFailure.failed("The notification chime must be available")
        }
        let volume = chime.volume
        chime.volume = 0
        defer { chime.stop(); chime.volume = volume }
        let audioModel = TokenotchModel(defaults: defaults, root: root.appendingPathComponent("audio"))
        audioModel.clearLocalHistory()
        audioModel.options.notifications = preferences
        audioModel.testNotification()
        audioModel.testNotification()
        try NotchChecks.require(chime.isPlaying && audioModel.notificationSoundError == nil,
                                "Closely spaced notifications must restart the native chime without a playback error")
    }

    private final class FixtureScreen: NSScreen {
        var bounds = CGRect.zero
        override var frame: CGRect { bounds }
        override var visibleFrame: CGRect { bounds.insetBy(dx: 0, dy: 30) }
    }

    static func displays() throws {
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first else {
            throw NotchCheckFailure.failed("Notification display checks require a GUI session")
        }
        let first = FixtureScreen()
        let second = FixtureScreen()
        let frame = screen.frame
        first.bounds = CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        second.bounds = first.bounds.offsetBy(dx: frame.width / 2, dy: 0)
        var connected: [NSScreen] = [first, second]
        var hidden: NSScreen?
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-display-delivery-\(UUID().uuidString)")
        let suite = "tokenotch-display-delivery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var sounds = 0
        let model = TokenotchModel(defaults: defaults, root: root, playNotificationSound: { sounds += 1; return true })
        model.clearLocalHistory()
        model.options.allDisplays = true
        model.options.notifications.enabled = true
        model.options.notifications.desktop = false
        model.options.notifications.sound = true
        model.options.notifications.expandNotch = true
        var now = Date()
        var pointer = CGPoint(x: -100_000, y: -100_000)
        let fleet = NotchFleet(model: model, openSettings: {},
            isFullScreen: { $0 === hidden }, pointerLocation: { pointer }, now: { now }, screens: { connected })
        model.expandNotch = { [weak fleet] in fleet?.reveal(allowSettings: false) }
        let before = Set(app.windows.map(ObjectIdentifier.init))
        let previousKey = app.keyWindow
        defer {
            fleet.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func windows() -> [NSWindow] {
            app.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0 is NotchPanel }
        }
        func cards() -> [NSWindow] {
            windows().filter { $0.contentView is ShapeHostingView<CopilotSummaryView> }
        }
        model.attention.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest("displays"),
                                             kind: .inputRequested, timestamp: now), now: now)
        fleet.start()
        settle()
        try NotchChecks.require(windows().count == 2, "Two display fixtures must each have an idle notch")
        guard let secondBadge = windows().first(where: { second.frame.contains($0.frame) }) else {
            throw NotchCheckFailure.failed("Missing second-display notch")
        }
        let pill = NotchLayout.badgeRect(in: CGRect(origin: .zero, size: secondBadge.frame.size),
                                        edge: .right, scale: 1, collapsed: true)
        pointer = CGPoint(x: secondBadge.frame.minX + pill.midX, y: secondBadge.frame.maxY - pill.midY)
        settle()
        // A hover becoming eligible during delivery must not cancel a sibling display's alert.
        now = now.addingTimeInterval(0.2)
        model.testNotification()
        pointer = CGPoint(x: -100_000, y: -100_000)
        settle()
        try NotchChecks.require(cards().count == 2 && sounds == 1,
                                "One notification must open both display cards and play exactly one sound")
        for display in connected {
            try NotchChecks.require(cards().filter { display.visibleFrame.contains($0.frame) }.count == 1,
                                    "Each notification card must be placed on its own display")
        }
        try NotchChecks.require(app.keyWindow === previousKey, "Automatic expansion must not steal focus")
        now = now.addingTimeInterval(2.9)
        settle()
        try NotchChecks.require(cards().count == 2, "Every display must receive the full minimum alert duration")
        try NotchChecks.require(model.attention.state.notices.allSatisfy { $0.viewedAt == nil && $0.disposition == .pending },
                                "Untouched automatic cards cannot acknowledge or dismiss requests")
        guard let firstCard = cards().first(where: { first.visibleFrame.contains($0.frame) }) else {
            throw NotchCheckFailure.failed("Missing first-display card")
        }
        pointer = CGPoint(x: firstCard.frame.midX, y: firstCard.frame.midY)
        now = now.addingTimeInterval(0.2)
        settle()
        now = now.addingTimeInterval(0.3)
        settle()
        try NotchChecks.require(cards().count == 1 && firstCard.isVisible,
                                "Only the engaged display stays expanded after the alert expires")
        pointer = CGPoint(x: -100_000, y: -100_000)
        now = now.addingTimeInterval(0.1)
        settle()
        now = now.addingTimeInterval(0.3)
        settle()
        try NotchChecks.require(cards().isEmpty, "Unengaged cards collapse independently")

        fleet.reveal(keyboard: true)
        let pinned = cards().first
        fleet.reveal(allowSettings: false)
        settle()
        try NotchChecks.require(cards().count == 2 && pinned?.isVisible == true, "Notifications preserve an existing pinned card")
        now = now.addingTimeInterval(3.1)
        settle()
        now = now.addingTimeInterval(0.3)
        settle()
        try NotchChecks.require(cards().count == 1 && pinned?.isVisible == true, "Other displays time out without unpinning a deliberate card")

        hidden = first
        fleet.reveal(allowSettings: false)
        settle()
        try NotchChecks.require(cards().count == 1 && second.visibleFrame.contains(cards()[0].frame),
                                "A full-screen display must stay hidden while other displays receive alerts")
        hidden = nil
        connected = [second]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        settle()
        fleet.reveal(allowSettings: false)
        settle()
        try NotchChecks.require(windows().count == 2 && cards().count == 1,
                                "Disconnecting a display must dispose of its notch and notification card")
        connected = [first, second]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        settle()
        fleet.reveal(allowSettings: false)
        settle()
        try NotchChecks.require(windows().count == 4 && cards().count == 2,
                                "Reconnected displays must receive subsequent notifications")
        connected = NSScreen.screens
        model.options.allDisplays = false
        settle()
        fleet.reveal(allowSettings: false)
        settle()
        try NotchChecks.require(windows().count == 2 && cards().count == 1,
                                "Single-display mode must continue to expand only its selected notch")
        model.options.showNotch = false
        settle()
        fleet.reveal(allowSettings: false)
        try NotchChecks.require(windows().isEmpty, "Notifications cannot override the master notch visibility setting")
        fleet.stop()
        try NotchChecks.require(windows().isEmpty, "Stopping the fleet must clean up every notification window")
    }
}
