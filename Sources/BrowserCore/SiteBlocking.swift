import Foundation

/// An ASCII DNS hostname. User-facing URL parsing belongs at the input boundary.
public struct BlockingHostname: Hashable, Codable, Sendable {
    public let value: String

    public init?(_ input: String) {
        guard !input.isEmpty, input.utf8.count <= 253,
              input.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let host = input.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last,
              last.utf8.contains(where: { (97...122).contains($0) }),
              labels.allSatisfy({ label in
                  let bytes = Array(label.utf8)
                  guard !bytes.isEmpty, bytes.count <= 63,
                        bytes.first != 45, bytes.last != 45 else { return false }
                  return bytes.allSatisfy {
                      (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                  }
              }) else { return nil }
        value = host
    }

    private enum CodingKeys: String, CodingKey { case value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .value)
        guard let hostname = Self(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container,
                                                    debugDescription: "Invalid hostname")
        }
        self = hostname
    }
}

public enum BlockingCategory: String, CaseIterable, Codable, Sendable {
    case adult
    case gambling

    public var title: String { self == .adult ? "Adult content" : "Gambling" }
}

public struct SiteBlockingRules: Sendable {
    public enum Decision: Equatable, Sendable {
        case blocked
        case allowed
        case unknown
    }

    public let blockedSites: Set<BlockingHostname>
    public let blockedCategories: Set<BlockingCategory>
    public let categorizedSites: [BlockingCategory: Set<BlockingHostname>]

    public init(blockedSites: Set<BlockingHostname> = [],
                blockedCategories: Set<BlockingCategory> = [],
                categorizedSites: [BlockingCategory: Set<BlockingHostname>] = [:]) {
        self.blockedSites = blockedSites
        self.blockedCategories = blockedCategories
        self.categorizedSites = categorizedSites
    }

    /// Unknown means no category matched. The caller chooses the unknown policy.
    public func decision(for rawHostname: String) -> Decision {
        guard let hostname = BlockingHostname(rawHostname) else { return .unknown }
        let labels = hostname.value.split(separator: ".")
        let suffixes = (0..<(labels.count - 1)).compactMap { index in
            BlockingHostname(labels[index...].joined(separator: "."))
        }
        if suffixes.contains(where: blockedSites.contains) { return .blocked }
        var known = false
        for (category, domains) in categorizedSites {
            guard suffixes.contains(where: domains.contains) else { continue }
            if blockedCategories.contains(category) { return .blocked }
            known = true
        }
        return known ? .allowed : .unknown
    }
}
