// ABOUTME: Client-side ordering of session lists: sort modes and a manual order the user arranges.
// ABOUTME: Mutagen lists sessions by creation time and stores no order, so Helix keeps its own.

import Foundation

public enum SessionSortMode: String, CaseIterable, Identifiable, Sendable {
    case manual
    case name
    case status
    case server
    case created

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .status: "Status"
        case .server: "Server"
        case .created: "Date Created"
        }
    }
}

/// How urgently a session needs attention, most urgent first.
public enum SessionAttention: Int, Comparable, Sendable {
    case failing
    case degraded
    case running
    case paused

    public static func < (lhs: SessionAttention, rhs: SessionAttention) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public protocol OrderableSession {
    var identifier: String { get }
    var name: String? { get }
    /// Host of the remote endpoint, or nil when every endpoint is local.
    var serverName: String? { get }
    var attention: SessionAttention { get }
}

extension OrderableSession {
    /// The key the manual order stores this session under: its name, or its identifier when unnamed.
    public var orderKey: String {
        nonEmptyName ?? identifier
    }

    fileprivate var nonEmptyName: String? {
        name.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension SyncSession: OrderableSession {
    public var serverName: String? {
        [beta, alpha].lazy.filter { $0.protocol_ != "local" }.compactMap(\.host).first
    }

    public var attention: SessionAttention {
        if paused { return .paused }
        switch phase {
        case .disconnected, .connecting:
            return .failing
        case .stalled:
            return .degraded
        default:
            return (conflicts ?? []).isEmpty ? .running : .degraded
        }
    }
}

extension ForwardSession: OrderableSession {
    public var serverName: String? {
        [destination, source].lazy.filter { $0.protocol_ != "local" }.compactMap(\.host).first
    }

    public var attention: SessionAttention {
        if paused { return .paused }
        if source.connected == false || destination.connected == false { return .failing }
        return .running
    }
}

public enum SessionOrder {

    /// Sessions in the order `mode` gives.
    /// - Parameters:
    ///   - sessions: sessions in mutagen's order, which is creation order.
    ///   - manualOrder: stored order keys. The other modes use it to break ties.
    public static func sorted<S: OrderableSession>(
        _ sessions: [S],
        by mode: SessionSortMode,
        manualOrder: [String]
    ) -> [S] {
        let manual = arranged(sessions, key: \.orderKey, manualOrder: manualOrder)
        switch mode {
        case .created:
            return sessions
        case .manual:
            return manual
        case .name:
            return stablySorted(manual) { precedes($0.nonEmptyName, $1.nonEmptyName) }
        case .status:
            return stablySorted(manual) { $0.attention < $1.attention }
        case .server:
            return stablySorted(manual) { precedes($0.serverName?.lowercased(), $1.serverName?.lowercased()) }
        }
    }

    /// The stored order after sessions move in the manually ordered list.
    /// - Parameters:
    ///   - offsets: positions in the displayed list, as SwiftUI's `onMove` reports them.
    ///   - destination: the insertion position, as SwiftUI's `onMove` reports it.
    ///   - keys: order keys of the current sessions, in mutagen's order.
    ///   - manualOrder: the stored order. Keys of absent sessions stay after the key they followed.
    /// - Returns: `manualOrder` unchanged when the offsets do not fit the displayed list.
    public static func moving(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        keys: [String],
        manualOrder: [String]
    ) -> [String] {
        var displayed = arranged(keys, key: \.self, manualOrder: manualOrder)
        guard let last = offsets.last, last < displayed.count, destination <= displayed.count else {
            return manualOrder
        }
        let moved = offsets.map { displayed[$0] }
        displayed = displayed.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        displayed.insert(contentsOf: moved, at: destination - offsets.count(in: 0..<destination))

        let present = Set(keys)
        var leadingAbsent: [String] = []
        var absentAfter: [String: [String]] = [:]
        var previous: String?
        for key in manualOrder {
            if present.contains(key) {
                previous = key
            } else if let previous {
                absentAfter[previous, default: []].append(key)
            } else {
                leadingAbsent.append(key)
            }
        }

        var result = leadingAbsent
        for key in unique(displayed) {
            result.append(key)
            result += absentAfter[key] ?? []
        }
        return unique(result)
    }

    /// `order` with `newKey` in place of `oldKey`, for a session recreated under a new name or identifier.
    public static func replacing(_ oldKey: String, with newKey: String, in order: [String]) -> [String] {
        guard oldKey != newKey, order.contains(oldKey) else { return order }
        return unique(order.compactMap { key in
            if key == oldKey { return newKey }
            return key == newKey ? nil : key
        })
    }

    /// `order` followed by the `keys` it lacks, which is the order the manual mode displays.
    public static func filledIn(_ order: [String], with keys: [String]) -> [String] {
        unique(order + keys)
    }

    private static func arranged<T>(_ items: [T], key: (T) -> String, manualOrder: [String]) -> [T] {
        let rank = Dictionary(
            manualOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return stablySorted(items) { (rank[key($0)] ?? .max) < (rank[key($1)] ?? .max) }
    }

    /// Orders present values before nil and compares them as Finder compares file names.
    private static func precedes(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs.localizedStandardCompare(rhs) == .orderedAscending
        case (.some, nil): true
        default: false
        }
    }

    private static func stablySorted<T>(_ items: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            if areInIncreasingOrder(lhs.element, rhs.element) { return true }
            if areInIncreasingOrder(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }
}
