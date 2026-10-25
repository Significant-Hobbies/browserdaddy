import AppKit
import CoreGraphics
import XCTest
@testable import BrowserCore

/// Opt-in, real-browser qualification. Ordinary CI never reads open tabs.
/// Normal mode uses one controlled tab in the already-front normal window.
/// Private and recovery inventory are withheld from owner browser windows.
@MainActor
final class PrivateWindowRuntimeTests: XCTestCase {
    private struct ForegroundPreflight {
        let selectedApplication: NSRunningApplication?
        let selectedPIDMatches: Bool
        let topWindowPIDMatches: Bool
        let frontWindowMatches: Bool
        let windowModeMatches: Bool
        let activeTabMatches: Bool
        let observedTopWindowPID: pid_t?
        let observedFrontWindowID: Int?

        init(selectedApplication: NSRunningApplication?,
             selectedPIDMatches: Bool,
             topWindowPIDMatches: Bool,
             frontWindowMatches: Bool,
             windowModeMatches: Bool = true,
             activeTabMatches: Bool = true,
             observedTopWindowPID: pid_t? = nil,
             observedFrontWindowID: Int? = nil) {
            self.selectedApplication = selectedApplication
            self.selectedPIDMatches = selectedPIDMatches
            self.topWindowPIDMatches = topWindowPIDMatches
            self.frontWindowMatches = frontWindowMatches
            self.windowModeMatches = windowModeMatches
            self.activeTabMatches = activeTabMatches
            self.observedTopWindowPID = observedTopWindowPID
            self.observedFrontWindowID = observedFrontWindowID
        }

        var failedPredicates: [String] {
            var failures: [String] = []
            if !selectedPIDMatches { failures.append("selectedApplicationPID") }
            if !topWindowPIDMatches { failures.append("topmostOrdinaryWindowPID") }
            if !frontWindowMatches { failures.append("controlledChromeFrontWindowID") }
            if !windowModeMatches { failures.append("controlledWindowNormalMode") }
            if !activeTabMatches { failures.append("controlledCanaryActiveTabID") }
            return failures
        }

        var isReady: Bool { failedPredicates.isEmpty }
    }

    private struct ControlledWindowState {
        let frontWindowID: Int
        let mode: String
        let activeTabID: String
        let activeTabIndex: Int
    }

    private struct ControlledCanaryTab {
        let windowID: Int
        let previousActiveTabID: String
        let previousActiveTabIndex: Int
        let canaryTabID: String
    }

