import XCTest
@testable import BrowserCore

final class BlockingConfigurationTests: XCTestCase {
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

    func testBundledListsAreUsableAndNonempty() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BrowserDaddy/Resources/BlockingLists")
        for name in ["Adult", "Gambling"] {
            let contents = try String(contentsOf: root.appendingPathComponent(name + ".txt"), encoding: .utf8)
            XCTAssertGreaterThan(try BlockingConfiguration.parseList(contents).count, 100)
        }
    }
}
