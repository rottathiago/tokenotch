import AppKit
import Combine
import TokenotchCore
import ServiceManagement
import UserNotifications
import os

struct TokenotchOptions: Codable {
    var notifications = NotificationPreferences()
    var healthEnabled = false
    var showNotch = true
    var autoHideNotch = true
    var allDisplays = false
    var edge = "right"
    var scale = 1.0
    var displayID: String?
    var foldsForFullScreen = true
    var offsets: [String: Double] = [:]
    var timeFormat: TimeFormat = .twentyFourHour

    private enum CodingKeys: String, CodingKey {
        case notifications, healthEnabled, showNotch, autoHideNotch, allDisplays
        case edge, scale, displayID, foldsForFullScreen, offsets, timeFormat
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try values.decode(NotificationPreferences.self, forKey: .notifications)
        healthEnabled = try values.decode(Bool.self, forKey: .healthEnabled)
        showNotch = try values.decode(Bool.self, forKey: .showNotch)
        // Older preferences had no idle-collapse setting.
        autoHideNotch = try values.decodeIfPresent(Bool.self, forKey: .autoHideNotch) ?? true
        allDisplays = try values.decode(Bool.self, forKey: .allDisplays)
        edge = try values.decode(String.self, forKey: .edge)
        scale = try values.decode(Double.self, forKey: .scale)
        displayID = try values.decodeIfPresent(String.self, forKey: .displayID)
        foldsForFullScreen = try values.decode(Bool.self, forKey: .foldsForFullScreen)
        offsets = try values.decode([String: Double].self, forKey: .offsets)
        timeFormat = try values.decodeIfPresent(TimeFormat.self, forKey: .timeFormat) ?? .twentyFourHour
        guard ["top", "bottom", "left", "right"].contains(edge), scale.isFinite,
              (0.75...1.5).contains(scale), offsets.count <= 4,
              offsets.allSatisfy({ ["top", "bottom", "left", "right"].contains($0.key) && $0.value.isFinite }),
              (0..<1440).contains(notifications.quietStart), (0..<1440).contains(notifications.quietEnd) else {
            throw TokenotchError.storage
        }
    }
}

enum SettingsTab {
    case usage, history, sessions, connections, notifications, appearance, privacy, about
}