    func testChromeWindowPrivacyAtTheActualCaptureBoundaries() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["BROWSERDADDY_PRIVACY_MODE"] else {
            throw XCTSkip("Real-browser qualification is opt-in; fixture tests are not runtime proof")
        }
        XCTAssertTrue(["normal", "private", "recovery"].contains(mode))
        guard ["normal", "private", "recovery"].contains(mode) else { return }
        guard mode == "normal" else {
            throw XCTSkip("This harness path is normal-only; private/recovery inventory is not read from owner windows")
        }
        let canary = "about:blank#browserdaddy-qualification-20261024"
        try runControlledNormalCanary(url: canary)
    }

    private func runControlledNormalCanary(url: String) throws {
        let bundleID = BrowserKind.chrome.bundleIdentifier
        guard BrowserProcess.permitsUnboundAction(bundleID: bundleID) else {
            XCTFail("Normal canary requires one regular Chrome process; no tab content read")
            return
        }
        let chrome = try BrowserProcess.application(bundleID: bundleID)
        do { _ = try ChromiumCapture(application: chrome) }
        catch ChromiumCapture.Failure.needsConsent {
            throw XCTSkip("Existing Chrome Automation consent is unavailable; no grant requested")
        }
        guard let selected = NSWorkspace.shared.frontmostApplication,
              selected.processIdentifier == chrome.processIdentifier,
              selected.bundleIdentifier == bundleID,
              topmostOrdinaryWindowPID() == chrome.processIdentifier else {
            XCTFail("Chrome must already own the frontmost ordinary window; no tab content read")
            return
        }
        guard let previous = frontWindowState(chrome: chrome),
              previous.mode == "normal",
              isSafeTabIdentifier(previous.activeTabID),
              previous.activeTabIndex > 0 else {
            XCTFail("Front Chrome window is not a safe normal-tab target; no tab content read")
            return
        }

        let initialPreflight = foregroundPreflight(chrome: chrome,
                                                   controlledWindowID: previous.frontWindowID,
                                                   expectedActiveTabID: previous.activeTabID)
        guard initialPreflight.isReady, initialPreflight.selectedApplication != nil else {
            reportPreflightFailure(initialPreflight, chrome: chrome,
                                   controlledWindowID: previous.frontWindowID,
                                   skippedCapture: "tab creation skipped; no tab content read")
            return
        }

        let canaryTabID: String
        do {
            guard let created = try createControlledCanaryTab(
                chrome: chrome,
                windowID: previous.frontWindowID,
                previousActiveTabID: previous.activeTabID,
                previousActiveTabIndex: previous.activeTabIndex,
                url: url
            ) else {
                XCTFail("Chrome front-tab state changed before canary creation; no tab content read")
                return
            }
            canaryTabID = created
        } catch let error as RuntimeProbeError {
            let failure = error.cleanupFailed
                ? "Canary tab setup failed and owned-tab cleanup could not be confirmed"
                : "Canary tab setup failed"
            XCTFail("\(failure); AppleScriptErrorNumber=\(error.number.map(String.init) ?? "unavailable"); no tab content read")
            return
        } catch {
            XCTFail("Canary tab setup failed; no tab content read")
            return
        }
        let canary = ControlledCanaryTab(windowID: previous.frontWindowID,
                                         previousActiveTabID: previous.activeTabID,
                                         previousActiveTabIndex: previous.activeTabIndex,
                                         canaryTabID: canaryTabID)
        defer { cleanupCanaryTab(canary, chrome: chrome) }

        // The disposable canary is assumed idle during this bounded check. OS
        // window metadata and subsequent browser AppleEvents cannot be sampled
        // atomically, so this normal-stage probe is not a complete privacy proof.
        let converged = waitForForegroundPreflight {
            foregroundPreflight(chrome: chrome,
                                controlledWindowID: canary.windowID,
                                expectedActiveTabID: canary.canaryTabID)
        }
        guard converged.isReady, converged.selectedApplication != nil else {
            reportPreflightFailure(converged, chrome: chrome,
                                   controlledWindowID: canary.windowID,
                                   skippedCapture: "capture skipped; no tab content read")
            return
        }

        let beforeFocusCapture = foregroundPreflight(chrome: chrome,
                                                    controlledWindowID: canary.windowID,
                                                    expectedActiveTabID: canary.canaryTabID)
        guard beforeFocusCapture.isReady, beforeFocusCapture.selectedApplication != nil else {
            reportPreflightFailure(beforeFocusCapture, chrome: chrome,
                                   controlledWindowID: canary.windowID,
                                   skippedCapture: "capture skipped; no tab content read")
            return
        }
        print("BrowserDaddy controlled normal tab canary gates: nativePID=true, topWindowPID=true, frontWindow=true, normalMode=true, canaryActive=true")
        let captured = FocusWatcher.browserTab(chrome)
        guard captured.0 == url else {
            XCTFail("Focused capture did not match the controlled canary; routing capture skipped; values omitted")
            return
        }

        let beforeRoutingCapture = foregroundPreflight(chrome: chrome,
                                                       controlledWindowID: canary.windowID,
                                                       expectedActiveTabID: canary.canaryTabID)
        guard beforeRoutingCapture.isReady,
              let frontmost = beforeRoutingCapture.selectedApplication else {
            reportPreflightFailure(beforeRoutingCapture, chrome: chrome,
                                   controlledWindowID: canary.windowID,
                                   skippedCapture: "routing capture skipped")
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

    private func frontWindowState(chrome: NSRunningApplication) -> ControlledWindowState? {
        guard isOriginalChromeProcessRunning(chrome) else {
            return nil
        }
        guard let result = try? runScript("""
        tell application id "com.google.Chrome"
            set controlledWindow to front window
            return ((id of front window) as text) & "|" & (mode of controlledWindow) & "|" & ((id of active tab of controlledWindow) as text) & "|" & ((active tab index of controlledWindow) as text)
        end tell
        """) else { return nil }
        return parseWindowState(result)
    }

    private func windowState(id: Int, chrome: NSRunningApplication) -> ControlledWindowState? {
        guard isOriginalChromeProcessRunning(chrome) else {
            return nil
        }
        guard let result = try? runScript("""
        tell application id "com.google.Chrome"
            set controlledWindow to window id \(id)
            return ((id of front window) as text) & "|" & (mode of controlledWindow) & "|" & ((id of active tab of controlledWindow) as text) & "|" & ((active tab index of controlledWindow) as text)
        end tell
        """) else { return nil }
        return parseWindowState(result)
    }

    private func parseWindowState(_ value: String) -> ControlledWindowState? {
        let fields = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4,
              let frontWindowID = Int(fields[0]),
              ["normal", "incognito"].contains(fields[1]),
              isSafeTabIdentifier(fields[2]),
              let activeTabIndex = Int(fields[3]), activeTabIndex > 0 else { return nil }
        return ControlledWindowState(frontWindowID: frontWindowID,
                                     mode: fields[1],
                                     activeTabID: fields[2],
                                     activeTabIndex: activeTabIndex)
    }

    private func createControlledCanaryTab(chrome: NSRunningApplication,
                                           windowID: Int,
                                           previousActiveTabID: String,
                                           previousActiveTabIndex: Int,
                                           url: String) throws -> String? {
        guard isOriginalChromeProcessRunning(chrome),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == chrome.processIdentifier,
              topmostOrdinaryWindowPID() == chrome.processIdentifier,
              isSafeTabIdentifier(previousActiveTabID), previousActiveTabIndex > 0 else {
            return nil
        }
        let result = try runScript("""
        tell application id "com.google.Chrome"
            set controlledWindow to window id \(windowID)
            if ((id of front window) as text) is not "\(windowID)" then return "front-changed"
            if (mode of controlledWindow) is not "normal" then return "not-normal"
            if ((id of active tab of controlledWindow) as text) is not "\(previousActiveTabID)" then return "owner-changed"
            if ((active tab index of controlledWindow) as integer) is not \(previousActiveTabIndex) then return "owner-changed"
            set controlledTab to make new tab at end of tabs of controlledWindow
            set validatedTabID to ""
            try
                set controlledTabID to (id of controlledTab) as text
                set checkedTabID to controlledTabID as integer
                set validatedTabID to checkedTabID as text
                set URL of controlledTab to "\(url)"
                set active tab index of controlledWindow to (count of tabs of controlledWindow)
                return "created|" & (checkedTabID as text)
            on error errorMessage number errorNumber
                try
                    close controlledTab
                    return "setup-failed|" & (errorNumber as text)
                on error closeMessage number closeErrorNumber
                    return "cleanup-failed|" & (errorNumber as text) & "|" & (closeErrorNumber as text) & "|" & validatedTabID
                end try
            end try
        end tell
        """)
        let fields = result.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if fields.first == "front-changed" || fields.first == "not-normal" || fields.first == "owner-changed" {
            return nil
        }
        if fields.first == "setup-failed" {
            let number = fields.count > 1 ? Int(fields[1]) : nil
            throw RuntimeProbeError.script(number: number)
        }
        if fields.first == "cleanup-failed" {
            let setupNumber = fields.count > 1 ? Int(fields[1]) : nil
            let cleanupNumber = fields.count > 2 ? Int(fields[2]) : nil
            guard fields.count == 4, isSafeTabIdentifier(fields[3]) else {
                throw RuntimeProbeError.cleanup(number: cleanupNumber ?? setupNumber)
            }
            let cleanup = closeCanaryTab(windowID: windowID, tabID: fields[3], chrome: chrome)
            guard cleanup.closed else {
                throw RuntimeProbeError.cleanup(number: cleanup.errorNumber ?? cleanupNumber ?? setupNumber)
            }
            throw RuntimeProbeError.script(number: setupNumber)
        }
        guard fields.count == 2, fields[0] == "created", isSafeTabIdentifier(fields[1]) else {
            throw RuntimeProbeError.script(number: nil)
        }
        return fields[1]
    }

    private func isSafeTabIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func shouldRestorePreviousSelection(originalProcessMatches: Bool,
                                                        exactWindowExists: Bool,
                                                        normalMode: Bool,
                                                        canaryTabID: String,
                                                        currentActiveTabID: String?,
                                                        previousTabID: String,
                                                        tabAtSavedIndex: String?) -> Bool {
        originalProcessMatches
            && exactWindowExists
            && normalMode
            && currentActiveTabID == canaryTabID
            && tabAtSavedIndex == previousTabID
    }

    func testCanaryCleanupRestoresOnlyWhenOwnerSelectionIsUnchanged() {
        XCTAssertTrue(Self.shouldRestorePreviousSelection(originalProcessMatches: true,
                                                           exactWindowExists: true,
                                                           normalMode: true,
                                                           canaryTabID: "30",
                                                           currentActiveTabID: "30",
                                                           previousTabID: "12",
                                                           tabAtSavedIndex: "12"),
                      "Restore the original selection in the same normal window even when Chrome is in the background")
        XCTAssertFalse(Self.shouldRestorePreviousSelection(originalProcessMatches: false,
                                                            exactWindowExists: true,
                                                            normalMode: true,
                                                            canaryTabID: "30",
                                                            currentActiveTabID: "30",
                                                            previousTabID: "12",
                                                            tabAtSavedIndex: "12"),
                       "Do not act on a replacement Chrome process with reused window or tab IDs")
        XCTAssertFalse(Self.shouldRestorePreviousSelection(originalProcessMatches: true,
                                                            exactWindowExists: true,
                                                            normalMode: true,
                                                            canaryTabID: "30",
                                                            currentActiveTabID: "44",
                                                            previousTabID: "12",
                                                            tabAtSavedIndex: "12"),
                       "Do not override a selection the owner changed")
        XCTAssertFalse(Self.shouldRestorePreviousSelection(originalProcessMatches: true,
                                                            exactWindowExists: true,
                                                            normalMode: true,
                                                            canaryTabID: "30",
                                                            currentActiveTabID: "30",
                                                            previousTabID: "12",
                                                            tabAtSavedIndex: "44"),
                       "Do not select a different tab after the owner reordered tabs")
    }

    private func readTabID(windowID: Int, index: Int, chrome: NSRunningApplication) -> String? {
        guard isOriginalChromeProcessRunning(chrome),
              index > 0 else { return nil }
        guard let id = try? runScript("""
        tell application id "com.google.Chrome"
            set controlledWindow to window id \(windowID)
            return (id of tab \(index) of controlledWindow) as text
        end tell
        """), isSafeTabIdentifier(id) else { return nil }
        return id
    }

    private func restorePriorSelection(_ canary: ControlledCanaryTab,
                                       chrome: NSRunningApplication) -> (restored: Bool, errorNumber: Int?) {
        guard isOriginalChromeProcessRunning(chrome) else {
            return (false, nil)
        }
        do {
            let result = try runScript("""
        tell application id "com.google.Chrome"
            set controlledWindow to window id \(canary.windowID)
            if (mode of controlledWindow) is not "normal" then return "not-normal"
            if ((id of active tab of controlledWindow) as text) is not "\(canary.canaryTabID)" then return "owner-changed"
            if ((id of tab \(canary.previousActiveTabIndex) of controlledWindow) as text) is not "\(canary.previousActiveTabID)" then return "tab-order-changed"
            set active tab index of controlledWindow to \(canary.previousActiveTabIndex)
            if ((id of active tab of controlledWindow) as text) is "\(canary.previousActiveTabID)" then return "restored"
            return "restore-failed"
        end tell
        """)
            return (result == "restored", nil)
        } catch let error as RuntimeProbeError {
            return (false, error.number)
        } catch {
            return (false, nil)
        }
    }

    private func closeCanaryTab(_ canary: ControlledCanaryTab,
                                chrome: NSRunningApplication) -> (closed: Bool, errorNumber: Int?) {
        closeCanaryTab(windowID: canary.windowID, tabID: canary.canaryTabID, chrome: chrome)
    }

    private func closeCanaryTab(windowID: Int,
                                tabID: String,
                                chrome: NSRunningApplication) -> (closed: Bool, errorNumber: Int?) {
        guard isOriginalChromeProcessRunning(chrome), isSafeTabIdentifier(tabID) else {
            return (false, nil)
        }
        do {
            let result = try runScript("""
        tell application id "com.google.Chrome"
            close tab id "\(tabID)" of window id \(windowID)
            return "closed"
        end tell
        """)
            return (result == "closed", nil)
        } catch let error as RuntimeProbeError {
            return (false, error.number)
        } catch {
            return (false, nil)
        }
    }

    private func cleanupCanaryTab(_ canary: ControlledCanaryTab,
                                  chrome: NSRunningApplication) {
        let state = windowState(id: canary.windowID, chrome: chrome)
        let processMatches = isOriginalChromeProcessRunning(chrome)
        let savedIndexMapsToPrevious = readTabID(windowID: canary.windowID,
                                                 index: canary.previousActiveTabIndex,
                                                 chrome: chrome)
            == canary.previousActiveTabID
        let restoreSelection = Self.shouldRestorePreviousSelection(
            originalProcessMatches: processMatches,
            exactWindowExists: state != nil,
            normalMode: state?.mode == "normal",
            canaryTabID: canary.canaryTabID,
            currentActiveTabID: state?.activeTabID,
            previousTabID: canary.previousActiveTabID,
            tabAtSavedIndex: savedIndexMapsToPrevious ? canary.previousActiveTabID : nil)
        let restoreResult = restoreSelection
            ? restorePriorSelection(canary, chrome: chrome)
            : (restored: false, errorNumber: Optional<Int>.none)
        let closed = closeCanaryTab(canary, chrome: chrome)
        XCTAssertTrue(closed.closed,
                      "Could not close only the controlled canary tab; AppleScriptErrorNumber=\(closed.errorNumber.map(String.init) ?? "unavailable")")
        if restoreSelection {
            XCTAssertTrue(restoreResult.restored,
                          "Prior selection could not be safely restored; AppleScriptErrorNumber=\(restoreResult.errorNumber.map(String.init) ?? "unavailable")")
            if restoreResult.restored {
                XCTAssertEqual(windowState(id: canary.windowID, chrome: chrome)?.activeTabID,
                               canary.previousActiveTabID,
                               "Prior active tab ID did not remain selected after canary cleanup")
            }
        }
    }

    private func isOriginalChromeProcessRunning(_ chrome: NSRunningApplication) -> Bool {
        guard !chrome.isTerminated,
              BrowserProcess.permitsUnboundAction(bundleID: BrowserKind.chrome.bundleIdentifier),
              let current = try? BrowserProcess.application(bundleID: BrowserKind.chrome.bundleIdentifier) else {
            return false
        }
        return current.processIdentifier == chrome.processIdentifier
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
        controlledWindowID: Int,
        expectedActiveTabID: String
    ) -> ForegroundPreflight {
        let selectedApplication = NSWorkspace.shared.frontmostApplication
        let topWindowPID = topmostOrdinaryWindowPID()
        let state = windowState(id: controlledWindowID, chrome: chrome)
        return ForegroundPreflight(
            selectedApplication: selectedApplication,
            selectedPIDMatches: selectedApplication?.processIdentifier == chrome.processIdentifier
                && selectedApplication?.bundleIdentifier == BrowserKind.chrome.bundleIdentifier,
            topWindowPIDMatches: topWindowPID == chrome.processIdentifier,
            frontWindowMatches: state?.frontWindowID == controlledWindowID,
            windowModeMatches: state?.mode == "normal",
            activeTabMatches: state?.activeTabID == expectedActiveTabID,
            observedTopWindowPID: topWindowPID,
            observedFrontWindowID: state?.frontWindowID
        )
    }

    private func reportPreflightFailure(_ preflight: ForegroundPreflight,
                                        chrome: NSRunningApplication,
                                        controlledWindowID: Int,
                                        skippedCapture: String) {
        let failures = preflight.failedPredicates.joined(separator: ",")
        let selectedPID = preflight.selectedApplication.map {
            String(describing: $0.processIdentifier)
        } ?? "none"
        let topWindowPID = preflight.observedTopWindowPID.map {
            String(describing: $0)
        } ?? "none"
        let frontWindowID = preflight.observedFrontWindowID.map {
            String(describing: $0)
        } ?? "none"
        XCTFail(
            "Native foreground preflight failed checks: \(failures); expectedPID=\(chrome.processIdentifier), observedSelectedPID=\(selectedPID), observedTopWindowPID=\(topWindowPID), expectedWindowID=\(controlledWindowID), observedFrontWindowID=\(frontWindowID); \(skippedCapture)"
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

    private func scriptInteger(_ source: String) throws -> Int {
        guard let value = try runScript(source).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").last,
              let integer = Int(value) else { throw RuntimeProbeError.script(number: nil) }
        return integer
    }

    private func runScript(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw RuntimeProbeError.script(number: nil)
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let value = result.stringValue else {
            let errorNumber = (error?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            throw RuntimeProbeError.script(number: errorNumber)
        }
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

    private enum RuntimeProbeError: Error {
        case script(number: Int?)
        case cleanup(number: Int?)

        var number: Int? {
            switch self {
            case let .script(number), let .cleanup(number): return number
            }
        }

        var cleanupFailed: Bool {
            if case .cleanup = self { return true }
            return false
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
