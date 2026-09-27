import XCTest
@testable import BrowserCore

final class RealReportTests: XCTestCase {
    func testBuildOnSyntheticArchive() throws {
        // Never open or migrate the operator's real browsing archive in tests.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-report-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.db")
        let store = try ArchiveStore(url: url)
        let source = HistorySource(browser: "chrome", profile: "Fixture",
                                   path: url, engine: .chromium)
        let visits = (1...3).map { id in
            HistoryVisit(browser: "chrome", profile: "Fixture", visitID: Int64(id),
                         url: "https://fixture.example/page-\(id)", title: "Fixture",
                         visitedAt: Date(), visitCount: 1, typedCount: 0,
                         transition: "link", fromVisit: nil)
        }
        try store.merge(visits: visits, source: source)
        let r = try ReportEngine(store: store).build()
        XCTAssertEqual(r.totalVisits, 3)
        XCTAssertEqual(r.uniqueURLs, 3)
        XCTAssertEqual(r.uniqueDomains, 1)
        XCTAssertEqual(r.sources.count, 1)
        XCTAssertEqual(r.weeklySeries.reduce(0) { $0 + $1.count }, 3)
    }

    func testSingleActiveDayCountsAsAStreakOfOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-streak-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.db")
        let store = try ArchiveStore(url: url)
        let source = HistorySource(browser: "chrome", profile: "Fixture",
                                   path: url, engine: .chromium)
        // Two isolated days a week apart — longest streak is 1, gap is 6.
        let day = Date()
        try store.merge(visits: [
            HistoryVisit(browser: "chrome", profile: "Fixture", visitID: 1,
                         url: "https://a.example/", title: "A",
                         visitedAt: day, visitCount: 1, typedCount: 0,
                         transition: "link", fromVisit: nil),
            HistoryVisit(browser: "chrome", profile: "Fixture", visitID: 2,
                         url: "https://b.example/", title: "B",
                         visitedAt: day.addingTimeInterval(7 * 86_400),
                         visitCount: 1, typedCount: 0,
                         transition: "link", fromVisit: nil),
        ], source: source)
        let r = try ReportEngine(store: store).build()
        XCTAssertEqual(r.longestStreak, 1)
        XCTAssertEqual(r.longestGapDays, 6)
    }
}
