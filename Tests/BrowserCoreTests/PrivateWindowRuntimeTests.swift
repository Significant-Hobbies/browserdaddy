import AppKit
import CoreGraphics
import XCTest
@testable import BrowserCore

/// Opt-in, real-browser qualification. Ordinary CI never reads open tabs.
/// Normal mode creates and later closes one controlled canary window. Private
/// and recovery modes retain the operator-supplied window flow.
@MainActor
final class PrivateWindowRuntimeTests: XCTestCase {
    private struct ForegroundPreflight {
        let selectedApplication: NSRunningApplication?
        let selectedPIDMatches: Bool
        let topWindowPIDMatches: Bool
        let frontWindowMatches: Bool

        var failedPredicates: [String] {
            var failures: [String] = []
            if !selectedPIDMatches { failures.append("selectedApplicationPID") }
            if !topWindowPIDMatches { failures.append("topmostOrdinaryWindowPID") }
            if !frontWindowMatches { failures.append("controlledChromeFrontWindowID") }
            return failures
        }

        var isReady: Bool { failedPredicates.isEmpty }
    }

    func testChromeWindowPrivacyAtTheActualCaptureBoundaries() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["BROWSERDADDY_PRIVACY_MODE"] else {
            throw XCTSkip("Real-browser qualification is opt-in; fixture tests are not runtime proof")
        }
        XCTAssertTrue(["normal", "private", "recovery"].contains(mode))
        guard ["normal", "private", "recovery"].contains(mode) else { return }
        let canary = "about:blank#browserdaddy-qualification-20261024"
        if mode == "normal" {
            try runControlledNormalCanary(url: canary)
            return
        }

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
        }
    }

    private func runControlledNormalCanary(url: String) throws {
        let chrome = try BrowserProcess.application(bundleID: BrowserKind.chrome.bundleIdentifier)
        do { _ = try ChromiumCapture(application: chrome) }
        catch ChromiumCapture.Failure.needsConsent {
            throw XCTSkip("Existing Chrome Automation consent is unavailable; no grant requested")
        }
        let previousApplication = NSWorkspace.shared.frontmostApplication
        var previousChromeWindowID: Int?
        if previousApplication?.processIdentifier == chrome.processIdentifier {
            guard let id = try? scriptInteger(
                "tell application id \"com.google.Chrome\" to get id of front window") else {
                XCTFail("Could not preserve the previously frontmost Chrome window")
                return
            }
            previousChromeWindowID = id
        }

        // Create a window and retain its ID before setting its only tab to the
        // disposable URL. This probe never enumerates unrelated tabs.
        guard let controlledWindowID = try? createNormalWindow(), controlledWindowID > 0 else {
            XCTFail("Could not create the controlled normal canary window")
            return
        }
        print("BrowserDaddy controlled normal canary created: windowID=\(controlledWindowID)")
        defer {
            let closed = (try? closeWindow(controlledWindowID)) ?? false
            XCTAssertTrue(closed, "Could not close only the controlled canary window")
            if let previousApplication {
                if previousApplication.processIdentifier == chrome.processIdentifier,
                   let previousChromeWindowID {
                    _ = try? activateChromeWindow(previousChromeWindowID)
                } else {
                    _ = previousApplication.activate()
                }
            }
        }

        guard (try? prepareWindow(controlledWindowID, url: url)) == true else {
            XCTFail("Could not prepare one normal canary tab; values omitted")
            return
        }

        do {
            let capture = try ChromiumCapture(application: chrome)
            guard try capture.frontWindowMode() == "normal" else {
                XCTFail("Controlled front window was not confirmed normal; no tab content read")
                return
            }
        } catch {
            XCTFail("Controlled normal window mode was unavailable; no tab content read")
            return
        }

        let converged = waitForForegroundPreflight {
            foregroundPreflight(chrome: chrome, controlledWindowID: controlledWindowID)
        }
        guard converged.isReady, converged.selectedApplication != nil else {
            reportPreflightFailure(converged, skippedCapture: "capture skipped; no tab content read")
            return
        }

        // The disposable canary is assumed idle during this bounded check. OS
        // window metadata and subsequent browser AppleEvents cannot be sampled
        // atomically, so this normal-stage probe is not a complete privacy proof.
        let beforeFocusCapture = foregroundPreflight(chrome: chrome,
                                                    controlledWindowID: controlledWindowID)
        guard beforeFocusCapture.isReady, beforeFocusCapture.selectedApplication != nil else {
            reportPreflightFailure(beforeFocusCapture, skippedCapture: "capture skipped; no tab content read")
            return
        }
        print("BrowserDaddy controlled normal canary gates: nativePID=true, topWindowPID=true, frontWindow=true, oneTab=true")
        let captured = FocusWatcher.browserTab(chrome)
        guard captured.0 == url else {
            XCTFail("Focused capture did not match the controlled canary; routing capture skipped; values omitted")
            return
        }

        let beforeRoutingCapture = foregroundPreflight(chrome: chrome,
                                                       controlledWindowID: controlledWindowID)
        guard beforeRoutingCapture.isReady,
              let frontmost = beforeRoutingCapture.selectedApplication else {
            reportPreflightFailure(beforeRoutingCapture, skippedCapture: "routing capture skipped")
            return
        }
        let routed = FrontmostTab.capture(frontmost: frontmost)
        switch routed {
        case let .url(browser, value):
            XCTAssertTrue(browser == .chrome && value == url,
                          "Routing capture did not match the controlled canary; values omitted")
        default:
            XCTFail("Routing capture was unavailable for the controlled canary; values omitted")
        }
    }

    private func createNormalWindow() throws -> Int {
        try scriptInteger("""
        tell application id "com.google.Chrome"
            activate
            set controlledWindow to make new window with properties {mode:"normal"}
            return id of controlledWindow as text
        end tell
        """)
    }

    private func waitForForegroundPreflight(
        maxSamples: Int = 10,
        pollInterval: TimeInterval = 0.1,
        sample: () -> ForegroundPreflight,
        pause: (TimeInterval) -> Void = {
            RunLoop.current.run(until: Date().addingTimeInterval($0))
        }
    ) -> ForegroundPreflight {
        precondition(maxSamples > 0)
        var latest = sample()
        guard !latest.isReady else { return latest }

        for _ in 1..<maxSamples {
            pause(pollInterval)
            latest = sample()
            if latest.isReady { return latest }
        }
        return latest
    }

    private func foregroundPreflight(
        chrome: NSRunningApplication,
        controlledWindowID: Int
    ) -> ForegroundPreflight {
        let selectedApplication = NSWorkspace.shared.frontmostApplication
        return ForegroundPreflight(
            selectedApplication: selectedApplication,
            selectedPIDMatches: selectedApplication?.processIdentifier == chrome.processIdentifier
                && selectedApplication?.bundleIdentifier == BrowserKind.chrome.bundleIdentifier,
            topWindowPIDMatches: topmostOrdinaryWindowPID() == chrome.processIdentifier,
            frontWindowMatches: (try? scriptInteger(
                "tell application id \"com.google.Chrome\" to get id of front window")) == controlledWindowID
        )
    }

    private func reportPreflightFailure(_ preflight: ForegroundPreflight,
                                        skippedCapture: String) {
        let failures = preflight.failedPredicates.joined(separator: ",")
        XCTFail(
            "Native foreground preflight did not converge; failed metadata checks: \(failures); \(skippedCapture)"
        )
    }

    func testForegroundPreflightWaitsForMetadataConvergence() {
        let samples = [
            ForegroundPreflight(selectedApplication: nil, selectedPIDMatches: false,
                                topWindowPIDMatches: false, frontWindowMatches: true),
            ForegroundPreflight(selectedApplication: nil, selectedPIDMatches: true,
                                topWindowPIDMatches: true, frontWindowMatches: true),
        ]
        var sampleIndex = 0
        var pauses = 0

        let result = waitForForegroundPreflight(maxSamples: 3, sample: {
            defer { sampleIndex += 1 }
            return samples[sampleIndex]
        }, pause: { _ in pauses += 1 })

        XCTAssertTrue(result.isReady)
        XCTAssertEqual(sampleIndex, 2)
        XCTAssertEqual(pauses, 1)
    }

    func testForegroundPreflightReportsOnlyUnsatisfiedMetadataPredicates() {
        var sampleCount = 0
        let result = waitForForegroundPreflight(maxSamples: 2, sample: {
            sampleCount += 1
            return ForegroundPreflight(selectedApplication: nil, selectedPIDMatches: true,
                                       topWindowPIDMatches: false, frontWindowMatches: true)
        }, pause: { _ in })

        XCTAssertEqual(result.failedPredicates, ["topmostOrdinaryWindowPID"])
        XCTAssertEqual(sampleCount, 2)
    }

    private func prepareWindow(_ id: Int, url: String) throws -> Bool {
        let result = try runScript("""
        tell application id "com.google.Chrome"
            set controlledWindow to window id \(id)
            set URL of active tab of controlledWindow to "\(url)"
            set controlledTabCount to count of tabs of controlledWindow
            set controlledMode to mode of controlledWindow
            return (controlledTabCount as text) & ":" & controlledMode
        end tell
        """)
        return result == "1:normal"
    }

    private func closeWindow(_ id: Int) throws -> Bool {
        try runScript("""
        tell application id "com.google.Chrome"
            close window id \(id)
            return "closed"
        end tell
        """) == "closed"
    }

    private func activateChromeWindow(_ id: Int) throws -> Bool {
        try runScript("""
        tell application id "com.google.Chrome"
            activate
            set index of window id \(id) to 1
            return (id of front window) as text
        end tell
        """) == String(id)
    }

    private func scriptInteger(_ source: String) throws -> Int {
        guard let value = try runScript(source).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").last,
              let integer = Int(value) else { throw RuntimeProbeError.script }
        return integer
    }

    private func runScript(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else { throw RuntimeProbeError.script }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let value = result.stringValue else { throw RuntimeProbeError.script }
        return value
    }

    /// Reads only window-owner metadata. It deliberately never asks for window
    /// names, titles, URLs, images, history, or profile data.
    private func topmostOrdinaryWindowPID() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in list {
            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0,
                  let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
                continue
            }
            return ownerPID
        }
        return nil
    }

    private enum RuntimeProbeError: Error { case script }

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
