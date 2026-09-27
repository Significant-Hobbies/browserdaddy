import XCTest
@testable import BrowserCore

final class ArchiveTests: XCTestCase {
    private var tmp: URL!
    private var store: ArchiveStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        store = try ArchiveStore(url: tmp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func visit(_ id: Int64, url: String = "https://a.example/")
        -> HistoryVisit {
        HistoryVisit(browser: "chrome", profile: "Default", visitID: id,
                     url: url, title: "t", visitedAt: Date(),
                     visitCount: 1, typedCount: 0,
                     transition: "link", fromVisit: nil)
    }

    func testMergeDedupesOnVisitID() throws {
        let src = HistorySource(browser: "chrome", profile: "Default",
                                path: tmp, engine: .chromium)
        let first = try store.merge(visits: [visit(1), visit(2), visit(3)],
                                    source: src)
        XCTAssertEqual(first, 3)
        // re-merge same ids + one new: only the new one lands
        let second = try store.merge(
            visits: [visit(1), visit(2), visit(4)], source: src)
        XCTAssertEqual(second, 1)
        let total = try store.db.scalar("SELECT COUNT(*) FROM visits",
                                        as: { $0.int })
        XCTAssertEqual(total, 4)
    }

    func testSameVisitIDDifferentSourceKept() throws {
        let chrome = HistorySource(browser: "chrome", profile: "Default",
                                   path: tmp, engine: .chromium)
        let safari = HistorySource(browser: "safari", profile: "default",
                                   path: tmp, engine: .safari)
        try store.merge(visits: [visit(1)], source: chrome)
        let n = try store.merge(visits: [visit(1)], source: safari)
        XCTAssertEqual(n, 1)  // (browser, profile, visit_id) is the key
    }

    func testSearchDedupe() throws {
        let src = HistorySource(browser: "chrome", profile: "Default",
                                path: tmp, engine: .chromium)
        try store.merge(searches: [("q", "https://x/", "t")], source: src)
        let n = try store.merge(searches: [("q", "https://x/", "t")],
                                source: src)
        XCTAssertEqual(n, 0)
    }

    func testWriteTransactionRollsBackAndLeavesConnectionUsable() throws {
        XCTAssertThrowsError(try store.db.writeTransaction {
            try store.db.execute(
                "INSERT INTO meta (key, value) VALUES ('k','v')")
            throw DBError(message: "boom")
        })
        XCTAssertNil(try store.db.scalar(
            "SELECT value FROM meta WHERE key='k'", as: { $0.text }))
        // A failed body must not leave an open transaction — writes work.
        try store.db.execute(
            "INSERT INTO meta (key, value) VALUES ('k2','v2')")
        XCTAssertEqual(try store.db.scalar(
            "SELECT value FROM meta WHERE key='k2'", as: { $0.text }), "v2")
    }

    func testQuerySurfacesStepErrorsInsteadOfTruncating() throws {
        // A prepare-time failure must throw (previously any non-ROW step
        // result silently ended the loop).
        XCTAssertThrowsError(try store.db.query("SELECT nope FROM visits"))
    }

    func testHistoryFiltersComposeAndExposeEffectiveTagProvenance() throws {
        let chrome = HistorySource(browser: "chrome", profile: "Work",
                                   path: tmp, engine: .chromium)
        let safari = HistorySource(browser: "safari", profile: "Personal",
                                   path: tmp, engine: .safari)
        let now = Date()
        try store.merge(visits: [
            HistoryVisit(browser: "chrome", profile: "Work", visitID: 10,
                         url: "https://docs.example.dev/guide", title: "Swift guide",
                         visitedAt: now, visitCount: 1, typedCount: 0,
                         transition: "link", fromVisit: nil),
            HistoryVisit(browser: "chrome", profile: "Work", visitID: 11,
                         url: "https://plain.example.dev/", title: "Plain",
                         visitedAt: now, visitCount: 1, typedCount: 0,
                         transition: "link", fromVisit: nil),
        ], source: chrome)
        try store.merge(visits: [
            HistoryVisit(browser: "safari", profile: "Personal", visitID: 12,
                         url: "https://news.example/", title: "Old news",
                         visitedAt: now.addingTimeInterval(-120 * 86_400),
                         visitCount: 1, typedCount: 0,
                         transition: "link", fromVisit: nil),
        ], source: safari)
        try store.setDomainCategory("docs.example.dev", "documentation")
        try store.setPageCategory("https://docs.example.dev/guide", "programming")
        let engine = ReportEngine(store: store)

        let manual = try engine.searchHistory(.init(
            term: "Swift", browser: "chrome", source: "chrome/Work",
            sinceDays: 7, category: "programming", tag: .manual))
        XCTAssertEqual(manual.count, 1)
        XCTAssertEqual(manual[0].host, "docs.example.dev")
        XCTAssertEqual(manual[0].category, "programming")
        XCTAssertEqual(manual[0].tagSource, "user")
        XCTAssertEqual(manual[0].tagScope, "page")
        XCTAssertEqual(manual[0].pageCategory, "programming")
        XCTAssertEqual(manual[0].domainCategory, "documentation")

        let untagged = try engine.searchHistory(.init(tag: .untagged))
        XCTAssertEqual(untagged.map(\.url), ["https://plain.example.dev/", "https://news.example/"])
        XCTAssertEqual(try engine.historySources(), ["chrome/Work", "safari/Personal"])
        XCTAssertEqual(try engine.historyCategories(), ["documentation", "programming"])
    }

    func testClearingPageDomainAndRollupTagsDoesNotTouchVisits() throws {
        let source = HistorySource(browser: "chrome", profile: "Default",
                                   path: tmp, engine: .chromium)
        try store.merge(visits: [
            visit(20, url: "https://www.example.com/a"),
            visit(21, url: "https://docs.example.com/b"),
        ], source: source)
        try store.setRollupCategory("example.com", "documentation")
        try store.setPageCategory("https://www.example.com/a", "programming")
        try store.clearPageCategory("https://www.example.com/a")
        XCTAssertEqual(try ReportEngine(store: store).searchHistory(
            .init(term: "www.example.com")).first?.category, "documentation")
        try store.clearDomainCategory("www.example.com")
        XCTAssertNil(try ReportEngine(store: store).searchHistory(
            .init(term: "www.example.com")).first?.category)
        try store.clearRollupCategory("example.com")
        XCTAssertTrue(try ReportEngine(store: store).searchHistory(
            .init(tag: .tagged)).isEmpty)
        XCTAssertEqual(try store.db.scalar("SELECT COUNT(*) FROM visits", as: { $0.int }), 2)
    }
}
