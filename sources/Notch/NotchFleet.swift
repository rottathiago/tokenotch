import AppKit
import Combine
import TokenotchCore
import SwiftUI

@MainActor
final class NotchFleet {
    private final class CardState {
        let source: NotchPanel
        var panel: NotchPanel?
        var host: ShapeHostingView<CopilotSummaryView>?
        var placement: NotchCardPlacement?
        var interaction = NotchInteraction()
        var exposure = NotchInteraction.NoticeExposure()
        var modelsExpanded = false
        var provider = UsageProvider.copilot

        init(source: NotchPanel) { self.source = source }
    }

    private let model: TokenotchModel
    private let openSettings: () -> Void
    private let isFullScreen: (NSScreen) -> Bool
    private let pointerLocation: () -> CGPoint
    private let currentDate: () -> Date
    private let screens: () -> [NSScreen]
    private var panels: [NotchPanel] = []
    private var panelScreens: [NotchPanel: NSScreen] = [:]
    private var cards: [NotchPanel: CardState] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellables = Set<AnyCancellable>()
    private var pointerTimer: Timer?
    private var visibilityTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var isDragging = false
    private var started = false
    private var refreshScheduled = false

    init(model: TokenotchModel, openSettings: @escaping () -> Void,
         isFullScreen: @escaping (NSScreen) -> Bool = { FullScreenDetector.isFullScreenAppVisible(on: $0) },
         pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation },
         now: @escaping () -> Date = Date.init,
         screens: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.model = model
        self.openSettings = openSettings
        self.isFullScreen = isFullScreen
        self.pointerLocation = pointerLocation
        currentDate = now
        self.screens = screens
    }

    func start() {
        guard !started else { return }
        started = true
        model.$options.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.started else { return }
                self.rebuild()
            }
        }.store(in: &cancellables)
        model.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh()
        }.store(in: &cancellables)
        model.history.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh()
        }.store(in: &cancellables)
        model.timeline.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh()
        }.store(in: &cancellables)
        model.attention.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh()
        }.store(in: &cancellables)
        model.claude.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh()
        }.store(in: &cancellables)
        model.claude.$enabled.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { if let self, self.started { self.rebuild() } }
        }.store(in: &cancellables)
        model.history.$knownProviders.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { if let self, self.started { self.rebuild() } }
        }.store(in: &cancellables)
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification)
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePointer() }
        }
        // Space/activation notifications can arrive before the full-screen animation ends.
        let visibilityTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateVisibility() }
        }
        RunLoop.main.add(visibilityTimer, forMode: .common)
        self.visibilityTimer = visibilityTimer
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handlePointerEvent(event)
        }) { mouseMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handlePointerEvent(event)
            return event
        }) { mouseMonitors.append(monitor) }
        rebuild()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started else { return }
                if name == NSWorkspace.didActivateApplicationNotification,
                   self.model.options.allDisplays || self.model.options.displayID != nil {
                    self.updateVisibility()
                } else {
                    self.rebuild()
                }
            }
        }
        observers.append((center, token))
    }

    func stop() {
        started = false
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        cancellables.removeAll()
        pointerTimer?.invalidate()
        pointerTimer = nil
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        dismiss(acknowledging: false)
        panels.forEach { $0.close() }
        panels.removeAll()
        panelScreens.removeAll()
        cards.removeAll()
        isDragging = false
    }

    private var edge: NotchEdge { NotchEdge(rawValue: model.options.edge) ?? .right }
    private var scale: CGFloat { NotchLayout.scale(model.options.scale) }

    private func rebuild() {
        guard !isDragging else { return }
        dismiss(acknowledging: false)
        panels.forEach { $0.close() }
        panels.removeAll()
        panelScreens.removeAll()
        cards.removeAll()
        guard model.options.showNotch, !model.notchProviders.isEmpty else { return }
        let availableScreens = self.screens()
        let screens: [NSScreen]
        if model.options.allDisplays { screens = availableScreens }
        else {
            let preference = model.options.displayID.map(DisplayPreference.display) ?? .followActiveWindow
            screens = NotchGeometry.preferredScreen(from: availableScreens, preference: preference).map { [$0] } ?? []
        }
        let edge = self.edge
        let scale = self.scale
        let size = NotchLayout.size(edge: edge, scale: scale, providerCount: model.notchProviders.count)
        for screen in screens {
            let offset = model.options.offsets[edge.rawValue] ?? 0
            var frame = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: edge,
                                                 alongOffset: offset.isFinite ? offset : 0)
            if edge == .top, let notch = screen.hardwareNotch,
               abs(frame.midX - screen.frame.midX) < notch.width / 2 + size.width / 2 {
                frame = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: edge,
                                                 alongOffset: notch.width / 2 + size.width / 2 + 8)
            }
            let panel = NotchPanel(contentRect: frame)
            let host = ShapeHostingView(rootView: LiveNotchBadge(model: model, edge: edge, scale: scale) { [weak self, weak panel] provider in
                if let panel { self?.show(from: panel, provider: provider) }
            })
            panel.contentView = host
            setCollapsed(model.options.autoHideNotch, for: panel)
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.onClick = { [weak self, weak panel] _ in
                if let panel { self?.show(from: panel) }
            }
            panel.onDrag = { [weak panel] dx, dy in
                guard let panel else { return }
                let current = edge.isVertical
                    ? screen.frame.midY - panel.frame.midY
                    : panel.frame.midX - screen.frame.midX
                panel.setFrame(NotchGeometry.panelFrame(for: screen, panelSize: size, edge: edge,
                    alongOffset: current + (edge.isVertical ? dy : dx)), display: true)
            }
            panel.onDragStart = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.isDragging = true
                self.dismiss()
                self.setCollapsed(false, for: panel)
            }
            panel.onDragEnd = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.isDragging = false
                self.cards[panel]?.interaction = NotchInteraction()
                self.setCollapsed(self.model.options.autoHideNotch, for: panel)
                self.model.options.offsets[edge.rawValue] = edge.isVertical
                    ? screen.frame.midY - panel.frame.midY : panel.frame.midX - screen.frame.midX
            }
            panels.append(panel)
            panelScreens[panel] = screen
            cards[panel] = CardState(source: panel)
        }
        updateVisibility()
        updatePointer()
    }

    private func updateVisibility() {
        guard started else { return }
        for panel in panels {
            guard let screen = panelScreens[panel] else { continue }
            let shouldHide = !model.options.showNotch ||
                (model.options.foldsForFullScreen && isFullScreen(screen))
            if shouldHide && panel.isVisible {
                if let card = cards[panel] {
                    dismiss(card)
                    card.interaction = NotchInteraction()
                }
                panel.orderOut(nil)
            } else if !shouldHide && !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
    }

    func reveal(allowSettings: Bool = true, keyboard: Bool = false) {
        updateVisibility()
        let visible = panels.filter(\.isVisible)
        if !allowSettings {
            guard model.notchProviders.contains(.copilot) else { return }
            for panel in visible {
                show(from: panel, pinned: false, minimumDuration: 3, origin: .automatic)
            }
            updatePointer()
        } else if let panel = visible.first {
            show(from: panel)
            if keyboard { cards[panel]?.panel?.makeKey() }
        } else if allowSettings {
            openSettings()
        }
    }

    func handlePointerEvent(_ event: NSEvent) {
        guard started, !isDragging else { return }
        if event.type != .mouseMoved {
            let pointer = pointerLocation()
            let overNotch = panels.contains { contains(pointer, in: $0) }
            let overCard = cards.values.contains { contains(pointer, in: $0.panel) }
            if !overNotch && !overCard { dismiss() }
        }
        updatePointer()
    }

    private func contains(_ point: CGPoint, in panel: NotchPanel?) -> Bool {
        guard let panel, panel.isVisible, let host = panel.contentView as? ShapeHitTesting else { return false }
        return host.contains(screenPoint: point)
    }

    private func updatePointer() {
        guard started, !isDragging else { return }
        let now = currentDate()
        let pointer = pointerLocation()
        for (index, panel) in panels.enumerated() {
            guard let card = cards[panel] else { continue }
            let inside = contains(pointer, in: panel)
            panel.ignoresMouseEvents = !inside
            let overCard = contains(pointer, in: card.panel)
            card.panel?.ignoresMouseEvents = !overCard
            let overBridge = card.placement?.hoverBridge.contains(pointer) ?? false
            if inside, card.panel != nil, !card.interaction.isPinned {
                let provider = provider(at: pointer, in: panel)
                if card.provider != provider { show(from: panel, provider: provider, pinned: false, origin: .hover) }
            }
            switch card.interaction.update(hovered: inside ? index : nil,
                                           overDetail: overCard || overBridge, now: now) {
            case .reveal(let index):
                if !cards.values.contains(where: { $0 !== card && $0.interaction.isPinned }) {
                    show(from: panels[index], pinned: false, origin: .hover)
                }
            case .dismiss: dismiss(card)
            case nil: break
            }
            let requests = Set((card.host?.rootView.presentation.sessionRows ?? []).compactMap { row in
                row.notice.flatMap { $0.kind.isRequest && $0.disposition == .pending ? $0.id : nil }
            })
            let update = card.exposure.tick(now: now,
                windowVisible: card.panel?.isVisible == true && (card.panel?.alphaValue ?? 0) >= 0.95,
                engaged: inside || overCard, pendingRequests: requests)
            if !update.viewed.isEmpty { model.attention.markViewed(update.viewed, now: now, holdUntilClose: true) }
            if !update.dismiss.isEmpty { model.attention.dismissRequests(update.dismiss, now: now) }
        }
    }

    private func provider(at point: CGPoint, in panel: NotchPanel) -> UsageProvider {
        let providers = model.notchProviders
        guard providers.count > 1 else { return providers.first ?? .copilot }
        let coordinate = edge.isVertical ? panel.frame.maxY - point.y : point.x - panel.frame.minX
        let host = panel.contentView as? ShapeHostingView<LiveNotchBadge>
        if host?.rootView.isCollapsed == true {
            let bounds = CGRect(origin: .zero, size: panel.frame.size)
            let rect = NotchLayout.badgeRect(in: bounds, edge: edge, scale: scale, collapsed: true,
                                              providerCount: providers.count)
            let start = edge.isVertical ? rect.minY : rect.minX
            let length = edge.isVertical ? rect.height : rect.width
            return providers[min(providers.count - 1, max(0, Int((coordinate - start) / length * CGFloat(providers.count))))]
        }
        let first = NotchLayout.ringCenter(in: panel.frame.size, edge: edge, scale: scale)
        let origin = edge.isVertical ? first.y : first.x
        let index = Int(((coordinate - origin) / (NotchLayout.cellStride(edge: edge) * scale)).rounded())
        return providers[min(providers.count - 1, max(0, index))]
    }

    private func show(from panel: NotchPanel, provider requestedProvider: UsageProvider? = nil,
                      pinned: Bool = true, minimumDuration: TimeInterval = 0,
                      origin: NotchInteraction.NoticeExposure.Origin = .deliberate) {
        guard panel.isVisible, let card = cards[panel] else { return }
        if origin != .automatic { dismiss(except: card) }
        let selected = requestedProvider ?? (origin == .automatic ? .copilot : provider(at: pointerLocation(), in: panel))
        if card.provider != selected, card.panel != nil { dismiss(card) }
        card.provider = selected
        if model.history.selectedProvider != selected { model.history.selectedProvider = selected }
        let data = NotchPresentation(model: model, provider: selected)
        card.exposure.open(origin: origin, initial: Set(data.sessionRows.compactMap { $0.notice?.id }),
                           keepingVisibility: card.panel != nil)
        setCollapsed(false, for: panel)
        let wasVisible = card.panel?.isVisible == true
        refreshCard(card)
        guard let detailPanel = card.panel else { return }
        card.interaction.show(pinned: pinned || (wasVisible && card.interaction.isPinned),
                              now: currentDate(), minimumDuration: minimumDuration,
                              sourceIndex: panels.firstIndex(of: panel))
        let animate = !wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        detailPanel.alphaValue = animate ? 0 : 1
        detailPanel.orderFrontRegardless()
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                detailPanel.animator().alphaValue = 1
            }
        }
        if origin != .automatic { updatePointer() }
    }

    private func dismiss(acknowledging: Bool = true, except retained: CardState? = nil) {
        for card in cards.values where card !== retained {
            dismiss(card, acknowledging: acknowledging)
        }
    }

    private func dismiss(_ card: CardState, acknowledging: Bool = true) {
        setCollapsed(model.options.autoHideNotch, for: card.source)
        card.panel?.close()
        card.panel = nil
        card.host = nil
        card.placement = nil
        card.modelsExpanded = false
        let looked = card.exposure.close()
        if acknowledging && !looked.isEmpty { model.attention.acknowledge(looked, now: currentDate()) }
        if cards.values.allSatisfy({ $0.panel == nil }) { model.attention.closeCard() }
        card.interaction.dismiss()
    }

    private func setCollapsed(_ collapsed: Bool, for panel: NotchPanel) {
        guard let host = panel.contentView as? ShapeHostingView<LiveNotchBadge> else { return }
        host.rootView.isCollapsed = collapsed
        let edge = host.rootView.edge
        let scale = host.rootView.scale
        let providerCount = model.notchProviders.count
        host.hitPath = { bounds in
            let rect = NotchLayout.badgeRect(in: bounds, edge: edge, scale: scale, collapsed: collapsed,
                                              providerCount: providerCount)
            return SideNotchShape(edge: edge, curlRadius: NotchLayout.curlRadius * scale,
                                  cornerRadius: NotchLayout.cornerRadius * scale).path(in: rect)
        }
    }

    private func scheduleRefresh() {
        guard started, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.started {
                for card in self.cards.values where card.panel != nil { self.refreshCard(card) }
            }
        }
    }

    private func refreshCard(_ card: CardState) {
        let source = card.source
        let provider = card.provider
        guard let screen = panelScreens[source] else { return }
        var data = NotchPresentation(model: model, provider: card.provider)
        if let previousRange = card.host?.rootView.presentation.range, previousRange != data.range {
            card.modelsExpanded = false
        }
        data.modelsExpanded = card.modelsExpanded
        let width = NotchCardPlacement.bodyWidth(notch: source.frame, edge: edge,
                                                 visibleFrame: screen.visibleFrame, scale: scale)
        let content = NSHostingView(rootView: CopilotSummaryContent(presentation: data, scale: scale,
                                                                   openClient: model.openClient,
                                                                   openHistory: {})
            .frame(width: width - 2 * NotchLayout.cardPadding * scale))
        let height = content.fittingSize.height + NotchLayout.cardChrome(scale: scale)
        let index = model.notchProviders.firstIndex(of: card.provider) ?? 0
        let localRing = NotchLayout.ringCenter(in: source.frame.size, edge: edge, scale: scale, index: index)
        let center = CGPoint(x: source.frame.minX + localRing.x, y: source.frame.maxY - localRing.y)
        let placement = NotchCardPlacement(notch: source.frame, ringCenter: center, edge: edge,
                                           visibleFrame: screen.visibleFrame, contentHeight: height,
                                           scale: scale)
        let root = CopilotSummaryView(presentation: data, placement: placement, openClient: model.openClient,
                                     openUsage: { [weak self] in
            self?.model.history.selectedProvider = provider
            self?.showUsage(sessions: false)
        }, openSettings: { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.openSettings()
        }, openHistory: { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.model.history.selectedProvider = provider
            self.model.history.navigate(range: data.range, anchor: data.anchor ?? data.now)
            self.model.settingsTab = .history
            self.openSettings()
        }, selectRange: { [weak self, weak card] range in
            guard let self, let card, range == .today || range == .week,
                  range != self.model.history.notchRange else { return }
            card.modelsExpanded = false
            self.model.history.selectNotchRange(range)
        }, selectSource: { [weak self, weak card] source in
            guard let self, let card else { return }
            card.modelsExpanded = false
            self.model.history.selectedSource = source
        }, openModel: { [weak self] selected in
            guard let self else { return }
            self.model.history.selectedProvider = provider
            if data.usageSource == .saved {
                self.model.history.navigate(range: data.range, anchor: data.anchor ?? data.now, model: selected)
                self.showSettings(tab: .history)
            } else if data.usageSource == .live {
                self.model.selectedSession = nil
                self.model.showLiveSessions = false
                self.model.usageNavigation = UUID()
                self.model.liveUsageDetail = LiveUsageDetail(models: data.models, tokens: data.tokens,
                    selectedModel: selected, partial: data.tokensPartial, observedAt: data.now,
                    zone: TimeZone.current.identifier)
                self.showSettings(tab: .usage)
            }
        }, openAttention: { [weak self] session in
            guard let self else { return }
            if let session {
                self.model.liveUsageDetail = nil
                self.model.selectedSession = SessionDetailTarget(source: .cli,
                    noticeSessionID: self.model.attention.state.sessionID(source: .cli, hash: session),
                    liveHash: session)
                self.model.showLiveSessions = false
                self.model.usageNavigation = UUID()
                self.showSettings(tab: .usage)
            } else {
                self.dismiss()
                self.model.openStatus()
            }
        }, openConnections: { [weak self] in
            self?.showSettings(tab: .connections)
        }, openActivity: { [weak self] in
            self?.model.history.selectedProvider = provider
            self?.showUsage(sessions: true)
        }, toggleModels: { [weak self, weak card] in
            guard let self, let card, data.canExpandModels else { return }
            card.modelsExpanded.toggle()
            self.refreshCard(card)
        }, openSession: { [weak self] target, notice in
            guard let self else { return }
            if let notice { self.model.attention.markViewed([notice]) }
            self.model.history.selectedProvider = provider
            self.model.liveUsageDetail = nil
            self.model.selectedSession = target
            self.model.usageNavigation = UUID()
            self.showSettings(tab: .usage)
        }, dismissRequest: { [weak self] id in
            guard let self else { return }
            self.model.attention.dismissRequests([id], now: self.currentDate())
        }, noticeVisibility: { [weak card, generation = card.exposure.generation] id, visible in
            card?.exposure.visibility(id, visible: visible, generation: generation)
        }, openPricing: { [weak self] in
            self?.model.openPricing(provider: provider)
        })
        if let host = card.host, let panel = card.panel {
            host.rootView = root
            host.hitPath = { placement.shape.path(in: $0) }
            panel.setFrame(placement.frame, display: true)
            panel.invalidateShadow()
        } else {
            let panel = NotchPanel(contentRect: placement.frame)
            panel.acceptsKeyboardFocus = true
            let host = ShapeHostingView(rootView: root)
            host.hitPath = { placement.shape.path(in: $0) }
            panel.contentView = host
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.hasShadow = true
            card.host = host
            card.panel = panel
        }
        card.placement = placement
    }

    private func showSettings(tab: SettingsTab) {
        dismiss()
        model.settingsTab = tab
        openSettings()
    }

    private func showUsage(sessions: Bool) {
        model.liveUsageDetail = nil
        model.selectedSession = nil
        model.showLiveSessions = sessions
        model.usageNavigation = UUID()
        showSettings(tab: .usage)
    }
}

