import XCTest
@testable import BrowserCore

final class NavigationTreeTests: XCTestCase {
    private var directory: URL!
    private var store: ArchiveStore!
    private var source: HistorySource!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try ArchiveStore(url: directory.appendingPathComponent("archive.db"))
        source = HistorySource(browser: "chrome", profile: "Work",
                               path: directory, engine: .chromium)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func visit(_ id: Int64, parent: Int64? = nil,
                       title: String? = nil) -> HistoryVisit {
        HistoryVisit(browser: "chrome", profile: "Work", visitID: id,
                     url: "https://example.test/\(id)", title: title ?? "Page \(id)",
                     visitedAt: Date(timeIntervalSince1970: Double(id) * 60),
                     visitCount: 1, typedCount: 0, transition: "link",
                     fromVisit: parent)
    }

    func testBranchingShowsAncestorsAndSelectedDescendantsInOrder() throws {
        try store.merge(visits: [visit(1), visit(2, parent: 1),
                                 visit(3, parent: 2), visit(4, parent: 2),
                                 visit(5, parent: 4)], source: source)
        let tree = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 2))
        XCTAssertEqual(tree.nodes.map(\.visitID), [1, 2, 3, 4, 5])
        XCTAssertEqual(tree.nodes.map(\.depth), [0, 1, 2, 2, 3])
        XCTAssertEqual(tree.nodes.map(\.isSelected), [false, true, false, false, false])
        XCTAssertFalse(tree.cycleDetected)
        XCTAssertFalse(tree.truncated)
        XCTAssertNil(tree.missingParentID)
        XCTAssertEqual(try store.db.scalar("SELECT COUNT(*) FROM visits", as: { $0.int }), 5)
    }

    func testMissingParentStopsAtSavedVisitWithoutCrossingProfiles() throws {
        try store.merge(visits: [visit(20, parent: 99), visit(21, parent: 20)],
                        source: source)
        let other = HistorySource(browser: "chrome", profile: "Personal",
                                  path: directory, engine: .chromium)
        try store.merge(visits: [visit(99), visit(22, parent: 20)], source: other)
        let tree = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 20))
        XCTAssertEqual(tree.nodes.map(\.visitID), [20, 21])
        XCTAssertEqual(tree.missingParentID, 99)
        XCTAssertFalse(tree.cycleDetected)
    }

    func testCycleIsBoundedAndReported() throws {
        try store.merge(visits: [visit(30, parent: 31), visit(31, parent: 30),
                                 visit(32, parent: 30)], source: source)
        let tree = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 30))
        XCTAssertTrue(tree.cycleDetected)
        XCTAssertEqual(tree.nodes.map(\.visitID), [31, 30, 32])
        XCTAssertEqual(Set(tree.nodes.map(\.visitID)).count, tree.nodes.count)
    }

    func testSinglePageAndMissingSelectedVisit() throws {
        try store.merge(visits: [visit(40)], source: source)
        let tree = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 40))
        XCTAssertEqual(tree.nodes.map(\.visitID), [40])
        XCTAssertFalse(tree.cycleDetected)
        XCTAssertFalse(tree.truncated)
        XCTAssertNil(try store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 41))
    }
}
