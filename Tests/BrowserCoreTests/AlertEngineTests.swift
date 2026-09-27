import XCTest
@testable import BrowserCore

final class AlertEngineTests: XCTestCase {
    private var directory: URL!
    private var store: ArchiveStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-alerts-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        store = try ArchiveStore(url: directory.appendingPathComponent("fixture.db"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func focus(_ app: String, _ url: String,
                       start: Date, end: Date,
                       ticks: Int64, active: Double) throws {
        try store.db.execute("""
            INSERT INTO focus (start_utc, end_utc, app, url, title, ticks, active_s)
            VALUES (?,?,?,?,?,?,?)
        """, [.text(ISO8601.format(start)), .text(ISO8601.format(end)),
              .text(app), .text(url), .text(""), .int(ticks), .double(active)])
    }

    private func engine(delivered: Deliveries) -> AlertEngine {
        let e = AlertEngine(store: store)
        e.deliver = { t, b in delivered.box.append((t, b)) }
        return e
    }

    private final class Deliveries {
        var box: [(String, String)] = []
    }

    func testDisabledConfigFiresNothing() throws {
        try focus("Safari", "", start: Date().addingTimeInterval(-300),
                  end: Date(), ticks: 150, active: 300)
        let d = Deliveries()
        engine(delivered: d).evaluate()
        XCTAssertTrue(d.box.isEmpty)
    }

    func testDailyCapFiresOnceAndPersistsAcrossRestart() throws {
        let d = Deliveries()
        let e = engine(delivered: d)
        var cfg = AlertConfig()
        cfg.enabled = true
        cfg.dailyMinutes = 1
        e.saveConfig(cfg)
        try focus("Safari", "", start: Date().addingTimeInterval(-300),
                  end: Date(), ticks: 150, active: 120)
        e.evaluate()
        XCTAssertEqual(d.box.count, 1)
        XCTAssertTrue(d.box[0].0.contains("cap") || d.box[0].0.contains("cap reached")
                      || d.box[0].1.contains("focused minutes"))
        e.evaluate()
        XCTAssertEqual(d.box.count, 1, "same rule must not re-fire the same day")
        // fresh engine = app restart; fired set persisted in the archive
        let d2 = Deliveries()
        engine(delivered: d2).evaluate()
        XCTAssertTrue(d2.box.isEmpty)
    }

    func testSiteCapMatchesOnlyThatHost() throws {
        let d = Deliveries()
        let e = engine(delivered: d)
        var cfg = AlertConfig()
        cfg.enabled = true
        cfg.siteCaps = ["fixture.example": 1, "other.example": 500]
        e.saveConfig(cfg)
        try focus("Google Chrome", "https://fixture.example/page",
                  start: Date().addingTimeInterval(-300),
                  end: Date(), ticks: 150, active: 90)
        e.evaluate()
        XCTAssertEqual(d.box.count, 1)
        XCTAssertTrue(d.box[0].1.contains("fixture.example"))
    }

    /// A cap on the registrable host must count subdomain focus rows —
    /// focus URLs record the literal host ("www.youtube.com"), and a
    /// "youtube.com" cap that only matched exactly would never fire.
    func testSiteCapCoversSubdomainsButNotLookalikes() throws {
        let d = Deliveries()
        let e = engine(delivered: d)
        var cfg = AlertConfig()
        cfg.enabled = true
        cfg.siteCaps = ["fixture.example": 1, "other.example": 1]
        e.saveConfig(cfg)
        try focus("Brave Browser", "https://www.fixture.example/page",
                  start: Date().addingTimeInterval(-300),
                  end: Date(), ticks: 150, active: 90)
        // Lookalike suffix must not count toward the cap.
        try focus("Brave Browser", "https://notfixture.example/page",
                  start: Date().addingTimeInterval(-600),
                  end: Date().addingTimeInterval(-400), ticks: 100, active: 120)
        try focus("Brave Browser", "https://another.example/page",
                  start: Date().addingTimeInterval(-900),
                  end: Date().addingTimeInterval(-800), ticks: 50, active: 60)
        e.evaluate()
        XCTAssertEqual(d.box.count, 1)
        XCTAssertTrue(d.box[0].1.contains("fixture.example"))
    }

    func testStreakFiresOnlyForStillOpenSegment() throws {
        let d = Deliveries()
        let e = engine(delivered: d)
        var cfg = AlertConfig()
        cfg.enabled = true
        cfg.streakMinutes = 10
        e.saveConfig(cfg)
        // closed segment long ago — not a live streak
        try focus("Google Chrome", "https://fixture.example/a",
                  start: Date().addingTimeInterval(-3600),
                  end: Date().addingTimeInterval(-1800),
                  ticks: 900, active: 500)
        e.evaluate()
        XCTAssertTrue(d.box.isEmpty)
        // open segment: end_utc still being bumped at poll cadence
        try focus("Google Chrome", "https://fixture.example/b",
                  start: Date().addingTimeInterval(-1500),
                  end: Date(), ticks: 750, active: 0)
        e.evaluate()
        XCTAssertEqual(d.box.count, 1)
        XCTAssertTrue(d.box[0].0.contains("Still on"))
        e.evaluate()
        XCTAssertEqual(d.box.count, 1, "one nudge per unbroken segment")
    }

    func testAgentSuspicionNeedsChurnWithoutInput() throws {
        let d = Deliveries()
        let e = engine(delivered: d)
        var cfg = AlertConfig()
        cfg.enabled = true
        cfg.agentMinutes = 1
        e.saveConfig(cfg)
        let base = Date().addingTimeInterval(-300)
        // 3 distinct Chrome tabs, 60s each, zero input — suspected agent drive
        for i in 0..<3 {
            try focus("Google Chrome", "https://agent\(i).example/",
                      start: base.addingTimeInterval(Double(i) * 60),
                      end: base.addingTimeInterval(Double(i) * 60 + 58),
                      ticks: 30, active: 0)
        }
        e.evaluate()
        XCTAssertEqual(d.box.count, 1)
        XCTAssertTrue(d.box[0].0.contains("Agent"))
    }

    func testAgentSuspicionRejectsSameURLAndInput() throws {
        let d = Deliveries()
        let e = engine(delivered: d)
        var cfg = AlertConfig()
        cfg.enabled = true
        cfg.agentMinutes = 1
        e.saveConfig(cfg)
        let base = Date().addingTimeInterval(-300)
        // same URL re-opened repeatedly — churn count stays 1
        for i in 0..<4 {
            try focus("Google Chrome", "https://fixture.example/same",
                      start: base.addingTimeInterval(Double(i) * 60),
                      end: base.addingTimeInterval(Double(i) * 60 + 58),
                      ticks: 30, active: 0)
        }
        e.evaluate()
        XCTAssertTrue(d.box.isEmpty)
        // real churn but active input — a human browsing fast
        for i in 0..<4 {
            try focus("Google Chrome", "https://human\(i).example/",
                      start: base.addingTimeInterval(400 + Double(i) * 60),
                      end: base.addingTimeInterval(400 + Double(i) * 60 + 58),
                      ticks: 30, active: 55)
        }
        e.evaluate()
        XCTAssertTrue(d.box.isEmpty)
    }

    func testConfigRoundTripsThroughMeta() throws {
        let e = engine(delivered: Deliveries())
        var cfg = AlertConfig()
        cfg.enabled = true
        cfg.dailyMinutes = 120
        cfg.streakMinutes = 25
        cfg.agentMinutes = 10
        cfg.siteCaps = ["a.example": 15]
        e.saveConfig(cfg)
        XCTAssertEqual(e.config(), cfg)
        XCTAssertEqual(AlertEngine(store: store).config(), cfg)
    }
}
