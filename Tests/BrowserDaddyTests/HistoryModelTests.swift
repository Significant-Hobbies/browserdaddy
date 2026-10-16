import BrowserCore
@testable import BrowserDaddy
import XCTest

@MainActor
final class HistoryModelTests: XCTestCase {
    func testLocalRetagScopesAndClearNeverRequireClassifierConsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-history-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArchiveStore(url: directory.appendingPathComponent("fixture.db"))
        let source = HistorySource(browser: "chrome", profile: "Work",
                                   path: directory, engine: .chromium)
        let url = "https://docs.example.com/guide"
        try store.merge(visits: [
            HistoryVisit(browser: "chrome", profile: "Work", visitID: 1,
                         url: url, title: "Guide", visitedAt: Date(),
                         visitCount: 1, typedCount: 0, transition: "link", fromVisit: nil),
        ], source: source)
        let model = AppModel(store: store, startCollection: {})
        XCTAssertFalse(model.classifyOptin)
        let row = AppModel.HistoryRow(
            id: "chrome/Work/1", visitID: 1, time: Date(), browser: "chrome", profile: "Work",
            title: "Guide", url: url, host: "docs.example.com",
            category: nil, tagSource: nil, tagScope: nil,
            pageCategory: nil, pageTagSource: nil,
            domainCategory: nil, domainTagSource: nil
        )

        model.setHistoryTag(row, scope: .page, category: "programming")
        var result = try ReportEngine(store: store).searchHistory(.init(term: "Guide"))
        XCTAssertEqual(result.first?.category, "programming")
        XCTAssertEqual(result.first?.tagSource, "user")
        model.clearHistoryTag(row, scope: .page)
        result = try ReportEngine(store: store).searchHistory(.init(term: "Guide"))
        XCTAssertNil(result.first?.category)
        XCTAssertFalse(model.classifying)
    }

    func testHistoryFilterCountAndClearAreComplete() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-history-filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            store: try ArchiveStore(url: directory.appendingPathComponent("fixture.db")),
            startCollection: {}
        )
        model.browserFilter = "chrome"
        model.historySourceFilter = "chrome/Work"
        model.historyDaysFilter = 30
        model.historyCategoryFilter = "development"
        model.historyTagFilter = .manual
        XCTAssertEqual(model.historyActiveFilterCount, 5)
        model.clearHistoryFilters()
        XCTAssertEqual(model.historyActiveFilterCount, 0)
        XCTAssertEqual(model.browserFilter, "all")
        XCTAssertEqual(model.historySourceFilter, "all")
        XCTAssertEqual(model.historyCategoryFilter, "all")
        XCTAssertEqual(model.historyTagFilter, .all)
    }
}
