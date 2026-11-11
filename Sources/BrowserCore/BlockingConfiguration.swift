import Foundation
import CryptoKit

public struct BlockingConfiguration: Codable, Sendable, Equatable {
    public static let group = "8F7LXHTJZR.com.significanthobbies.browserdaddy"
    public static let extensionID = "com.significanthobbies.browserdaddy.filter"
    public static let filename = "blocking-rules.json"
    public static let providerRulesKey = "rules-v2"
    public static let legacyProviderRulesKey = "rules-v1"
    public static let maximumLocalBytes = 16 * 1024 * 1024
    public static let maximumProviderBytes = 480 * 1024
    public var version = 1
    public var sites: Set<BlockingHostname> = []
    public var scheduledSites: Set<ScheduledSiteBlock> = [] {
        didSet { version = scheduledSites.isEmpty ? 1 : 2 }
    }
    public var categories: Set<BlockingCategory> = []
    public var lists: [BlockingCategory: Set<BlockingHostname>] = [:]
    public var strictUnknownDestinations = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, sites, categories, lists, strictUnknownDestinations, scheduledSites
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        sites = try values.decode(Set<BlockingHostname>.self, forKey: .sites)
        categories = try values.decode(Set<BlockingCategory>.self, forKey: .categories)
        lists = try values.decode([BlockingCategory: Set<BlockingHostname>].self, forKey: .lists)
        strictUnknownDestinations = try values.decodeIfPresent(Bool.self, forKey: .strictUnknownDestinations) ?? false
        scheduledSites = values.contains(.scheduledSites) ? try values.decode(Set<ScheduledSiteBlock>.self, forKey: .scheduledSites) : []
        guard (version == 1 && scheduledSites.isEmpty) || (version == 2 && !scheduledSites.isEmpty),
              scheduledSites.count <= ScheduledSiteBlock.maximumCount else { throw CocoaError(.fileReadCorruptFile) }
    }

    public var activeConfiguration: Self {
        var result = self
        result.lists = lists.filter { categories.contains($0.key) }
        return result
    }

    public var rules: SiteBlockingRules {
        SiteBlockingRules(blockedSites: sites, blockedCategories: categories, categorizedSites: lists)
    }

    public func blocks(hostname: String?, outgoing: Bool, at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> Bool {
        var host = hostname ?? ""
        if host.hasSuffix(".") { host.removeLast() }
        guard BlockingHostname(host) != nil else {
            return outgoing && strictUnknownDestinations
        }
        return rules.decision(for: host) == .blocked
            || scheduledSites.contains { $0.matches(hostname: host) && $0.isActive(at: date, timeZone: timeZone) }
    }

    public static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumLocalBytes else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    public func providerData() throws -> Data {
        try validate()
        var sources: [BlockingCategory: BlockingListSource] = [:]
        for (category, hosts) in lists where categories.contains(category) {
            if !hosts.isEmpty && BlockingListCatalog.canonicalDigest(hosts) == BlockingListCatalog.canonicalDigests[category] {
                sources[category] = .bundled(sha256: BlockingListCatalog.rawDigests[category]!)
            } else {
                sources[category] = .inline(hosts)
            }
        }
        let value = BlockingProviderConfiguration(version: scheduledSites.isEmpty ? 2 : 3, sites: sites, categories: categories,
            sources: sources, strictUnknownDestinations: strictUnknownDestinations, scheduledSites: scheduledSites)
        let data = try JSONEncoder().encode(value)
        try Self.validateProviderSize(data)
        return data
    }

    public static func validateProviderSize(_ data: Data) throws {
        guard data.count <= maximumProviderBytes else { throw BlockingTransportError.configurationTooLarge }
        let vendor = [providerRulesKey: data]
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let encoded = try PropertyListSerialization.data(fromPropertyList: vendor, format: format, options: 0)
            guard encoded.count <= maximumProviderBytes else { throw BlockingTransportError.configurationTooLarge }
        }
    }

    public static func decodeProvider(_ data: Data, catalog: BlockingListCatalog = .main) throws -> Self {
        try validateProviderSize(data)
        let value = try JSONDecoder().decode(BlockingProviderConfiguration.self, from: data)
        try value.validate()
        var result = Self()
        result.sites = value.sites
        result.scheduledSites = value.scheduledSites
        result.categories = value.categories
        result.strictUnknownDestinations = value.strictUnknownDestinations
        for (category, source) in value.sources {
            switch source {
            case .bundled(let sha256): result.lists[category] = try catalog.resolve(category, sha256: sha256)
            case .inline(let hosts): result.lists[category] = hosts
            }
        }
        try result.validate()
        return result
    }

    /// Host maintenance only: recover explicit and active inline additions without trusting
    /// a bundled reference. The provider must continue to use decodeProvider's strict hashes.
    public static func recoverProviderAdditions(_ data: Data) throws -> (configuration: Self, incomplete: Bool) {
        try validateProviderSize(data)
        try requireLegacyRecovery(data)
        let value = try JSONDecoder().decode(BlockingProviderRecoveryConfiguration.self, from: data)
        guard value.version == 2 else { throw BlockingTransportError.unsupportedVersion }
        var result = Self()
        result.sites = value.sites
        var incomplete = value.incomplete
        for category in value.categories {
            guard let source = value.sources[category]?.value else { incomplete = true; continue }
            switch source {
            case .bundled: break
            case .inline(let hosts):
                guard !hosts.isEmpty else { incomplete = true; continue }
                result.categories.insert(category)
                result.lists[category] = hosts
            }
        }
        return (result, incomplete)
    }

    public static func requireLegacyRecovery(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 2 else { throw BlockingTransportError.unsupportedVersion }
        if object.keys.contains("scheduledSites") {
            guard let schedules = object["scheduledSites"] as? [Any], schedules.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    public func localData() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumLocalBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return data
    }

    private func validate() throws {
        guard version == (scheduledSites.isEmpty ? 1 : 2),
              scheduledSites.count <= ScheduledSiteBlock.maximumCount,
              categories.allSatisfy({ !(lists[$0]?.isEmpty ?? true) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try localData().write(to: url, options: .atomic)
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

/// Only this value can produce an app-applied policy. Legacy DTOs remain decodable.
public struct CommittedBlockingRules: Sendable, Equatable {
    public static let protectedSites = Set(["youtube.com", "youtu.be", "youtube-nocookie.com", "reddit.com", "redd.it", "instagram.com"].map { BlockingHostname($0)! })
    public let configuration: BlockingConfiguration

    public init(preserving configurations: [BlockingConfiguration] = [], catalog: BlockingListCatalog = .main) throws {
        var result = BlockingConfiguration()
        result.categories = Set(BlockingCategory.allCases)
        result.strictUnknownDestinations = true
        result.sites = Self.protectedSites
        for category in BlockingCategory.allCases {
            result.lists[category] = try catalog.resolve(category, sha256: BlockingListCatalog.rawDigests[category]!)
        }
        for previous in configurations {
            result.sites.formUnion(previous.sites)
            result.scheduledSites.formUnion(previous.scheduledSites)
            for category in previous.categories {
                result.sites.formUnion((previous.lists[category] ?? []).subtracting(result.lists[category] ?? []))
            }
        }
        configuration = result
    }

    private init(configuration: BlockingConfiguration) { self.configuration = configuration }

    public func addingSite(_ site: BlockingHostname) throws -> Self {
        var result = configuration
        result.sites.insert(site)
        let value = Self(configuration: result)
        _ = try value.providerPayload()
        return value
    }

    public func addingScheduledSite(_ schedule: ScheduledSiteBlock) throws -> Self {
        var result = configuration
        result.scheduledSites.insert(schedule)
        let value = Self(configuration: result)
        _ = try value.providerPayload()
        return value
    }

    public func preserving(_ previous: BlockingConfiguration) throws -> Self {
        var result = configuration
        result.sites.formUnion(previous.sites)
        result.scheduledSites.formUnion(previous.scheduledSites)
        for category in previous.categories {
            result.sites.formUnion((previous.lists[category] ?? []).subtracting(result.lists[category] ?? []))
        }
        let value = Self(configuration: result)
        _ = try value.providerPayload()
        return value
    }

    public func providerPayload() throws -> CommittedBlockingPayload {
        let value = BlockingProviderConfiguration(version: configuration.scheduledSites.isEmpty ? 2 : 3, sites: configuration.sites,
            categories: configuration.categories,
            sources: Dictionary(uniqueKeysWithValues: BlockingCategory.allCases.map {
                ($0, .bundled(sha256: BlockingListCatalog.rawDigests[$0]!))
            }), strictUnknownDestinations: true, scheduledSites: configuration.scheduledSites)
        return try CommittedBlockingPayload(data: JSONEncoder().encode(value))
    }

    public func save(to url: URL) throws {
        _ = try providerPayload()
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        if let existing, try BlockingConfiguration.decode(existing) == configuration { return }
        let data = try configuration.localData()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing {
            let recovery = url.appendingPathExtension("pre-commitment")
            if !FileManager.default.fileExists(atPath: recovery.path) {
                let temporary = url.appendingPathExtension("recovery-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try existing.write(to: temporary, options: .atomic)
                // An exclusive hard link publishes complete bytes without replacing a prior backup.
                try FileManager.default.linkItem(at: temporary, to: recovery)
            }
        }
        try data.write(to: url, options: .atomic)
    }
}

public struct CommittedBlockingPayload: Sendable {
    public let data: Data
    fileprivate init(data: Data) throws {
        try BlockingConfiguration.validateProviderSize(data)
        try JSONDecoder().decode(BlockingProviderConfiguration.self, from: data).validate()
        self.data = data
    }

    public func matches(_ applied: Data?) -> Bool {
        guard let applied,
              let actual = try? JSONDecoder().decode(BlockingProviderConfiguration.self, from: applied),
              let expected = try? JSONDecoder().decode(BlockingProviderConfiguration.self, from: data) else { return false }
        return actual == expected
    }
}

/// The provider starts closed and swaps only fully validated snapshots.
public struct BlockingPolicy: Sendable {
    private let configuration: BlockingConfiguration?

    public init() { configuration = nil }
    public init(data: Data, catalog: BlockingListCatalog = .main) throws {
        configuration = try CommittedBlockingRules(preserving: [BlockingConfiguration.decodeProvider(data, catalog: catalog)], catalog: catalog).configuration
    }

    public init(committedProviderData: Data?, catalog: BlockingListCatalog = .main) {
        configuration = committedProviderData.flatMap { try? CommittedBlockingRules(preserving: [BlockingConfiguration.decodeProvider($0, catalog: catalog)], catalog: catalog).configuration }
    }

    public init(vendorConfiguration: [String: Any]?, catalog: BlockingListCatalog = .main) {
        if let vendorConfiguration, vendorConfiguration.keys.contains(BlockingConfiguration.providerRulesKey) {
            configuration = (vendorConfiguration[BlockingConfiguration.providerRulesKey] as? Data)
                .flatMap { try? CommittedBlockingRules(preserving: [BlockingConfiguration.decodeProvider($0, catalog: catalog)], catalog: catalog).configuration }
        } else if let data = vendorConfiguration?[BlockingConfiguration.legacyProviderRulesKey] as? Data,
                  data.count <= 512 * 1024 {
            configuration = try? CommittedBlockingRules(preserving: [BlockingConfiguration.decode(data)], catalog: catalog).configuration
        } else {
            configuration = nil
        }
    }

    public func blocks(hostname: String?, outgoing: Bool, at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> Bool {
        configuration?.blocks(hostname: hostname, outgoing: outgoing, at: date, timeZone: timeZone) ?? outgoing
    }

    /// Resolve wall-clock activity once for a batch of open scheduled connections.
    public func evaluatingSchedules(at date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> Self {
        guard var value = configuration else { return Self() }
        for schedule in value.scheduledSites where schedule.isActive(at: date, timeZone: timeZone) {
            value.sites.insert(schedule.hostname)
        }
        value.scheduledSites = []
        return Self(configuration: value)
    }

    private init(configuration: BlockingConfiguration) { self.configuration = configuration }

    public func hasSchedule(hostname: String?) -> Bool {
        guard let hostname else { return false }
        return configuration?.scheduledSites.contains { $0.matches(hostname: hostname) } ?? false
    }
}

private enum BlockingListSource: Codable, Equatable {
    case bundled(sha256: String)
    case inline(Set<BlockingHostname>)
}

private struct BlockingProviderConfiguration: Codable, Equatable {
    let version: Int
    let sites: Set<BlockingHostname>
    let categories: Set<BlockingCategory>
    let sources: [BlockingCategory: BlockingListSource]
    let strictUnknownDestinations: Bool
    let scheduledSites: Set<ScheduledSiteBlock>

    init(version: Int, sites: Set<BlockingHostname>, categories: Set<BlockingCategory>,
         sources: [BlockingCategory: BlockingListSource], strictUnknownDestinations: Bool,
         scheduledSites: Set<ScheduledSiteBlock>) {
        self.version = version
        self.sites = sites
        self.categories = categories
        self.sources = sources
        self.strictUnknownDestinations = strictUnknownDestinations
        self.scheduledSites = scheduledSites
    }

    private enum CodingKeys: String, CodingKey { case version, sites, categories, sources, strictUnknownDestinations, scheduledSites }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        sites = try values.decode(Set<BlockingHostname>.self, forKey: .sites)
        categories = try values.decode(Set<BlockingCategory>.self, forKey: .categories)
        sources = try values.decode([BlockingCategory: BlockingListSource].self, forKey: .sources)
        strictUnknownDestinations = try values.decode(Bool.self, forKey: .strictUnknownDestinations)
        scheduledSites = values.contains(.scheduledSites) ? try values.decode(Set<ScheduledSiteBlock>.self, forKey: .scheduledSites) : []
        try validate()
    }

    func validate() throws {
        guard (version == 2 && scheduledSites.isEmpty) || (version == 3 && !scheduledSites.isEmpty),
              scheduledSites.count <= ScheduledSiteBlock.maximumCount else { throw BlockingTransportError.unsupportedVersion }
    }
}

private struct RecoverableBlockingValue<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

private struct RecoverableBlockingValues<Value: Decodable & Hashable>: Decodable {
    let values: Set<Value>
    let incomplete: Bool

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: Set<Value> = []
        var incomplete = false
        while !container.isAtEnd {
            let item = try container.decode(RecoverableBlockingValue<Value>.self)
            if let value = item.value { values.insert(value) }
            else { incomplete = true }
        }
        self.values = values
        self.incomplete = incomplete
    }
}

private struct RecoverableBlockingListSource: Decodable {
    let value: BlockingListSource?
    let incomplete: Bool
    private enum CodingKeys: String, CodingKey { case inline }
    private enum InlineKeys: String, CodingKey { case hosts = "_0" }

    init(from decoder: Decoder) throws {
        if let source = try? BlockingListSource(from: decoder) {
            value = source
            incomplete = false
        } else {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            let inline = try? container?.nestedContainer(keyedBy: InlineKeys.self, forKey: .inline)
            let hosts = try? inline?.decode(RecoverableBlockingValues<BlockingHostname>.self, forKey: .hosts)
            value = hosts.map { .inline($0.values) }
            incomplete = true
        }
    }
}

private struct BlockingProviderRecoveryConfiguration: Decodable {
    let version: Int
    let sites: Set<BlockingHostname>
    let categories: Set<BlockingCategory>
    let sources: [BlockingCategory: RecoverableBlockingListSource]
    let incomplete: Bool

    private enum CodingKeys: String, CodingKey { case version, sites, categories, sources }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        let sites = try? values.decode(RecoverableBlockingValues<BlockingHostname>.self, forKey: .sites)
        let categories = try? values.decode(RecoverableBlockingValues<BlockingCategory>.self, forKey: .categories)
        self.sites = sites?.values ?? []
        self.categories = categories?.values ?? []
        var incomplete = sites == nil || categories == nil || sites?.incomplete == true || categories?.incomplete == true
        var sources: [BlockingCategory: RecoverableBlockingListSource] = [:]
        if var pairs = try? values.nestedUnkeyedContainer(forKey: .sources) {
            while !pairs.isAtEnd {
                let category = try pairs.decode(RecoverableBlockingValue<BlockingCategory>.self).value
                guard !pairs.isAtEnd else { incomplete = true; break }
                let source = try pairs.decode(RecoverableBlockingListSource.self)
                if let category, sources[category] == nil { sources[category] = source }
                else { incomplete = true }
                if source.incomplete { incomplete = true }
            }
        } else { incomplete = true }
        self.sources = sources
        self.incomplete = incomplete
    }
}

public enum BlockingTransportError: LocalizedError {
    case configurationTooLarge, unsupportedVersion, unsupportedReference, missingResource, corruptResource, invalidList

    public var errorDescription: String? {
        switch self {
        case .configurationTooLarge: return "The protected rules exceed the macOS filter limit. Existing saved rules have been preserved; assisted maintenance is required."
        case .unsupportedVersion: return "Unsupported filter rules version."
        case .unsupportedReference: return "Unsupported bundled category reference."
        case .missingResource: return "A bundled category list is missing."
        case .corruptResource: return "A bundled category list failed its integrity check."
        case .invalidList: return "A category list must contain valid domains."
        }
    }
}

public struct BlockingListCatalog: Sendable {
    private let resource: @Sendable (BlockingCategory) throws -> Data

    public init(resource: @escaping @Sendable (BlockingCategory) throws -> Data) {
        self.resource = resource
    }

    public static let main = BlockingListCatalog { category in
        let name = category == .adult ? "Adult" : "Gambling"
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else {
            throw BlockingTransportError.missingResource
        }
        return try Data(contentsOf: url)
    }

    static let rawDigests: [BlockingCategory: String] = [
        .adult: "4eb9d0d020d546521c4d90485d7c423f6fbb1336e880d003fd08dcce5c7675d3",
        .gambling: "a0655a6a781fea5a8ecd5bf2b45e83cacd4b7b27350a34d58544de5d866cae2c"
    ]
    static let canonicalDigests: [BlockingCategory: String] = [
        .adult: "5892095c2383c1686ae5ac90210523eb3f6754676e376d098c8d6d739b428c57",
        .gambling: "304494de8354d8c560260778467b931d065cfa1a7141e1aca968fe46ee47b31c"
    ]

    static func canonicalDigest(_ hosts: Set<BlockingHostname>) -> String {
        digest(Data((hosts.map(\.value).sorted().joined(separator: "\n") + "\n").utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func resolve(_ category: BlockingCategory, sha256: String) throws -> Set<BlockingHostname> {
        guard sha256 == Self.rawDigests[category] else { throw BlockingTransportError.unsupportedReference }
        let data = try resource(category)
        guard Self.digest(data) == sha256 else { throw BlockingTransportError.corruptResource }
        guard let text = String(data: data, encoding: .utf8) else { throw BlockingTransportError.invalidList }
        return try BlockingConfiguration.parseList(text)
    }
}
