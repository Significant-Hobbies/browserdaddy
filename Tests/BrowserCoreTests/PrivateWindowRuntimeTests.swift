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
        guard Permissions.automationState(bundleID: BrowserKind.chrome.bundleIdentifier,
                                          scriptName: "Google Chrome") == .granted else {
            throw XCTSkip("Existing Chrome Automation consent is unavailable; no grant requested")
        }
        let chrome = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: BrowserKind.chrome.bundleIdentifier).first)
        // Qualify the browser capture kernels without claiming that the Mac
        // foreground poller, idle or sleep transitions were exercised.
        // Check the real window type without reading its private URL or title.
        let windowMode = try execute("""
            tell application id "com.google.Chrome"
                if (count of windows) is 0 then return "no-window"
                set candidate to front window
                if (mode of candidate) is "normal" then return "normal"
                if (mode of candidate) is "incognito" then return "incognito"
                return "unknown"
            end tell
            """)
        let expectedWindow = mode == "private" ? "incognito" : "normal"
        guard windowMode == expectedWindow else {
            XCTFail("Canary window type mismatch: \(windowMode); no URL or title read")
            return
        }
        let captured = FocusWatcher.decodeTab(try execute(try XCTUnwrap(
            FocusWatcher.tabScript(bundleID: BrowserKind.chrome.bundleIdentifier))))
        let routed = FrontmostTab.capture(frontmost: chrome)
        guard case let .tabs(tabs) = TabInventory.state(for: .chrome) else {
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

    private func execute(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "BrowserDaddyPrivacyQualification", code: 2)
        }
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            // Never dump Apple events, titles or URLs into test logs.
            throw NSError(domain: "BrowserDaddyPrivacyQualification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Native browser capture failed"])
        }
        return result.stringValue ?? ""
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