@MainActor
protocol ShapeHitTesting: AnyObject {
    func contains(screenPoint: CGPoint) -> Bool
}

final class ShapeHostingView<Content: View>: NSHostingView<Content>, ShapeHitTesting {
    var hitPath: (CGRect) -> Path = { Path($0) }

    private func shapePoint(_ local: CGPoint) -> CGPoint {
        isFlipped ? local : CGPoint(x: local.x, y: bounds.maxY - local.y + bounds.minY)
    }

    func contains(screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return hitPath(bounds).contains(shapePoint(local))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitPath(bounds).contains(shapePoint(convert(point, from: superview))) else { return nil }
        return super.hitTest(point)
    }
}

private struct LiveNotchBadge: View {
    @ObservedObject var model: TokenotchModel
    @ObservedObject private var attention: SessionAttentionController
    let edge: NotchEdge
    let scale: CGFloat
    var isCollapsed = false
    let open: (UsageProvider) -> Void

    init(model: TokenotchModel, edge: NotchEdge, scale: CGFloat, open: @escaping (UsageProvider) -> Void) {
        self.model = model
        attention = model.attention
        self.edge = edge
        self.scale = scale
        self.open = open
    }

    var body: some View {
        let presentation = NotchPresentation(model: model, provider: .copilot)
        ProviderNotchBadge(providers: model.notchProviders,
            reading: CopilotRingReading(quota: model.primaryQuota, isStale: model.accountStale,
            isWorking: !presentation.working.isEmpty, needsAttention: presentation.needsAttention,
            sessionSignal: presentation.sessionSignal, sessionSummary: presentation.activityTitle),
            edge: edge, scale: scale, isCollapsed: isCollapsed, open: open,
            claudeStatusLine: model.claude.statusLineState.latest, now: model.clock)
    }
}