@MainActor
final class TokenotchModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    let updates = ReleaseUpdateController()
    @Published var showOnboarding = false
    @Published private(set) var onboardingComplete: Bool
    @Published private(set) var onboarding: OnboardingProgress
    @Published private(set) var onboardingMessage: String?
    @Published private(set) var installedClients: Set<Client> = []
    @Published private(set) var connectionSetupErrors: [Client: String] = [:]
    @Published private(set) var loginItemStatus = ""
    @Published private(set) var preferencesUnreadable = false
    @Published var settingsTab = SettingsTab.usage
    @Published var options = TokenotchOptions() { didSet { saveOptions() } }
    @Published private(set) var sessions: [ObservedSession] = []
    @Published private(set) var connection: [Client: String] = [:]
    @Published private(set) var registeredClients: Set<Client> = []
    @Published private(set) var lastEvent: [Client: Date] = [:]
    @Published private(set) var lastActivityEvent: [Client: Date] = [:]
    @Published private(set) var lastCLIUsageEvent: Date?
    @Published private(set) var health = "Not checked"
    @Published private(set) var healthObservedAt: Date?
    @Published private(set) var healthIncident = false
    @Published private(set) var notificationStatus = "Not requested"
    @Published private(set) var notificationSoundError: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var bridgeStatus = "Not started"
    @Published private(set) var accountSnapshot: CopilotAccountSnapshot?
    @Published private(set) var accountStatus = "Not connected"
    @Published private(set) var accountBusy = false
    @Published private(set) var accountStale = false
    @Published private(set) var tokenTotals: ObservedTokens?
    @Published private(set) var todayTokenTotals: ObservedTokens?
    @Published private(set) var modelTokenTotals: [ObservedModelTokens] = []
    @Published private(set) var todayModelTokenTotals: [ObservedModelTokens] = []
    @Published private(set) var todayTimeline: UsageTimeline?
    @Published var liveUsageDetail: LiveUsageDetail?
    @Published var selectedSession: SessionDetailTarget? {
        didSet { notificationNavigationMessage = nil }
    }
    @Published var notificationNavigationMessage: String?
    @Published var showLiveSessions = false
    @Published var usageNavigation = UUID()
    @Published private(set) var sessionMetrics: [ObservedSessionMetrics] = []
    @Published private(set) var tokenSampleLimitReached = false
    @Published private(set) var insights: [SessionInsight] = []
    let history: HistoryController
    let vscode: VSCodeIntegrationController
    let timeline: SessionTimelineController
    let attention: SessionAttentionController
    @Published var cliExecutable: String {
        didSet { defaults.set(cliExecutable, forKey: "copilotExecutable") }
    }
    @Published var clock = Date()
    var expandNotch: (() -> Void)?
    var openNotificationDetails: (() -> Void)?
    private let playNotificationSound: () -> Bool
    private let desktopNotificationsAllowed: () async -> Bool
    private let postNotification: (UNNotificationRequest) async throws -> Void
    private let defaults: UserDefaults
    private let bridge: LocalBridge
    private let installation: HookInstallation
    private let bundleURL: URL
    private var onboardingDestination: SettingsTab?
    private let root: URL
    private var activity = ActivityState()
    private var lifecycleActivity = ActivityState()
    private var ledger = NotificationLedger()
    private var healthLedger = HealthLedger()
    private var timer: Timer?
    private var sourceSubscription: AnyCancellable?
    private var healthTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var accountRuntime: CopilotRuntime?
    private var accountGeneration = UUID()
    private var nextAccountCheck = Date.distantPast
    private var tokenLedger = TokenLedger()
    private var sessionInsights = SessionInsights()
    private var contextWarnings = ContextWarningPolicy()
    private var contextWarningsEnabled = false
    private var nextHealthCheck = Date.distantPast
    private var loaded = false
    private var storageReady = false
    private var startedAt = Date()
    private let log = Logger(subsystem: "io.github.rottathiago.tokenotch", category: "app")
    var managedMute: Bool { defaults.objectIsForced(forKey: "DisableNotifications") && defaults.bool(forKey: "DisableNotifications") }
    var managedHooksDisabled: Bool { defaults.objectIsForced(forKey: "DisableHooks") && defaults.bool(forKey: "DisableHooks") }
    var managedHealthDisabled: Bool { defaults.objectIsForced(forKey: "DisableHealth") && defaults.bool(forKey: "DisableHealth") }
    var managedAccountDisabled: Bool { defaults.objectIsForced(forKey: "DisableAccountConnection") && defaults.bool(forKey: "DisableAccountConnection") }
    var accountConnectionEnabled: Bool { defaults.bool(forKey: "accountConnectionEnabled") }
    var primaryQuota: CopilotQuota? {
        accountSnapshot?.primaryQuota
    }
    var usageMessage: String {
        guard let quota = primaryQuota else { return accountSnapshot == nil ? "Sign in to view your Copilot account quota." : "This account did not report a metered quota." }
        let used = NSDecimalNumber(decimal: quota.usedRequests).stringValue
        let allowance = quota.isUnlimitedEntitlement ? "unlimited" : NSDecimalNumber(decimal: quota.entitlementRequests).stringValue
        return "\(used) / \(allowance) \(quota.title.lowercased())\(accountStale ? " (stale)" : "")"
    }

    init(defaults: UserDefaults, root: URL = PrivateFiles.root,
         installation: HookInstallation? = nil, bundleURL: URL = Bundle.main.bundleURL,
         openSetupURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         playNotificationSound: @escaping () -> Bool = {
             guard let sound = NSSound(named: "Glass") else { return false }
             if sound.isPlaying { sound.stop() }
             return sound.play()
         },
         desktopNotificationsAllowed: @escaping () async -> Bool = {
             let settings = await UNUserNotificationCenter.current().notificationSettings()
             return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
         },
         postNotification: @escaping (UNNotificationRequest) async throws -> Void = {
             try await UNUserNotificationCenter.current().add($0)
         }) {
        self.defaults = defaults
        onboardingComplete = defaults.bool(forKey: "onboardingComplete.v1")
        onboarding = OnboardingProgress(defaults: defaults)
        self.root = root
        self.bundleURL = bundleURL
        self.playNotificationSound = playNotificationSound
        self.desktopNotificationsAllowed = desktopNotificationsAllowed
        self.postNotification = postNotification
        history = HistoryController(defaults: defaults, root: root)
        vscode = VSCodeIntegrationController(defaults: defaults, root: root, openSetupURL: openSetupURL)
        timeline = SessionTimelineController(defaults: defaults, root: root)
        attention = SessionAttentionController(defaults: defaults, root: root)
        cliExecutable = defaults.string(forKey: "copilotExecutable") ?? Self.detectCLI()
        bridge = LocalBridge(root: root)
        self.installation = installation ?? HookInstallation(root: root)
        super.init()
        sourceSubscription = history.$selectedSource.sink { [weak self] source in
            self?.liveUsageDetail = nil
            self?.updateTokenMetrics(now: Date(), source: source)
        }
        vscode.onBatch = { [weak self] batch in self?.receiveTelemetry(batch) }
        vscode.onAvailability = { [weak self] _ in
            guard let self else { return }
            self.history.setAvailableSources(self.historySources)
        }
        vscode.onCoverageGap = { [weak self] sources in self?.history.markGap(sources: sources) }
    }

    func start() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        do {
            try PrivateFiles.directory(root)
            if let data = defaults.data(forKey: "preferences.v1") {
                do { options = try JSONDecoder().decode(TokenotchOptions.self, from: data) }
                catch { preferencesUnreadable = true; throw error }
            }
            if let data = try PrivateFiles.read(root.appendingPathComponent("notifications.json")) {
                ledger = try JSONDecoder().decode(NotificationLedger.self, from: data)
                guard ledger.version == 1 else { throw TokenotchError.storage }
            }
            storageReady = true
        } catch { report(.storage) }
        loaded = true
        attention.start()
        refreshConnectionInstallations()
        UNUserNotificationCenter.current().delegate = self
        refreshPermission()
        refreshLoginItemStatus()
        if !managedHooksDisabled {
            do {
                bridge.onEvent = { [weak self] event in
                    Task { @MainActor in self?.receive(event) }
                }
                bridge.onFailure = { [weak self] error in
                    Task { @MainActor in
                        self?.timeline.markInterruption()
                        self?.report(error)
                    }
                }
                try bridge.start()
                bridgeStatus = "Listening locally"
            } catch { bridgeStatus = "Unavailable (another Tokenotch copy may be running)"; report(.bridgeUnavailable) }
        } else { bridgeStatus = "Disabled by managed policy" }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        history.start(available: cliHistoryAvailable)
        if !managedHooksDisabled { vscode.start() }
        timeline.start(clients: timelineClients)
        tick()
    }

    func stop() {
        accountGeneration = UUID()
        updates.stop()
        timer?.invalidate()
        healthTask?.cancel()
        accountTask?.cancel()
        accountRuntime?.cancel()
        bridge.stop()
        vscode.stop()
        history.stop()
        timeline.stop()
    }

    private func saveOptions() {
        guard loaded, !preferencesUnreadable else { return }
        do { defaults.set(try JSONEncoder().encode(options), forKey: "preferences.v1") }
        catch { report(.storage) }
        let contextEnabled = options.notifications.enabled && options.notifications.categories.contains(.context) && !managedMute
        if contextEnabled != contextWarningsEnabled {
            contextWarnings = ContextWarningPolicy()
            contextWarningsEnabled = contextEnabled
        }
        if !options.healthEnabled {
            healthTask?.cancel()
            healthTask = nil
            health = "Not checked (disabled)"
            healthObservedAt = nil
            healthIncident = false
            healthLedger = HealthLedger()
        } else { refreshHealth() }
    }

    private func tick() {
        clock = Date()
        activity.expire(now: clock)
        lifecycleActivity.expire(now: clock)
        updateTokenMetrics(now: clock)
        history.setAvailableSources(historySources)
        history.tick(now: clock)
        timeline.setAvailable(timelineClients)
        timeline.tick(now: clock)
        attention.tick(now: clock)
        insights = insights.filter { clock.timeIntervalSince($0.observedAt) < 86_400 }
        sessions = activity.sessions.values.sorted { $0.observedAt > $1.observedAt }
        if storageReady, ledger.expire(now: clock) {
            do {
                try PrivateFiles.write(try JSONEncoder().encode(ledger), to: root.appendingPathComponent("notifications.json"))
            } catch { storageReady = false; report(.storage) }
        }

        for client in Client.allCases {
            if let date = lastEvent[client], clock.timeIntervalSince(date) > 300 {
                connection[client] = "No recent events; coverage unknown"
            }
        }
        do {
            if let marker = try PrivateFiles.read(root.appendingPathComponent("bridge-failure"), limit: 128) {
                bridgeStatus = marker == Data("metric-upgrade".utf8) ? TokenotchError.metricUpgrade.rawValue
                    : "A hook delivery failed. Re-test both clients."
            }
        } catch { report(.unsafePath) }
        refreshHealth()
        refreshAccount()
    }

    func resumeAfterWake() {
        nextAccountCheck = .distantPast
        nextHealthCheck = .distantPast
        refreshPermission()
        refreshLoginItemStatus()
        tick()
    }

    private func receive(_ event: ActivityEvent) {
        guard !managedHooksDisabled else { return }
        do {
            guard try PrivateFiles.read(root.appendingPathComponent("\(event.source.rawValue).registration")) != nil else { return }
            try event.validate(now: Date())
            let sessionNotice = attention.observe(event, now: Date())
            if event.kind.isAttention {
                guard let sessionNotice else { return }
                lastEvent[event.source] = max(lastEvent[event.source] ?? .distantPast, event.timestamp)
                lastActivityEvent[event.source] = max(lastActivityEvent[event.source] ?? .distantPast, event.timestamp)
                connection[event.source] = "Receiving session attention reports"
                if event.timestamp >= startedAt,
                   let notice = Notice.activity(event, sessionNotice: sessionNotice) { deliver(notice) }
                return
            }
            if event.kind.isActivitySnapshot {
                let now = Date()
                if try activity.accept(event, now: now) {
                    sessions = activity.sessions.values.sorted { $0.observedAt > $1.observedAt }
                }
                clock = now
                lastEvent[.cli] = max(lastEvent[.cli] ?? .distantPast, event.timestamp)
                lastActivityEvent[.cli] = max(lastActivityEvent[.cli] ?? .distantPast, event.timestamp)
                connection[.cli] = "Receiving live session activity"
                return
            }
            if event.kind != .contextInvalidated { timeline.observe(event) }
            if event.kind.isMetric {
                let now = Date()
                try event.validate(now: now)
                if event.kind != .compaction { try tokenLedger.observe(event, now: now) }
                sessionInsights.observe(event, now: now)
                insights = sessionInsights.sessions
                if event.kind != .contextInvalidated { history.observe(event) }
                if let notice = contextWarnings.evaluate(event, now: now) { deliver(notice) }
                updateTokenMetrics(now: now)
                connection[.cli] = "Receiving live developer metrics"
                lastEvent[.cli] = event.timestamp
                if event.kind == .usage { lastCLIUsageEvent = max(lastCLIUsageEvent ?? .distantPast, event.timestamp) }
                return
            }
            let now = Date()
            let acceptedLifecycle = try lifecycleActivity.accept(event, now: now)
            if try activity.accept(event, now: now) {
                sessions = activity.sessions.values.sorted { $0.observedAt > $1.observedAt }
            }
            // Snapshot delivery must not suppress an otherwise new lifecycle notification.
            guard acceptedLifecycle else { return }
            lastEvent[event.source] = max(lastEvent[event.source] ?? .distantPast, event.timestamp)
            lastActivityEvent[event.source] = max(lastActivityEvent[event.source] ?? .distantPast, event.timestamp)
            connection[event.source] = "Receiving \(event.kind.rawValue) events"
            if event.timestamp >= startedAt, let sessionNotice,
               let notice = Notice.activity(event, sessionNotice: sessionNotice) { deliver(notice) }
        } catch { report(.invalidEvent) }
    }

    private func updateTokenMetrics(now: Date) {
        updateTokenMetrics(now: now, source: history.selectedSource)
    }

    private func updateTokenMetrics(now: Date, source: UsageSource?) {
        clock = now
        if liveUsageDetail?.isExpired(now: now) == true { liveUsageDetail = nil }
        tokenLedger.expire(now: now)
        var filtered = tokenLedger.filtered(source)
        tokenTotals = filtered.totals
        todayTokenTotals = filtered.today(now: now)
        modelTokenTotals = filtered.byModel
        todayModelTokenTotals = filtered.todayByModel(now: now)
        let timeline = filtered.hourlyTimeline(now: now)
        if todayTimeline != timeline { todayTimeline = timeline }
        sessionMetrics = filtered.bySession
        tokenSampleLimitReached = tokenLedger.lastDiscardedAt != nil
    }

    private func receiveTelemetry(_ batch: TelemetryBatch) {
        guard !managedHooksDisabled, vscode.enabled else { return }
        let now = Date()
        for event in batch.events {
            do {
                try tokenLedger.observe(event, now: now, allowingDelayed: true)
                history.observe(event)
                if event.metricSessionReported != false { timeline.observe(event) }
            } catch { report(.invalidEvent) }
        }
        updateTokenMetrics(now: now)
    }

    func configureVSCode(metrics: Bool) {
        guard !managedHooksDisabled else { report(.unavailable); return }
        guard !vscode.isWorking else { report(.unavailable); return }
        guard install(.vscode) else { return }
        vscode.configure(metrics: metrics)
    }

    func disableVSCodeMetrics() {
        guard !vscode.isWorking else { report(.unavailable); return }
        vscode.remove(hooks: false)
        tokenLedger.remove(.vscodeLocal)
        tokenLedger.remove(.vscodeCopilot)
        liveUsageDetail = nil
        updateTokenMetrics(now: Date())
        history.setAvailableSources(historySources)
    }

    @discardableResult
    func install(_ client: Client) -> Bool {
        guard !managedHooksDisabled else {
            report(.unavailable)
            connectionSetupErrors[client] = "Client connections are turned off by your organization."
            return false
        }
        do {
            let helper = bundleURL.appendingPathComponent("Contents/Helpers/TokenotchHook")
            let extensionData = client == .cli
                ? try Data(contentsOf: bundleURL.appendingPathComponent("Contents/Resources/CopilotUsage/extension.mjs"))
                : nil
            try installation.install(client, bundledHelper: helper, usageExtension: extensionData)
            registeredClients.insert(client)
            if client == .cli {
                let failure = root.appendingPathComponent("bridge-failure")
                if try PrivateFiles.read(failure, limit: 128) == Data("metric-upgrade".utf8) {
                    guard unlink(failure.path) == 0 else { throw TokenotchError.storage }
                    bridgeStatus = "Token integration updated; reload extensions or restart CLI sessions"
                }
            }
            connection[client] = client == .cli ? "Installed; reload extensions or restart each CLI session" : "File ready; configure VS Code hook location"
            history.setAvailableSources(historySources)
            timeline.setAvailable(timelineClients)
            errorMessage = nil
            installedClients.insert(client)
            connectionSetupErrors[client] = nil
            return true
        } catch let error as TokenotchError { report(error) }
        catch { report(.storage) }
        connectionSetupErrors[client] = errorMessage
        installedClients.remove(client)
        return false
    }

    func uninstall(_ client: Client) {
        guard client != .vscode || !vscode.isWorking else { report(.unavailable); return }
        installedClients.remove(client)
        timeline.setAvailable(timelineClients.subtracting([client]))
        activity.remove(client)
        lifecycleActivity.remove(client)
        attention.remove(client)
        if selectedSession?.source == client { selectedSession = nil }
        if client == .cli {
            lastCLIUsageEvent = nil
            liveUsageDetail = nil
            selectedSession = nil
            tokenLedger.remove(.cli); updateTokenMetrics(now: Date())
            sessionInsights = SessionInsights(); insights = []; contextWarnings = ContextWarningPolicy()
        } else {
            vscode.remove(hooks: true)
            tokenLedger.remove(.vscodeLocal)
            tokenLedger.remove(.vscodeCopilot)
            updateTokenMetrics(now: Date())
        }
        sessions.removeAll { $0.source == client }
        lastEvent.removeValue(forKey: client)
        lastActivityEvent.removeValue(forKey: client)
        connection[client] = "Removing integration"
        do {
            try installation.uninstall(client)
            connection[client] = "Not installed"
            connectionSetupErrors[client] = nil
        } catch let error as TokenotchError {
            connection[client] = "Removal needs attention"
            report(error)
        } catch {
            connection[client] = "Removal needs attention"
            report(.storage)
        }
        do {
            if try PrivateFiles.read(root.appendingPathComponent("\(client.rawValue).registration")) == nil {
                registeredClients.remove(client)
            }
        } catch { report(.unsafePath) }
        history.setAvailableSources(historySources)
    }

    var vscodeSetting: String {
        """
        "chat.hookFilesLocations": {
          "~/.tokenotch/vscode-hooks": true
        }
        """
    }

    func clearLocalHistory() {
        guard attention.clear() else { return }
        liveUsageDetail = nil
        selectedSession = nil
        activity = ActivityState()
        lifecycleActivity = ActivityState()
        tokenLedger = TokenLedger()
        vscode.clearObservations()
        sessionInsights = SessionInsights(); insights = []; contextWarnings = ContextWarningPolicy()
        updateTokenMetrics(now: Date())
        sessions = []
        lastEvent = [:]
        lastActivityEvent = [:]
        lastCLIUsageEvent = nil
        ledger = NotificationLedger()
        startedAt = Date()
        do {
            try PrivateFiles.write(try JSONEncoder().encode(ledger), to: root.appendingPathComponent("notifications.json"))
            let failure = root.appendingPathComponent("bridge-failure")
            if try PrivateFiles.read(failure) != nil, unlink(failure.path) != 0 { throw TokenotchError.storage }
            storageReady = true
            bridgeStatus = managedHooksDisabled ? "Disabled by managed policy" : "Re-test integrations to verify coverage"
            errorMessage = nil
        } catch { storageReady = false; report(.storage) }
    }

    func showTimeline(source: Client, hash: String) {
        settingsTab = .sessions
        timeline.openSession(source: source, hash: hash)
    }

    func currentTarget(_ target: SessionDetailTarget) -> SessionDetailTarget {
        var result = target
        result.liveHash = sessions.first {
            $0.source == target.source &&
                attention.state.sessionID(source: $0.source, hash: $0.key) == target.noticeSessionID
        }?.key
        return result
    }

    private var timelineClients: Set<Client> {
        guard !managedHooksDisabled, bridgeStatus != "Not started",
              !bridgeStatus.hasPrefix("Unavailable"), !bridgeStatus.hasPrefix("Disabled") else { return [] }
        do {
            return Set(try Client.allCases.filter {
                try PrivateFiles.read(root.appendingPathComponent("\($0.rawValue).registration"), limit: 128) != nil
            })
        } catch { report(.unsafePath); return [] }
    }

    func requestNotifications() {
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                options.notifications.enabled = allowed
                refreshPermission()
            } catch { notificationStatus = "Permission request failed"; report(.unavailable) }
        }
    }

    func refreshPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: notificationStatus = "Allowed"
            case .denied: notificationStatus = "Denied in macOS System Settings"
            case .notDetermined: notificationStatus = "Not requested"
            @unknown default: notificationStatus = "Unknown"
            }
        }
    }

    func snooze(minutes: Int) {
        options.notifications.snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60)
    }

    func testNotification() {
        deliver(Notice(id: UUID().uuidString, category: .stopped, title: "Tokenotch test notification",
                       body: "Your current delivery, snooze and quiet-hour settings apply."))
    }

    func deliver(_ notice: Notice) {
        guard storageReady else { report(.storage); return }
        let decision = ledger.evaluate(notice, preferences: options.notifications, now: Date(), managedMute: managedMute)
        do {
            try PrivateFiles.write(try JSONEncoder().encode(ledger), to: root.appendingPathComponent("notifications.json"))
        } catch { storageReady = false; report(.storage); return }
        guard let decision else { return }
        if decision.expand { expandNotch?() }
        if decision.sound {
            notificationSoundError = playNotificationSound() ? nil : "Sound playback failed"
            if notificationSoundError != nil { log.error("Notification sound playback failed.") }
        }
        if decision.desktop {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            // Audio is delivered independently, once per notice rather than per display.
            content.sound = nil
            if let target = notice.target { content.userInfo = target.userInfo }
            else if let source = notice.source { content.userInfo = ["source": source.rawValue] }
            Task {
                guard await desktopNotificationsAllowed() else {
                    notificationStatus = "Desktop delivery suppressed: permission unavailable"
                    return
                }
                guard options.notifications.desktop,
                      options.notifications.allows(notice.category, now: Date(), managedMute: managedMute) else { return }
                do {
                    try await postNotification(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
                } catch { notificationStatus = "Desktop delivery failed"; log.error("Notification delivery failed.") }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            self.routeNotification(userInfo)
            completionHandler()
        }
    }

    func routeNotification(_ userInfo: [AnyHashable: Any]) {
        liveUsageDetail = nil
        selectedSession = nil
        showLiveSessions = false
        settingsTab = .usage
        usageNavigation = UUID()
        if let target = NoticeTarget(userInfo: userInfo),
           attention.state.notices.contains(where: { $0.source == target.source && $0.sessionID == target.sessionID }) {
            selectedSession = currentTarget(SessionDetailTarget(source: target.source,
                noticeSessionID: target.sessionID, liveHash: nil))
            if !attention.state.notices.contains(where: {
                $0.source == target.source && $0.sessionID == target.sessionID && $0.id == target.noticeID
            }) {
                notificationNavigationMessage = "The original notice is no longer retained. Showing this session's current notices."
            }
        } else {
            notificationNavigationMessage = "These notification details are no longer available. Showing retained session notices."
        }
        openNotificationDetails?()
    }

    func openClient(_ client: Client) {
        let bundleID = client == .vscode && defaults.string(forKey: "vscodeURIScheme") == "vscode-insiders"
            ? "com.microsoft.VSCodeInsiders" : client.bundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            report(.unavailable); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in self.report(.unavailable) } }
        }
    }

    func openUsage() { openURL("https://github.com/settings/copilot") }
    func openStatus() { openURL("https://www.githubstatus.com/") }
    func openPricing() { openURL(NotchLayout.modelPricingURL) }
    private func openURL(_ value: String) {
        guard let url = URL(string: value), NSWorkspace.shared.open(url) else { report(.unavailable); return }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginItemStatus()
        } catch { report(.unavailable) }
    }

    func refreshLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginItemStatus = "Enabled"
        case .requiresApproval: loginItemStatus = "Approval required in System Settings"
        case .notRegistered: loginItemStatus = "Off"
        case .notFound: loginItemStatus = "Unavailable. Move Tokenotch to Applications and reopen it."
        @unknown default: loginItemStatus = "Status unavailable"
        }
    }

    func refreshConnectionInstallations() {
        for client in Client.allCases {
            do {
                let registered = try PrivateFiles.read(root.appendingPathComponent("\(client.rawValue).registration")) != nil
                if registered { registeredClients.insert(client) } else { registeredClients.remove(client) }
                let expectedExtension = client == .cli && registered
                    ? try Data(contentsOf: bundleURL.appendingPathComponent("Contents/Resources/CopilotUsage/extension.mjs"))
                    : nil
                if try installation.isInstalled(client, expectedUsageExtension: expectedExtension) {
                    installedClients.insert(client)
                    connectionSetupErrors[client] = nil
                } else {
                    installedClients.remove(client)
                    if registered {
                        connectionSetupErrors[client] = client == .cli
                            ? "CLI setup files are missing or out of date. Repair setup, then reload extensions or restart each CLI session."
                            : "Setup files are missing. Review or repair this connection."
                    }
                }
                if !registered {
                    connection[client] = "Not installed"
                } else if lastEvent[client] == nil {
                    connection[client] = client == .cli
                        ? "Installed; reload extensions or restart each CLI session"
                        : "Installed; awaiting client events"
                }
            } catch {
                installedClients.remove(client)
                let failure = (error as? TokenotchError) ?? .unsafePath
                connectionSetupErrors[client] = failure.rawValue
                report(failure)
            }
        }
    }

    var setupStep: OnboardingStep { onboarding.step }

    func isClientConfigured(_ client: Client) -> Bool {
        !managedHooksDisabled && installedClients.contains(client)
            && (client == .cli || (vscode.activityConfigured && !vscode.removingActivity))
    }

    var hasOnboardingConnection: Bool { onboarding.clients.contains(where: isClientConfigured) }
    var canAdvanceOnboarding: Bool { setupStep != .connections || hasOnboardingConnection }

    func resumeOnboarding() {
        refreshConnectionInstallations()
        if onboardingComplete && setupStep == .complete { onboarding.step = .welcome }
        if onboardingComplete && onboardingDestination == nil { onboardingDestination = settingsTab }
        onboardingMessage = nil
        onboarding.save(to: defaults)
        showOnboarding = true
    }

    func reviewOnboarding() {
        if onboardingComplete {
            onboarding.step = .welcome
            onboardingDestination = settingsTab
        }
        resumeOnboarding()
    }

    func selectOnboardingClient(_ client: Client) {
        onboarding.clients.insert(client)
        onboarding.activeClient = client
        onboardingMessage = nil
        onboarding.save(to: defaults)
    }

    func pauseOnboarding() {
        onboarding.save(to: defaults)
        showOnboarding = false
    }

    func backOnboarding() {
        switch setupStep {
        case .connections: onboarding.step = .welcome
        case .preferences: onboarding.step = .connections
        case .welcome, .complete: return
        }
        onboardingMessage = nil
        onboarding.save(to: defaults)
    }

    func advanceOnboarding() {
        switch setupStep {
        case .welcome: onboarding.step = .connections
        case .connections:
            refreshConnectionInstallations()
            guard requireOnboardingConnection() else { return }
            onboarding.step = .preferences
        case .preferences:
            finishOnboarding()
            return
        case .complete:
            dismissCompletedOnboarding()
            return
        }
        onboardingMessage = nil
        onboarding.save(to: defaults)
    }

    private func requireOnboardingConnection() -> Bool {
        guard hasOnboardingConnection else {
            onboardingMessage = managedHooksDisabled
                ? "Client connections are turned off by your organization. You can pause setup and contact your administrator."
                : "Configure at least one client you chose before continuing. You can try another client or pause setup."
            return false
        }
        return true
    }

    @discardableResult
    func finishOnboarding() -> Bool {
        if setupStep == .complete && onboardingComplete { return true }
        guard setupStep == .preferences else {
            onboardingMessage = "Continue through the setup steps before finishing."
            return false
        }
        refreshConnectionInstallations()
        guard requireOnboardingConnection() else { return false }
        defaults.set(true, forKey: "onboardingComplete.v1")
        onboardingComplete = true
        onboarding.step = .complete
        onboardingMessage = nil
        onboarding.save(to: defaults)
        return true
    }

    func dismissCompletedOnboarding() {
        guard onboardingComplete && setupStep == .complete else { pauseOnboarding(); return }
        settingsTab = onboardingDestination ?? .usage
        onboardingDestination = nil
        showOnboarding = false
    }

    func resetUnreadablePreferences() {
        guard preferencesUnreadable else { return }
        if let data = defaults.data(forKey: "preferences.v1") {
            defaults.set(data, forKey: "preferences.recovery")
        }
        defaults.removeObject(forKey: "preferences.v1")
        preferencesUnreadable = false
        options = TokenotchOptions()
        errorMessage = "Preferences reset. Restart Tokenotch to retry private storage. The previous settings were kept for recovery."
    }

    private static func detectCLI() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot",
                "\(home)/.local/bin/copilot", "\(home)/.copilot/bin/copilot"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the official GitHub Copilot CLI executable."
        if panel.runModal() == .OK, let url = panel.url {
            disconnectAccount()
            cliExecutable = url.path
        }
    }

    func signInAccount() {
        guard !managedAccountDisabled else { accountStatus = "Account connection disabled by managed policy"; return }
        disconnectAccount()
        guard !cliExecutable.isEmpty else { accountStatus = CopilotConnectionError.missingCLI.rawValue; return }
        let generation = accountGeneration
        let runtime = CopilotRuntime(executable: URL(fileURLWithPath: cliExecutable),
                                     home: root.appendingPathComponent("copilot-account"))
        accountRuntime = runtime
        accountBusy = true
        accountStatus = "Complete GitHub sign-in in your browser. This can take up to three minutes."
        accountTask = Task {
            do {
                try await Task.detached { try runtime.signIn() }.value
                guard accountGeneration == generation else { return }
                defaults.set(true, forKey: "accountConnectionEnabled")
                accountTask = nil
                accountRuntime = nil
                accountBusy = false
                nextAccountCheck = .distantPast
                refreshAccount()
            } catch {
                guard accountGeneration == generation else { return }
                accountStatus = (error as? CopilotConnectionError)?.rawValue ?? CopilotConnectionError.loginFailed.rawValue
                accountBusy = false
                accountTask = nil
                accountRuntime = nil
            }
        }
    }

    func disconnectAccount() {
        accountGeneration = UUID()
        accountTask?.cancel()
        accountRuntime?.cancel()
        accountTask = nil
        accountRuntime = nil
        defaults.set(false, forKey: "accountConnectionEnabled")
        accountSnapshot = nil
        accountStale = false
        accountBusy = false
        accountStatus = "Disconnected from account metrics"
        nextAccountCheck = .distantPast
    }

    func refreshAccount() {
        guard defaults.bool(forKey: "accountConnectionEnabled"), !managedAccountDisabled,
              accountTask == nil, Date() >= nextAccountCheck else { return }
        nextAccountCheck = Date().addingTimeInterval(60)
        let generation = accountGeneration
        let runtime = CopilotRuntime(executable: URL(fileURLWithPath: cliExecutable),
                                     home: root.appendingPathComponent("copilot-account"))
        accountRuntime = runtime
        accountBusy = true
        accountStatus = "Refreshing Copilot account quota…"
        accountTask = Task {
            do {
                let snapshot = try await Task.detached { try runtime.snapshot() }.value
                guard accountGeneration == generation else { return }
                accountSnapshot = snapshot
                accountStale = false
                accountStatus = "Connected · account quota refreshes every 60 seconds"
            } catch {
                guard accountGeneration == generation else { return }
                accountStale = accountSnapshot != nil
                accountStatus = (error as? CopilotConnectionError)?.rawValue ?? CopilotConnectionError.failed.rawValue
                if error as? CopilotConnectionError == .rateLimited {
                    nextAccountCheck = Date().addingTimeInterval(300)
                }
            }
            guard accountGeneration == generation else { return }
            accountBusy = false
            accountTask = nil
            accountRuntime = nil
        }
    }

    func refreshHealth() {
        guard options.healthEnabled, !managedHealthDisabled, healthTask == nil, Date() >= nextHealthCheck else { return }
        nextHealthCheck = Date().addingTimeInterval(300)
        healthTask = Task {
            defer { healthTask = nil }
            do {
                let url = URL(string: "https://www.githubstatus.com/api/v2/summary.json")!
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                request.setValue("Tokenotch/\(TokenotchProduct.version)", forHTTPHeaderField: "User-Agent")
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw TokenotchError.unavailable }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 262_144 else { throw TokenotchError.invalidEvent }
                    data.append(byte)
                }
                try Task.checkCancellation()
                guard options.healthEnabled, !managedHealthDisabled else { return }
                let incidents = try HealthParser.parse(data)
                healthIncident = incidents.contains { !$0.resolved }
                health = healthIncident ? "GitHub reports a Copilot incident" : "No Copilot incident reported"
                healthObservedAt = Date()
                for notice in healthLedger.observe(incidents) { deliver(notice) }
            } catch is CancellationError {
                // User disabled the feature or the app is terminating.
            } catch {
                guard options.healthEnabled else { return }
                health = "Status feed unavailable; cause unknown (not proof of an outage)"
                healthIncident = false
                log.error("Status feed unavailable.")
            }
        }
    }

    var diagnostics: String {
        let clients = Client.allCases.map { "\($0.rawValue): \(connection[$0] ?? "Not installed")" }.joined(separator: "\n")
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        let runtimeVersion = accountSnapshot.flatMap { ReleaseVersion($0.runtimeVersion) }
            .map { $0.components.map(String.init).joined(separator: ".") } ?? "not observed or unrecognized"
        return """
        Tokenotch \(AppVersion.short) (\(AppVersion.build)) / lifecycle schema 1, live activity and compaction schema 2
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(architecture)
        Runtime protocol: 2 required
        Account runtime version (numeric): \(runtimeVersion)
        Usage: \(accountSnapshot == nil ? "not connected" : (accountStale ? "stale runtime quota" : "runtime quota"))
        Selected-source token samples: \(tokenTotals == nil ? "not observed" : "retained observations")
        VS Code metrics: \(vscode.enabled ? (vscode.ready ? "receiver ready" : "receiver unavailable") : "off")
        VS Code telemetry rejected: \(vscode.rejected)
        VS Code telemetry requests rejected: \(vscode.failedRequests)
        Persistent history: \(history.error != nil ? "unavailable" : (history.recording ? "recording locally" : "not recording"))
        Session timelines: \(timeline.error != nil ? "unavailable" : (timeline.recording ? "recording locally" : "not recording"))
        Session notices: \(attention.error != nil ? "saving unavailable" : (attention.saving ? "saved locally" : "memory only"))
        Identity: runtime account shown only in app, billing identity not inferred
        Bridge: \(bridgeStatus)
        \(clients)
        Service: \(health)
        Notifications: \(notificationStatus)
        Notification sound: \(notificationSoundError ?? "No playback error")
        Managed notifications disabled: \(managedMute)
        Recent local error: \(errorMessage == nil ? "none" : "present; see Settings")
        No account IDs, session IDs, paths, prompts, credentials or raw responses included.
        """
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    private func report(_ error: TokenotchError) {
        errorMessage = error.rawValue
        log.error("\(error.rawValue, privacy: .public)")
    }

    private var cliHistoryAvailable: Bool {
        guard !managedHooksDisabled else { return false }
        do { return try PrivateFiles.read(root.appendingPathComponent("cli.registration"), limit: 128) != nil }
        catch { report(.unsafePath); return false }
    }

    private var historySources: Set<UsageSource> {
        guard !managedHooksDisabled else { return [] }
        var sources: Set<UsageSource> = cliHistoryAvailable ? [.cli] : []
        if vscode.enabled && vscode.ready { sources.formUnion([.vscodeLocal, .vscodeCopilot]) }
        return sources
    }
}
