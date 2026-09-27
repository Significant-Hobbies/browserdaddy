import XCTest
@testable import BrowserCore

final class FocusPrivacyTests: XCTestCase {
    func testUnavailableTabClosesPreviousURLWithoutAttributingMoreTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-focus-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArchiveStore(url: directory.appendingPathComponent("fixture.db"))
        let watcher = FocusWatcher(store: store)
        var visibleURLs: [String] = []
        watcher.onTick = { _, url in visibleURLs.append(url) }
        for _ in 0..<2 {
            watcher.recordCapture(app: "Chrome", url: "https://fixture.example/",
                                  title: "Public", dt: 2, active: true)
        }
        for _ in 0..<3 {
            watcher.recordCapture(app: "Chrome", url: "", title: "", dt: 2, active: true)
        }
        let rows = try store.db.query("SELECT url, title, active_s FROM focus ORDER BY id")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["url"]?.text, "https://fixture.example/")
        XCTAssertEqual(rows[0]["active_s"]?.double, 2)
        XCTAssertEqual(rows[1]["url"]?.text, "")
        XCTAssertEqual(rows[1]["title"]?.text, "")
        XCTAssertEqual(Array(visibleURLs.suffix(3)), ["", "", ""])
    }

    func testMissingFrontmostAppClosesSegmentWithoutWritingEmptyRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-gap-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArchiveStore(url: directory.appendingPathComponent("fixture.db"))
        let watcher = FocusWatcher(store: store)
        for _ in 0..<2 {
            watcher.recordCapture(app: "Chrome", url: "https://fixture.example/",
                                  title: "Public", dt: 2, active: true)
        }
        watcher.recordCapture(app: "", url: "", title: "", dt: 2, active: false)
        watcher.recordCapture(app: "", url: "", title: "", dt: 2, active: false)
        let rows = try store.db.query("SELECT app FROM focus ORDER BY id")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["app"]?.text, "Chrome")
    }

    /// Safari/Firefox can't prove window privacy state through AppleScript —
    /// they get no tab query at all (app-only focus).
    func testUnverifiableBrowsersNeverReceiveTabQuery() {
        for id in ["com.apple.Safari", "org.mozilla.firefox", "unknown.browser"] {
            XCTAssertNil(FocusWatcher.tabScript(bundleID: id), id)
        }
    }

    /// Every Chromium-family browser gets the same window-mode gate — the
    /// check must precede the tab read in each generated script.
    func testChromiumPrivacyGatePrecedesTabRead() throws {
        let chromium = [
            "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
            "com.operasoftware.Opera", "org.chromium.Chromium",
        ]
        for id in chromium {
            let script = try XCTUnwrap(FocusWatcher.tabScript(bundleID: id), id)
            XCTAssertTrue(script.contains("tell application id \"\(id)\""), id)
            let gate = try XCTUnwrap(
                script.range(of: "if (mode of captureWindow) is not \"normal\" then return \"\""), id)
            let read = try XCTUnwrap(
                script.range(of: "set captureTab to active tab of captureWindow"), id)
            XCTAssertLessThan(gate.lowerBound, read.lowerBound, id)
            XCTAssertNotNil(NSAppleScript(source: script), id)
        }
    }

    func testUnavailableOrMalformedCaptureNeverRetainsTabData() {
        for value in [nil, "", "private", "\u{1f}private title"] as [String?] {
            let result = FocusWatcher.decodeTab(value)
            XCTAssertEqual(result.0, "")
            XCTAssertEqual(result.1, "")
        }
        let result = FocusWatcher.decodeTab("https://fixture.example/\u{1f}Fixture")
        XCTAssertEqual(result.0, "https://fixture.example/")
        XCTAssertEqual(result.1, "Fixture")
    }
}
