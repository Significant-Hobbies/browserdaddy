import AppKit
import XCTest
@testable import BrowserCore

/// Opt-in, real-browser qualification. Ordinary CI never reads open tabs.
/// The operator supplies a dedicated normal/private canary window through UI.
@MainActor
final class PrivateWindowRuntimeTests: XCTestCase {
    func testChromeWindowPrivacyAtTheActualCaptureBoundaries() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["BROWSERDADDY_PRIVACY_MODE"] else {
            throw XCTSkip("Real-browser qualification is opt-in; fixture tests are not runtime proof")
        }
        XCTAssertTrue(["normal", "private", "recovery"].contains(mode))
        guard ["normal", "private", "recovery"].contains(mode) else { return }
        let canary = "https://example.com/?browserdaddy-qualification=20261023"
        let chrome = try BrowserProcess.application(bundleID: BrowserKind.chrome.bundleIdentifier)
        let reader: ChromiumCapture
        do { reader = try ChromiumCapture(application: chrome) }
        catch ChromiumCapture.Failure.needsConsent {
            throw XCTSkip("Existing Chrome Automation consent is unavailable; no grant requested")
        }
        // Use the same selected GUI process at every capture boundary. Checking
        // window mode never asks for its URL or title.
        let windowMode = try reader.frontWindowMode() ?? "no-window"
        let expectedWindow = mode == "private" ? "incognito" : "normal"
        guard windowMode == expectedWindow else {
            XCTFail("Canary window type mismatch: \(windowMode); no URL or title read")
            return
        }
        let captured = FocusWatcher.browserTab(chrome)
        let routed = FrontmostTab.capture(frontmost: chrome)
        guard case let .tabs(tabs) = TabInventory.state(for: .chrome, application: chrome) else {
            XCTFail("Actual tab inventory did not complete; an empty/error response is not privacy proof")
            return
        }
        if mode == "private" {
            XCTAssertTrue(captured.0.isEmpty && captured.1.isEmpty,
                          "Private focus capture must contain neither URL nor title")
            XCTAssertTrue(routed == .unavailable(browser: .chrome),
                          "Private routing capture must be unavailable; values omitted")
            // The normal canary stays open behind the private window. Exactly
            // one copy proves inventory works while excluding its private twin.
            XCTAssertEqual(tabs.filter { $0.url == canary }.count, 1)
            try verifyNoCarryForward(capture: captured, canary: canary)
        } else {
            XCTAssertTrue(captured.0 == canary, "Normal canary mismatch; URLs deliberately omitted")
            switch routed {
            case let .url(browser, value):
                XCTAssertEqual(browser, .chrome)
                XCTAssertTrue(value == canary, "Routing canary mismatch; URLs deliberately omitted")
            default: XCTFail("The real normal-window routing capture was unavailable")
            }
            XCTAssertEqual(tabs.filter { $0.url == canary }.count, 1)
        }
    }

    private func verifyNoCarryForward(capture: (String, String), canary: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-runtime-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArchiveStore(url: directory.appendingPathComponent("fixture.db"))
        let watcher = FocusWatcher(store: store)
        for _ in 0..<2 {
            watcher.recordCapture(app: "Chrome", url: canary, title: "Canary", dt: 2, active: true)
        }
        for _ in 0..<3 {
            watcher.recordCapture(app: "Chrome", url: capture.0, title: capture.1, dt: 2, active: true)
        }
        let rows = try store.db.query("SELECT url, title, active_s FROM focus ORDER BY id")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.first?["url"]?.text == canary)
        XCTAssertEqual(rows.first?["active_s"]?.double, 2)
        XCTAssertEqual(rows.last?["url"]?.text, "")
        XCTAssertEqual(rows.last?["title"]?.text, "")
    }
}
