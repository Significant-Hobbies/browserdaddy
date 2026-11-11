import Foundation

/// Days identify the start of a window; an overnight window ends the following day.
public struct ScheduledSiteBlock: Codable, Hashable, Sendable {
    public let hostname: BlockingHostname
    public let weekdays: Set<Int>
    public let startMinute: Int
    public let endMinute: Int
    public static let maximumCount = 128

    public init?(hostname: BlockingHostname, weekdays: Set<Int>, startMinute: Int, endMinute: Int) {
        guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }),
              (0..<1440).contains(startMinute), (0..<1440).contains(endMinute),
              startMinute != endMinute else { return nil }
        self.hostname = hostname
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    private enum CodingKeys: String, CodingKey { case hostname, weekdays, startMinute, endMinute }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(hostname: try values.decode(BlockingHostname.self, forKey: .hostname),
            weekdays: try values.decode(Set<Int>.self, forKey: .weekdays),
            startMinute: try values.decode(Int.self, forKey: .startMinute),
            endMinute: try values.decode(Int.self, forKey: .endMinute)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid scheduled site block"))
        }
        self = value
    }

    public func matches(hostname raw: String) -> Bool {
        var raw = raw
        if raw.hasSuffix(".") { raw.removeLast() }
        guard let host = BlockingHostname(raw) else { return false }
        return host == hostname || host.value.hasSuffix("." + hostname.value)
    }

    public func isActive(at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return false }
        let current = hour * 60 + minute
        if startMinute < endMinute {
            return weekdays.contains(weekday) && current >= startMinute && current < endMinute
        }
        let previous = weekday == 1 ? 7 : weekday - 1
        return (weekdays.contains(weekday) && current >= startMinute)
            || (weekdays.contains(previous) && current < endMinute)
    }
}

/// Ephemeral native-flow ownership. A drop keeps its slot until macOS reports closure.
public struct ScheduledFlowRegistry<Flow> {
    private struct Entry {
        let flow: Flow
        let hostname: String
        var dropRequested = false
    }
    private var entries: [UUID: Entry] = [:]
    private let maximumCount: Int
    public var count: Int { entries.count }

    public init(maximumCount: Int = 4096) { self.maximumCount = max(0, maximumCount) }

    public mutating func insert(_ flow: Flow, id: UUID, hostname: String) -> Bool {
        if let existing = entries[id] { return !existing.dropRequested }
        guard entries.count < maximumCount else { return false }
        entries[id] = Entry(flow: flow, hostname: hostname)
        return true
    }

    public mutating func remove(id: UUID) { entries.removeValue(forKey: id) }
    public mutating func removeAll() { entries.removeAll() }

    public func blockedIDs(by policy: BlockingPolicy, at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> [UUID] {
        let evaluated = policy.evaluatingSchedules(at: date, timeZone: timeZone)
        return entries.compactMap { id, entry in
            !entry.dropRequested && evaluated.blocks(hostname: entry.hostname, outgoing: true, at: date, timeZone: timeZone) ? id : nil
        }
    }

    public mutating func takeBlocked(ids: [UUID]) -> [Flow] {
        var result: [Flow] = []
        for id in ids {
            guard let entry = entries[id], !entry.dropRequested else { continue }
            entries[id]?.dropRequested = true
            result.append(entry.flow)
        }
        return result
    }

    public mutating func takeBlocked(by policy: BlockingPolicy, at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> [Flow] {
        takeBlocked(ids: blockedIDs(by: policy, at: date, timeZone: timeZone))
    }
}
