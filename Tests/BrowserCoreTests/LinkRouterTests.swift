import XCTest
@testable import BrowserCore

final class LinkRouterTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: matching

    func testExactHostMatchesSubdomains() {
        let rule = RouteRule(pattern: "github.com",
                             target: LinkTarget(browser: .brave, profile: "Work"))
        XCTAssertTrue(RuleEngine.matches(rule.pattern, url: url("https://github.com/a/b")))
        XCTAssertTrue(RuleEngine.matches(rule.pattern, url: url("https://gist.github.com/x")))
        XCTAssertFalse(RuleEngine.matches(rule.pattern, url: url("https://notgithub.com/")))
        XCTAssertFalse(RuleEngine.matches(rule.pattern, url: url("https://github.com.evil.test/")))
    }

    func testHostGlob() {
        XCTAssertTrue(RuleEngine.matches("*.internal.*.dev",
            url: url("https://app.internal.corp.dev/")))
        XCTAssertFalse(RuleEngine.matches("*.internal.*.dev",
            url: url("https://internal.corp.dev/")))
        XCTAssertTrue(RuleEngine.matches("*youtube*",
            url: url("https://www.youtube.com/watch")))
    }

    func testSlashPatternMatchesWholeURL() {
        XCTAssertTrue(RuleEngine.matches("*github.com/*/pull/*",
            url: url("https://github.com/o/r/pull/123")))
        XCTAssertFalse(RuleEngine.matches("*github.com/*/pull/*",
            url: url("https://github.com/o/r/issues/1")))
    }

    /// A "host/path" pattern without a scheme or wildcard must still match —
    /// otherwise it's silently dead against https://-prefixed URLs.
    func testSlashPatternWithoutSchemeMatchesHostPath() {
        XCTAssertTrue(RuleEngine.matches("github.com/o/r/pull/*",
            url: url("https://github.com/o/r/pull/123")))
        XCTAssertTrue(RuleEngine.matches("github.com/o/r/pull/*",
            url: url("http://github.com/o/r/pull/123?x=1")))
        XCTAssertFalse(RuleEngine.matches("github.com/o/r/pull/*",
            url: url("https://github.com/o/r/issues/1")))
        XCTAssertFalse(RuleEngine.matches("github.com/o/r/pull/*",
            url: url("https://sub.github.com/o/r/pull/123")))
    }

    /// Query/fragment belong to the full-URL glob, not host+path — a bare
    /// path pattern must still hit a URL carrying a query.
    func testSlashPatternIgnoresQueryAndFragment() {
        XCTAssertTrue(RuleEngine.matches("github.com/pulls",
            url: url("https://github.com/pulls?tab=files")))
        XCTAssertTrue(RuleEngine.matches("github.com/pulls",
            url: url("https://github.com/pulls#top")))
        XCTAssertFalse(RuleEngine.matches("github.com/pulls",
            url: url("https://github.com/pullsxyz")))
    }

    func testMatchingIsCaseInsensitiveAndOrdered() {
        let rules = [
            RouteRule(pattern: "apple.com", target: LinkTarget(browser: .safari)),
            RouteRule(pattern: "*.APPLE.com", target: LinkTarget(browser: .chrome)),
        ]
        let hit = RuleEngine.match(url("https://Developer.APPLE.com/x"), rules: rules)
        XCTAssertEqual(hit?.target.browser, .safari)
    }

    func testNoMatchAndBlankPattern() {
        XCTAssertNil(RuleEngine.match(url("https://x.dev"),
            rules: [RouteRule(pattern: "github.com",
                              target: LinkTarget(browser: .chrome))]))
        XCTAssertFalse(RuleEngine.matches("  ", url: url("https://x.dev")))
    }

    // MARK: opener command line

    func testChromiumProfileArgv() {
        let argv = BrowserOpener.commandLine(
            url: url("https://a.dev"),
            target: LinkTarget(browser: .chrome, profile: "Profile 1"),
            foreground: false)
        XCTAssertEqual(argv, ["-g", "-n", "-b", "com.google.Chrome", "--args",
                              "--profile-directory=Profile 1", "https://a.dev"])
    }

    /// Non-profile targets use `-a <path>` — `-n` spawns a duplicate app
    /// instance per link and `-b` alone silently drops the URL. `-g` keeps
    /// the destination browser in the background (routed links must not
    /// steal focus).
    func testNoProfileArgv() {
        let argv = BrowserOpener.commandLine(
            url: url("https://a.dev"), target: LinkTarget(browser: .chrome),
            foreground: false)
        XCTAssertEqual(argv[0], "-g")
        XCTAssertEqual(argv[1], "-a")
        XCTAssertTrue(argv[2].hasSuffix("Google Chrome.app"))
        XCTAssertEqual(argv.last, "https://a.dev")
    }

    /// Foreground opens (explicit picks) drop `-g` so the chosen browser
    /// comes forward.
    func testForegroundArgvDropsBackgroundFlag() {
        let argv = BrowserOpener.commandLine(
            url: url("https://a.dev"), target: LinkTarget(browser: .chrome),
            foreground: true)
        XCTAssertFalse(argv.contains("-g"))
        XCTAssertEqual(argv[0], "-a")
        XCTAssertTrue(argv[1].hasSuffix("Google Chrome.app"))
        XCTAssertEqual(argv.last, "https://a.dev")
    }

    /// System apps resolve to a cryptex path `open` refuses — the
    /// /Applications stub is used instead.
    func testSafariUsesApplicationsStub() {
        let argv = BrowserOpener.commandLine(
            url: url("https://a.dev"),
            target: LinkTarget(browser: .safari, profile: "Work"),
            foreground: false)
        XCTAssertEqual(argv[0], "-g")
        XCTAssertEqual(argv[1], "-a")
        XCTAssertEqual(argv[2], "/Applications/Safari.app")
        XCTAssertEqual(argv.last, "https://a.dev")
    }

    // MARK: profile discovery

    func testChromiumProfilesFromLocalState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bd-localstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = """
            {"profile": {"info_cache": {
                "Profile 1": {"name": "Work"},
                "Default": {"name": "Personal"}
            }}}
            """
        try json.write(to: root.appendingPathComponent("Local State"),
                       atomically: true, encoding: .utf8)
        let profiles = ProfileDiscovery.chromiumProfiles(userDataRoot: root)
        XCTAssertEqual(profiles.map(\.directory), ["Default", "Profile 1"])
        XCTAssertEqual(profiles.map(\.name), ["Personal", "Work"])
    }

    func testChromiumProfilesMissingFile() {
        XCTAssertEqual(ProfileDiscovery.chromiumProfiles(
            userDataRoot: URL(fileURLWithPath: "/nonexistent")), [])
    }

    // MARK: config

    func testRouterConfigRoundTrip() throws {
        var cfg = RouterConfig()
        cfg.enabled = false
        cfg.fallback = LinkTarget(browser: .brave, profile: "Work")
        cfg.rules = [RouteRule(pattern: "github.com",
                               target: LinkTarget(browser: .chrome, profile: "Default"))]
        cfg.profiles = ["brave": ["Work", "Personal"]]
        let data = try JSONEncoder().encode(cfg)
        XCTAssertEqual(try JSONDecoder().decode(RouterConfig.self, from: data), cfg)
    }
}
