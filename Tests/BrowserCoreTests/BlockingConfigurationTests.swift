import XCTest
@testable import BrowserCore

final class BlockingConfigurationTests: XCTestCase {
    func testLegacyNativePreferencesKeepTheirPolicyUntilV2IsCommitted() throws {
        var legacy = BlockingConfiguration()
        legacy.sites = [BlockingHostname("blocked.test")!]
        legacy.categories = [.adult]
        legacy.lists[.adult] = [BlockingHostname("adult.test")!]
        let old = try legacy.localData()
        var policy = BlockingPolicy(vendorConfiguration: [BlockingConfiguration.legacyProviderRulesKey: old])
        XCTAssertTrue(policy.blocks(hostname: "sub.blocked.test", outgoing: true))
        XCTAssertTrue(policy.blocks(hostname: "sub.adult.test", outgoing: true))
        XCTAssertFalse(policy.blocks(hostname: "allowed.test", outgoing: true))
        for invalid in [Data("invalid".utf8), NSNull()] as [Any] {
            policy = BlockingPolicy(vendorConfiguration: [
                BlockingConfiguration.legacyProviderRulesKey: old,
                BlockingConfiguration.providerRulesKey: invalid
            ])
            XCTAssertTrue(policy.blocks(hostname: "allowed.test", outgoing: true))
        }
        let current = try legacy.providerData()
        policy = BlockingPolicy(vendorConfiguration: [
            BlockingConfiguration.legacyProviderRulesKey: Data("invalid".utf8),
            BlockingConfiguration.providerRulesKey: current
        ])
        XCTAssertFalse(policy.blocks(hostname: "allowed.test", outgoing: true))
        policy = BlockingPolicy(vendorConfiguration: [
            BlockingConfiguration.legacyProviderRulesKey: Data(repeating: 0, count: 512 * 1024 + 1)
        ])
        XCTAssertTrue(policy.blocks(hostname: "allowed.test", outgoing: true))
    }

