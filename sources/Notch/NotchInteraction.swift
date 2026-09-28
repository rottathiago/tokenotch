import Foundation

struct NotchInteraction {
    enum Action: Equatable {
        case reveal(Int)
        case dismiss
    }

    struct NoticeExposure {
        enum Origin { case deliberate, hover, automatic }
        struct Update {
            var viewed = Set<String>()
            var dismiss = Set<String>()
        }

        private(set) var generation = UUID()
        private var initial = Set<String>()
        private var visible = Set<String>()
        private var began: [String: Date] = [:]
        private var consumed = Set<String>()
        private var initialPending = false
        private var deliberate = false
        private var requestBegan: [String: Date] = [:]
        private var dismissed = Set<String>()
        /// Rows a person demonstrably looked at during this opening; acknowledged on close.
        private var qualified = Set<String>()
        private var engagedTime: [String: TimeInterval] = [:]
        private var lastEngagedTick: Date?
        private var lastEngagedRows = Set<String>()
        static let closeAcknowledgment: TimeInterval = 0.5

        mutating func open(origin: Origin, initial: Set<String>, keepingVisibility: Bool = false) {
            let previous = self
            self = NoticeExposure()
            self.initial = initial
            initialPending = origin == .deliberate
            deliberate = origin == .deliberate
            if keepingVisibility {
                visible = previous.visible.intersection(initial)
                deliberate = deliberate || previous.deliberate
                requestBegan = previous.requestBegan.filter { initial.contains($0.key) }
                dismissed = previous.dismissed.intersection(initial)
                qualified = previous.qualified
                engagedTime = previous.engagedTime
            }
        }

        mutating func visibility(_ id: String, visible isVisible: Bool, generation: UUID) {
            guard generation == self.generation else { return }
            if isVisible { visible.insert(id) }
            else {
                visible.remove(id)
                began.removeValue(forKey: id)
                requestBegan.removeValue(forKey: id)
            }
        }

        mutating func tick(now: Date, windowVisible: Bool, engaged: Bool,
                           pendingRequests: Set<String> = []) -> Update {
            guard windowVisible else {
                began = [:]
                requestBegan = [:]
                lastEngagedTick = nil
                lastEngagedRows = []
                return Update()
            }
            if engaged {
                let elapsed = lastEngagedTick.map { max(0, now.timeIntervalSince($0)) } ?? 0
                for id in visible.intersection(lastEngagedRows) {
                    let total = engagedTime[id, default: 0] + elapsed
                    engagedTime[id] = total
                    if total >= Self.closeAcknowledgment - 0.001 { qualified.insert(id) }
                }
                lastEngagedTick = now
                lastEngagedRows = visible
            } else {
                lastEngagedTick = nil
                lastEngagedRows = []
            }
            var seen = Set<String>()
            if initialPending {
                seen = visible.intersection(initial)
                // Allow the first real layout callback, not a pre-layout timer tick.
                if !visible.isEmpty { initialPending = false }
            }
            for id in visible.subtracting(consumed) where !seen.contains(id) {
                if engaged {
                    if let start = began[id], now.timeIntervalSince(start) >= 1 { seen.insert(id) }
                    else if began[id] == nil { began[id] = now }
                } else { began.removeValue(forKey: id) }
            }
            consumed.formUnion(seen)

            // Request dwell starts at visibility, independently of the earlier viewed marker.
            let requests = visible.intersection(pendingRequests)
            dismissed.formIntersection(pendingRequests)
            requestBegan = requestBegan.filter { requests.contains($0.key) }
            var due = Set<String>()
            if deliberate || engaged {
                for id in requests.subtracting(dismissed) {
                    if let start = requestBegan[id], now.timeIntervalSince(start) >= 3 {
                        due.insert(id)
                    } else if requestBegan[id] == nil {
                        requestBegan[id] = now
                    }
                }
            } else {
                requestBegan = [:]
            }
            dismissed.formUnion(due)
            qualified.formUnion(seen)
            qualified.formUnion(due)
            return Update(viewed: seen, dismiss: due)
        }

        /// Resets the tracker and returns the rows that were looked at during this opening.
        @discardableResult
        mutating func close() -> Set<String> {
            let result = qualified
            self = NoticeExposure()
            return result
        }
    }

    private(set) var isVisible = false
    private(set) var isPinned = false
    private var hoveredIndex: Int?
    private var visibleIndex: Int?
    private var hoverBegan = Date.distantPast
    private var leftAt: Date?
    private var minimumVisibleUntil = Date.distantPast

    mutating func show(pinned: Bool, now: Date, minimumDuration: TimeInterval = 0, sourceIndex: Int? = nil) {
        isVisible = true
        isPinned = pinned
        visibleIndex = sourceIndex ?? hoveredIndex
        minimumVisibleUntil = now.addingTimeInterval(minimumDuration)
        leftAt = nil
    }

    mutating func dismiss() {
        isVisible = false
        isPinned = false
        visibleIndex = nil
        leftAt = nil
        minimumVisibleUntil = .distantPast
    }

    mutating func update(hovered index: Int?, overDetail: Bool, now: Date) -> Action? {
        if index != hoveredIndex {
            hoveredIndex = index
            hoverBegan = now
        }
        if let index, !isVisible || (!isPinned && index != visibleIndex),
           now.timeIntervalSince(hoverBegan) >= 0.18 {
            return .reveal(index)
        }
        if index != nil || overDetail {
            leftAt = nil
        } else if isVisible && !isPinned && now >= minimumVisibleUntil {
            if let leftAt {
                if now.timeIntervalSince(leftAt) >= 0.25 { return .dismiss }
            } else { leftAt = now }
        }
        return nil
    }
}
