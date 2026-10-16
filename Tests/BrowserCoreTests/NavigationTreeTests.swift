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

    func testExactDescendantLimitIsCompleteButNextVisitIsTruncated() throws {
        let children = (2...252).map { visit(Int64($0), parent: 1) }
        try store.merge(visits: [visit(1)] + children, source: source)

        let overLimit = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 1))
        XCTAssertEqual(overLimit.nodes.count, 251)
        XCTAssertTrue(overLimit.truncated)

        try store.db.execute("DELETE FROM visits WHERE visit_id = 252")
        let exactLimit = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 1))
        XCTAssertEqual(exactLimit.nodes.count, 251)
        XCTAssertFalse(exactLimit.truncated)
    }

    func testDepthLimitDisclosesOnlyARealOmittedChild() throws {
        let chain = (1...34).map { id in
            visit(Int64(id), parent: id == 1 ? nil : Int64(id - 1))
        }
        try store.merge(visits: chain, source: source)

        let tooDeep = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 1))
        XCTAssertEqual(tooDeep.nodes.map(\.visitID), Array(Int64(1)...Int64(33)))
        XCTAssertTrue(tooDeep.truncated)

        try store.db.execute("DELETE FROM visits WHERE visit_id = 34")
        let exactDepth = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 1))
        XCTAssertEqual(exactDepth.nodes.count, 33)
        XCTAssertFalse(exactDepth.truncated)
    }

    func testAncestorLimitStopsBeforeSixtyFifthVisit() throws {
        let chain = (1...65).map { id in
            visit(Int64(id), parent: id == 1 ? nil : Int64(id - 1))
        }
        try store.merge(visits: chain, source: source)

        let tooLong = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 65))
        XCTAssertEqual(tooLong.nodes.first?.visitID, 2)
        XCTAssertEqual(tooLong.nodes.count, 64)
        XCTAssertTrue(tooLong.truncated)

        let exactLimit = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 64))
        XCTAssertEqual(exactLimit.nodes.first?.visitID, 1)
        XCTAssertEqual(exactLimit.nodes.count, 65) // visit 65 is a downstream child
        XCTAssertFalse(exactLimit.truncated)
    }

    func testZeroAndMalformedIdentifiersCannotCreateLinks() throws {
        try store.merge(visits: [visit(0), visit(1, parent: 0),
                                 visit(2, parent: 1)], source: source)
        try store.db.execute("""
            INSERT INTO visits (browser, profile, visit_id, from_visit, url, title)
            VALUES ('chrome', 'Work', 'bad-id', 1, 'https://example.test/bad', 'Bad')
        """)
        try store.db.execute("""
            INSERT INTO visits (browser, profile, visit_id, from_visit, url, title)
            VALUES ('chrome', 'Work', 3, 'bad-parent', 'https://example.test/3', 'Three')
        """)

        XCTAssertNil(try store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 0))
        let root = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 1))
        XCTAssertEqual(root.nodes.map(\.visitID), [1, 2])
        XCTAssertNil(root.nodes.first?.parentID)

        let orphan = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 3))
        XCTAssertEqual(orphan.nodes.map(\.visitID), [3])
        XCTAssertNil(orphan.nodes.first?.parentID)
    }

    func testDeletedIntermediateVisitDoesNotInventAConnection() throws {
        try store.merge(visits: [visit(1), visit(2, parent: 1),
                                 visit(3, parent: 2)], source: source)
        try store.db.execute("DELETE FROM visits WHERE visit_id = 2")

        let child = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 3))
        XCTAssertEqual(child.nodes.map(\.visitID), [3])
        XCTAssertEqual(child.missingParentID, 2)
        let root = try XCTUnwrap(store.navigationTree(
            browser: "chrome", profile: "Work", visitID: 1))
        XCTAssertEqual(root.nodes.map(\.visitID), [1])
    }
}
