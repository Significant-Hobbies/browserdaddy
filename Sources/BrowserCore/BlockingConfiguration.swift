import Foundation

public struct BlockingConfiguration: Codable, Sendable, Equatable {
    public static let group = "8F7LXHTJZR.com.significanthobbies.browserdaddy"
    public static let extensionID = "com.significanthobbies.browserdaddy.filter"
    public static let filename = "blocking-rules.json"
    public static let providerRulesKey = "rules-v1"
    public static let maximumProviderBytes = 16 * 1024 * 1024
    public var version = 1
    public var sites: Set<BlockingHostname> = []
    public var categories: Set<BlockingCategory> = []
    public var lists: [BlockingCategory: Set<BlockingHostname>] = [:]

    public init() {}

    public var rules: SiteBlockingRules {
        SiteBlockingRules(blockedSites: sites, blockedCategories: categories, categorizedSites: lists)
    }

    public static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumProviderBytes else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    public func providerData() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumProviderBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return data
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try providerData().write(to: url, options: .atomic)
    }

    public static func parseList(_ text: String) throws -> Set<BlockingHostname> {
        guard text.utf8.count <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        var hosts: Set<BlockingHostname> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let clean = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }
            let parts = clean.split(whereSeparator: \.isWhitespace)
            let raw: String
            if parts.count == 2 && ["0.0.0.0", "127.0.0.1"].contains(String(parts[0])) {
                raw = String(parts[1])
            } else if parts.count == 1 { raw = String(parts[0]) }
            else { throw CocoaError(.fileReadCorruptFile) }
            if raw == "localhost" { continue }
            guard let host = BlockingHostname(raw) else { throw CocoaError(.fileReadCorruptFile) }
            hosts.insert(host)
        }
        guard !hosts.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return hosts
    }
}