extension NotchPresentation {
    @MainActor init(model: TokenotchModel, range requestedRange: HistoryRange? = nil,
                    provider requestedProvider: UsageProvider? = nil) {
        let provider = requestedProvider ?? model.history.selectedSource?.provider ?? model.history.selectedProvider
        let source = model.history.selectedSource.flatMap { provider == nil || $0.provider == provider ? $0 : nil }
        var live = model.liveLedger(provider: provider, source: source)
        self.init(account: model.accountSnapshot, accountStatus: model.accountStatus,
                  accountStale: model.accountStale, tokens: live.today(now: model.clock),
                  tokensPartial: model.tokenSampleLimitReached, sessions: model.sessions,
                  now: model.clock)
        self.provider = provider
        claudeStatusLine = model.claude.statusLineState.latest
        claudeStatusLineEnabled = model.claude.statusLineEnabled
        metricSessions = model.liveSessionMetrics(provider: provider, source: source)
        openClaudeSessions = model.claude.sessionState.openSessions
        if provider == .claudeCode {
            account = nil
            sessions = []
        }
        historyError = model.history.error
        metricsWarning = provider == .claudeCode ? model.claude.error : nil
        models = live.todayByModel(now: model.clock)
        insights = provider == .claudeCode ? [] : model.insights
        range = requestedRange ?? model.history.notchRange
        let matching = provider == model.history.selectedProvider || model.history.selectedSource?.provider == provider
        savedUsage = matching ? (range == .today ? model.history.todayUsage : model.history.notchUsage) : nil
        savedTimeline = matching && range == model.history.notchRange ? model.history.notchTimeline : nil
        liveTimeline = live.hourlyTimeline(now: model.clock)
        timeFormat = model.options.timeFormat
        metricSource = source
        historyLoading = matching && model.history.notchLoading && !(requestedRange == .today && savedUsage != nil)
        historyRecording = provider.map { model.history.recordingProviders.contains($0) } ?? !model.history.recordingProviders.isEmpty
        anchor = model.history.notchAnchor
        healthIncident = provider != .claudeCode && model.healthIncident
        healthObservedAt = model.healthObservedAt
        sessionNotices = provider == .claudeCode ? [] : model.attention.state.notices
        heldNoticeIDs = model.attention.heldNoticeIDs
        noticeSessionIDs = Dictionary(uniqueKeysWithValues: model.sessions.map {
            ($0.id, model.attention.state.sessionID(source: $0.source, hash: $0.key))
        })
        restoredNoticeIDs = Set(sessionNotices.filter { model.attention.isRestored($0) }.map(\.id))
        noticeStorageMessage = model.attention.error != nil ? "Notice saving unavailable - open details" :
            (model.attention.state.evictedSessions > 0 ? "Older notices removed at capacity - open details" : nil)
    }
}