    func testProviderStartsClosedAndRetainsValidPolicyAfterRejectedReplacement() throws {
        var policy = BlockingPolicy()
        XCTAssertTrue(policy.blocks(hostname: "allowed.test", outgoing: true))
        XCTAssertTrue(policy.blocks(hostname: nil, outgoing: true))
        XCTAssertFalse(policy.blocks(hostname: nil, outgoing: false))
        var config = BlockingConfiguration()
        config.sites = [BlockingHostname("blocked.test")!]
        policy = try BlockingPolicy(data: config.providerData())
        XCTAssertFalse(policy.blocks(hostname: "allowed.test", outgoing: true))
        XCTAssertTrue(policy.blocks(hostname: "blocked.test", outgoing: true))
        XCTAssertThrowsError(try { policy = try BlockingPolicy(data: Data("corrupt".utf8)) }())
        XCTAssertTrue(policy.blocks(hostname: "blocked.test", outgoing: true))
        XCTAssertFalse(policy.blocks(hostname: "allowed.test", outgoing: true))
    }
    func testStrictProtectionBlocksUnidentifiableOutgoingDestinationsOnly() throws {
        var config = BlockingConfiguration()
        config.sites = [BlockingHostname("blocked.test")!]
        XCTAssertFalse(config.blocks(hostname: nil, outgoing: true))
        config.strictUnknownDestinations = true
        for host in [nil, "", "127.0.0.1", "::1", "example..com", "https://allowed.test"] as [String?] {
            XCTAssertTrue(config.blocks(hostname: host, outgoing: true), "\(String(describing: host))")
            XCTAssertFalse(config.blocks(hostname: host, outgoing: false))
        }
        XCTAssertTrue(config.blocks(hostname: "www.blocked.test.", outgoing: true))
        XCTAssertFalse(config.blocks(hostname: "notblocked.test", outgoing: true))
        XCTAssertFalse(config.blocks(hostname: "allowed.test", outgoing: true))
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(config.providerData()), config)
    }

    func testLegacyConfigurationDoesNotEnableStrictModeImplicitly() throws {
        let current = try BlockingConfiguration().localData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        json.removeValue(forKey: "strictUnknownDestinations")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        XCTAssertFalse(try BlockingConfiguration.decode(legacy).strictUnknownDestinations)
        json["strictUnknownDestinations"] = "true"
        XCTAssertThrowsError(try BlockingConfiguration.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testEnabledCategoryWithoutDataIsRejectedBeforeReplacingSavedRules() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var config = BlockingConfiguration()
        config.sites = [BlockingHostname("blocked.test")!]
        try config.save(to: file)
        let original = try Data(contentsOf: file)
        config.categories = [.adult]
        XCTAssertThrowsError(try config.save(to: file))
        XCTAssertEqual(try Data(contentsOf: file), original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["categories"] = ["adult"]
        XCTAssertThrowsError(try BlockingConfiguration.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testSaveReloadAndCategoryDecisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("rules.json")
        defer { try? FileManager.default.removeItem(at: root) }
        var config = BlockingConfiguration()
        config.categories = [.adult, .gambling]
        config.lists[.adult] = try BlockingConfiguration.parseList("# local\n0.0.0.0 adult.test\n")
        config.lists[.gambling] = try BlockingConfiguration.parseList("bet.test\n")
        try config.save(to: file)
        let loaded = try BlockingConfiguration.load(from: file)
        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.rules.decision(for: "www.adult.test"), .blocked)
        XCTAssertEqual(loaded.rules.decision(for: "bet.test"), .blocked)
        XCTAssertEqual(loaded.rules.decision(for: "unknown.test"), .unknown)
        config.categories = []
        try config.save(to: file)
        XCTAssertEqual(try BlockingConfiguration.load(from: file).rules.decision(for: "bet.test"), .allowed)
    }

    func testImportsRejectInvalidOrEmptyListsWithoutPartialSuccess() throws {
        for text in ["# empty", "", "example.com\nhttps://bad.test", "com", "1.2.3.4"] {
            XCTAssertThrowsError(try BlockingConfiguration.parseList(text))
        }
        XCTAssertEqual(try BlockingConfiguration.parseList("EXAMPLE.COM\nexample.com\n").count, 1)
    }

    func testProviderPayloadCarriesRulesWithoutAUserContainerPath() throws {
        var config = BlockingConfiguration()
        config.categories = [.gambling]
        config.lists[.gambling] = try BlockingConfiguration.parseList("bet.test")
        let payload = try config.providerData()
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(payload), config)
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(payload).rules.decision(for: "www.bet.test"), .blocked)
        XCTAssertThrowsError(try BlockingConfiguration.decodeProvider(Data(repeating: 0, count: BlockingConfiguration.maximumProviderBytes + 1)))
        XCTAssertThrowsError(try BlockingConfiguration.decodeProvider(Data("{}".utf8)))
    }

    private static let listRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/BrowserDaddy/Resources/BlockingLists")

    private static let catalog = BlockingListCatalog { category in
        let name = category == .adult ? "Adult" : "Gambling"
        return try Data(contentsOf: listRoot.appendingPathComponent(name + ".txt"))
    }

    private func fullConfiguration() throws -> BlockingConfiguration {
        var config = BlockingConfiguration()
        config.categories = [.adult, .gambling]
        config.strictUnknownDestinations = true
        config.sites = Set(["youtube.com", "youtu.be", "youtube-nocookie.com", "reddit.com", "redd.it", "instagram.com"].map { BlockingHostname($0)! })
        for category in BlockingCategory.allCases {
            let name = category == .adult ? "Adult" : "Gambling"
            config.lists[category] = try BlockingConfiguration.parseList(
                String(contentsOf: Self.listRoot.appendingPathComponent(name + ".txt"), encoding: .utf8))
        }
        return config
    }

    func testBundledListsAreUsableAndNonempty() throws {
        let config = try fullConfiguration()
        XCTAssertEqual(config.lists[.adult]?.count, 236454)
        XCTAssertEqual(config.lists[.gambling]?.count, 9667)
        let data = try config.providerData()
        XCTAssertLessThan(data.count, 1024)
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(data, catalog: Self.catalog), config)
        let policy = try BlockingPolicy(data: data, catalog: Self.catalog)
        for category in BlockingCategory.allCases {
            for host in config.lists[category]! {
                XCTAssertTrue(policy.blocks(hostname: host.value, outgoing: true))
            }
            let host = config.lists[category]!.sorted { $0.value < $1.value }[0].value
            XCTAssertTrue(policy.blocks(hostname: "sub." + host, outgoing: true))
            XCTAssertFalse(policy.blocks(hostname: host + ".unlisted.test", outgoing: true))
        }
        XCTAssertTrue(policy.blocks(hostname: "m.youtube.com", outgoing: true))
        XCTAssertFalse(policy.blocks(hostname: "notyoutube.com", outgoing: true))
        XCTAssertFalse(policy.blocks(hostname: "youtube.com.unlisted.test", outgoing: true))
        XCTAssertTrue(policy.blocks(hostname: nil, outgoing: true))
        XCTAssertFalse(policy.blocks(hostname: nil, outgoing: false))
        print("Pinned provider payload \(data.count) bytes for 246121 category domains and six explicit sites")
    }

    func testLegacyFullLocalConfigurationRemainsLoadable() throws {
        let config = try fullConfiguration()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try config.save(to: file)
        XCTAssertGreaterThan(try Data(contentsOf: file).count, 6 * 1024 * 1024)
        XCTAssertEqual(try BlockingConfiguration.load(from: file), config)
    }

    func testModifiedPinnedListIsInlineAndOversizeIsRejected() throws {
        var config = try fullConfiguration()
        config.lists[.adult]!.insert(BlockingHostname("custom-adult.test")!)
        XCTAssertThrowsError(try config.providerData()) { error in
            XCTAssertTrue(error is BlockingTransportError)
        }
        config.categories = [.gambling]
        config.lists = [.gambling: [BlockingHostname("custom-bet.test")!]]
        let data = try config.providerData()
        let missing = BlockingListCatalog { _ in throw BlockingTransportError.missingResource }
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(data, catalog: missing), config)
        let malformed = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "custom-bet.test", with: "https://bad.test").utf8)
        XCTAssertThrowsError(try BlockingConfiguration.decodeProvider(malformed, catalog: missing))
    }

    func testInactiveCustomListsStayLocalWithoutConsumingProviderBudget() throws {
        var config = BlockingConfiguration()
        config.lists[.adult] = Set((0..<20000).map { BlockingHostname("custom-\($0).test")! })
        let payload = try config.providerData()
        XCTAssertLessThan(payload.count, 1024)
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(payload), config.activeConfiguration)
        XCTAssertGreaterThan(try config.localData().count, BlockingConfiguration.maximumProviderBytes)
        XCTAssertEqual(try BlockingConfiguration.decode(config.localData()), config)
    }

    func testInvalidCommittedRulesReplaceAnOpenPolicyWithClosedPolicy() throws {
        let config = try fullConfiguration()
        let valid = try config.providerData()
        let missing = BlockingListCatalog { _ in throw BlockingTransportError.missingResource }
        let corrupt = BlockingListCatalog { _ in Data("wrong.test".utf8) }
        let text = String(decoding: valid, as: UTF8.self)
        let wrongHash = Data(text.replacingOccurrences(of: BlockingListCatalog.rawDigests[.adult]!, with: String(repeating: "0", count: 64)).utf8)
        let wrongVersion = Data(text.replacingOccurrences(of: "\"version\":2", with: "\"version\":99").utf8)
        XCTAssertNotEqual(wrongVersion, valid)
        var missingSource = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        missingSource["sources"] = []
        let missingSourceData = try JSONSerialization.data(withJSONObject: missingSource)
        let candidates: [(Data?, BlockingListCatalog)] = [
            (nil, Self.catalog), (Data("corrupt".utf8), Self.catalog), (valid, missing),
            (valid, corrupt), (wrongHash, Self.catalog), (wrongVersion, Self.catalog), (missingSourceData, Self.catalog),
            (Data(repeating: 0, count: BlockingConfiguration.maximumProviderBytes + 1), Self.catalog)
        ]
        for (data, catalog) in candidates {
            var policy = try BlockingPolicy(data: valid, catalog: Self.catalog)
            XCTAssertFalse(policy.blocks(hostname: "allowed.test", outgoing: true))
            policy = BlockingPolicy(committedProviderData: data, catalog: catalog)
            XCTAssertTrue(policy.blocks(hostname: "allowed.test", outgoing: true))
            XCTAssertFalse(policy.blocks(hostname: "allowed.test", outgoing: false))
        }
    }
}
