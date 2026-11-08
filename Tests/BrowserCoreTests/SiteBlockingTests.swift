import XCTest
@testable import BrowserCore

final class SiteBlockingTests: XCTestCase {
    private func host(_ value: String) -> BlockingHostname {
        BlockingHostname(value)!
    }

    func testExplicitRulesMatchDomainAndSubdomainsOnly() {
        let rules = SiteBlockingRules(blockedSites: [host("example.com")])
        XCTAssertEqual(rules.decision(for: "EXAMPLE.COM"), .blocked)
        XCTAssertEqual(rules.decision(for: "a.b.example.com"), .blocked)
        XCTAssertEqual(rules.decision(for: "notexample.com"), .unknown)
        XCTAssertEqual(rules.decision(for: "example.com.evil.test"), .unknown)
    }

    func testCategorySelectionAndUnknownAreDistinct() {
        let rules = SiteBlockingRules(
            blockedCategories: [.gambling],
            categorizedSites: [.adult: [host("adult.test")],
                               .gambling: [host("bet.test")]])
        XCTAssertEqual(rules.decision(for: "www.bet.test"), .blocked)
        XCTAssertEqual(rules.decision(for: "adult.test"), .allowed)
        XCTAssertEqual(rules.decision(for: "new.test"), .unknown)
    }

    func testExplicitAndOverlappingCategoryRulesBlock() {
        let rules = SiteBlockingRules(
            blockedSites: [host("adult.test")], blockedCategories: [.gambling],
            categorizedSites: [.adult: [host("overlap.test")],
                               .gambling: [host("overlap.test")]])
        XCTAssertEqual(rules.decision(for: "adult.test"), .blocked)
        XCTAssertEqual(rules.decision(for: "overlap.test"), .blocked)
    }

    func testInvalidOrNonHostnameInputsDoNotBecomeRules() {
        for input in ["", "localhost", "com", "example..com", ".example.com",
                      "example.com.", "-example.com", "example-.com",
                      "https://example.com", "example.com:443", "example.com/path",
                      "127.0.0.1", "user@example.com", "éxample.com", "K.com",
                      " example.com"] {
            XCTAssertNil(BlockingHostname(input), input)
        }
        XCTAssertEqual(BlockingHostname("XN--BCHER-KVA.example")?.value,
                       "xn--bcher-kva.example")
        let rules = SiteBlockingRules(blockedSites: [host("example.com")])
        XCTAssertEqual(rules.decision(for: "https://example.com"), .unknown)
    }

    func testDecodingCannotBypassValidation() throws {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(BlockingHostname.self,
            from: Data(#"{"value":"example.com/path"}"#.utf8)))
        let normalized = try decoder.decode(BlockingHostname.self,
            from: Data(#"{"value":"EXAMPLE.COM"}"#.utf8))
        XCTAssertEqual(normalized.value, "example.com")
    }
}
