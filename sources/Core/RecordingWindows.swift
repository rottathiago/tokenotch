import Foundation

public struct RecordingWindows<Key: Hashable & Sendable>: Sendable {
    public private(set) var starts: [Key: Date] = [:]
    public var keys: Set<Key> { Set(starts.keys) }
    public init() {}

    public mutating func update(_ keys: Set<Key>, at date: Date) {
        starts = starts.filter { keys.contains($0.key) }
        for key in keys where starts[key] == nil { starts[key] = date }
    }

    public func accepts(_ key: Key, at date: Date) -> Bool {
        starts[key].map { date >= $0 } ?? false
    }
}
