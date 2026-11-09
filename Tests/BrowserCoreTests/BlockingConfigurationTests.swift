import XCTest
@testable import BrowserCore

final class BlockingConfigurationTests: XCTestCase {
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
        XCTAssertEqual(try BlockingConfiguration.decode(config.providerData()), config)
    }

    func testLegacyConfigurationDoesNotEnableStrictModeImplicitly() throws {
        let current = try BlockingConfiguration().providerData()
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
        XCTAssertEqual(try BlockingConfiguration.decode(payload), config)
        XCTAssertEqual(try BlockingConfiguration.decode(payload).rules.decision(for: "www.bet.test"), .blocked)
        XCTAssertThrowsError(try BlockingConfiguration.decode(Data(repeating: 0, count: BlockingConfiguration.maximumProviderBytes + 1)))
        XCTAssertThrowsError(try BlockingConfiguration.decode(Data("{}".utf8)))
    }

    func testBundledListsAreUsableAndNonempty() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BrowserDaddy/Resources/BlockingLists")
        var config = BlockingConfiguration()
        for name in ["Adult", "Gambling"] {
            let contents = try String(contentsOf: root.appendingPathComponent(name + ".txt"), encoding: .utf8)
            let hosts = try BlockingConfiguration.parseList(contents)
            XCTAssertGreaterThan(hosts.count, 100)
            config.lists[name == "Adult" ? .adult : .gambling] = hosts
        }
        XCTAssertLessThan(try config.providerData().count, BlockingConfiguration.maximumProviderBytes)
    }
}
