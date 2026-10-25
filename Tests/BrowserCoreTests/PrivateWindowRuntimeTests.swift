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
        let captureWindowMatches: Bool
        let windowModeMatches: Bool
        let activeTabMatches: Bool
        let observedTopWindowPID: pid_t?
        let observedCaptureWindowID: Int?

        init(selectedApplication: NSRunningApplication?,
             selectedPIDMatches: Bool,
             topWindowPIDMatches: Bool,
             captureWindowMatches: Bool,
             windowModeMatches: Bool = true,
             activeTabMatches: Bool = true,
             observedTopWindowPID: pid_t? = nil,
             observedCaptureWindowID: Int? = nil) {
            self.selectedApplication = selectedApplication
            self.selectedPIDMatches = selectedPIDMatches
            self.topWindowPIDMatches = topWindowPIDMatches
            self.captureWindowMatches = captureWindowMatches
            self.windowModeMatches = windowModeMatches
            self.activeTabMatches = activeTabMatches
            self.observedTopWindowPID = observedTopWindowPID
            self.observedCaptureWindowID = observedCaptureWindowID
        }

        var failedPredicates: [String] {
            var failures: [String] = []
            if !selectedPIDMatches { failures.append("selectedApplicationPID") }
            if !topWindowPIDMatches { failures.append("topmostOrdinaryWindowPID") }
            if !captureWindowMatches { failures.append("controlledChromeCaptureWindowID") }
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

    private struct ExternalMetadataGate {
        let processID: Int
        let selectedPID: Int
        let topWindowPID: Int?
        let firstWindowID: Int
        let mode: String
        let activeTabID: Int
    }

    private struct ExternalMetadataSnapshot {
        let application: NSRunningApplication
        let gate: ExternalMetadataGate
    }

    private enum ExternalMetadataFailure: Error {
        case needsConsent
        case unavailable
        case appleEvent(Int?)

        var errorNumber: Int? {
            if case let .appleEvent(number) = self { return number }
            return nil
        }
    }

    private static let externalCanaryURL = "about:blank#browserdaddy-external-normal-20261025"

    func testChromeWindowPrivacyAtTheActualCaptureBoundaries() throws {
        let environment = ProcessInfo.processInfo.environment
        if let phase = environment["BROWSERDADDY_EXTERNAL_CANARY_PHASE"] {
            guard environment["BROWSERDADDY_PRIVACY_MODE"] == "normal" else {
                XCTFail("External canary requires explicit normal mode")
                return
            }
            try runExternalNormalCanary(phase: phase, environment: environment)
            return
        }
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

    private func runExternalNormalCanary(phase: String, environment: [String: String]) throws {
        switch phase {
        case "identify":
            guard let expectedPID = Self.positiveInteger(environment["BROWSERDADDY_EXPECTED_PID"]),
                  let expectedTabID = Self.positiveInteger(environment["BROWSERDADDY_EXPECTED_TAB_ID"]) else {
                XCTFail("External identify requires positive expected PID and tab ID")
                return
            }
            do {
                let snapshot = try externalMetadataSnapshot(expectedProcessID: expectedPID)
                guard Self.matchesExternalCanary(snapshot.gate,
                                                 expectedPID: expectedPID,
                                                 expectedWindowID: snapshot.gate.firstWindowID,
                                                 expectedTabID: expectedTabID) else {
                    XCTFail("External identify metadata gate failed; values omitted")
                    return
                }
                print("BROWSERDADDY_EXTERNAL_CANARY pid=\(snapshot.gate.processID) windowID=\(snapshot.gate.firstWindowID) tabID=\(snapshot.gate.activeTabID)")
            } catch ExternalMetadataFailure.needsConsent {
                throw XCTSkip("Existing Chrome Automation consent is unavailable; no grant requested")
            } catch let error as ExternalMetadataFailure {
                XCTFail("External identify metadata read failed; AppleEventErrorNumber=\(error.errorNumber.map(String.init) ?? "unavailable")")
            }
        case "capture":
            guard let expectedPID = Self.positiveInteger(environment["BROWSERDADDY_EXPECTED_PID"]),
                  let expectedWindowID = Self.positiveInteger(environment["BROWSERDADDY_EXPECTED_WINDOW_ID"]),
                  let expectedTabID = Self.positiveInteger(environment["BROWSERDADDY_EXPECTED_TAB_ID"]) else {
                XCTFail("External capture requires positive expected PID, window ID, and tab ID")
                return
            }
            do {
                let beforeFocus = try externalMetadataSnapshot(expectedProcessID: expectedPID)
                guard Self.matchesExternalCanary(beforeFocus.gate,
                                                 expectedPID: expectedPID,
                                                 expectedWindowID: expectedWindowID,
                                                 expectedTabID: expectedTabID) else {
                    XCTFail("External capture metadata gate failed; focus capture skipped")
                    return
                }
                let captured = FocusWatcher.browserTab(beforeFocus.application)
                guard captured.0 == Self.externalCanaryURL else {
                    XCTFail("Focused capture did not match the fixed external canary; values omitted")
                    return
                }

                let beforeRouting = try externalMetadataSnapshot(expectedProcessID: expectedPID)
                guard Self.matchesExternalCanary(beforeRouting.gate,
                                                 expectedPID: expectedPID,
                                                 expectedWindowID: expectedWindowID,
                                                 expectedTabID: expectedTabID) else {
                    XCTFail("External routing metadata gate failed; routing capture skipped")
                    return
                }
                switch FrontmostTab.capture(frontmost: beforeRouting.application) {
                case let .url(browser, value):
                    XCTAssertTrue(browser == .chrome && value == Self.externalCanaryURL,
                                  "Routing capture did not match the fixed external canary; values omitted")
                default:
                    XCTFail("Routing capture was unavailable for the fixed external canary; values omitted")
                }
            } catch ExternalMetadataFailure.needsConsent {
                throw XCTSkip("Existing Chrome Automation consent is unavailable; no grant requested")
            } catch let error as ExternalMetadataFailure {
                XCTFail("External capture metadata read failed; AppleEventErrorNumber=\(error.errorNumber.map(String.init) ?? "unavailable"); content capture skipped")
            }
        default:
            XCTFail("Unknown external canary phase; no browser metadata read")
        }
    }

    private static func isSafeExternalMetadata(_ gate: ExternalMetadataGate) -> Bool {
        gate.processID > 0
            && gate.selectedPID == gate.processID
            && gate.topWindowPID == gate.processID
            && gate.firstWindowID > 0
            && gate.mode == "normal"
            && gate.activeTabID > 0
    }

    private static func matchesExternalCanary(_ gate: ExternalMetadataGate,
                                              expectedPID: Int,
                                              expectedWindowID: Int,
                                              expectedTabID: Int) -> Bool {
        isSafeExternalMetadata(gate)
            && gate.processID == expectedPID
            && gate.selectedPID == expectedPID
            && gate.topWindowPID == expectedPID
            && gate.firstWindowID == expectedWindowID
            && gate.activeTabID == expectedTabID
    }

    private static func positiveInteger(_ value: String?) -> Int? {
        guard let value,
              !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let integer = Int(value), integer > 0 else { return nil }
        return integer
    }

    private func externalMetadataSnapshot(expectedProcessID: Int) throws -> ExternalMetadataSnapshot {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated,
              application.activationPolicy == .regular,
              application.bundleIdentifier == BrowserKind.chrome.bundleIdentifier else {
            throw ExternalMetadataFailure.unavailable
        }
        let processID = Int(application.processIdentifier)
        let selectedPID = NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } ?? 0
        let topPID = topmostOrdinaryWindowPID().map(Int.init)
        guard processID > 0,
              processID == expectedProcessID,
              selectedPID == processID,
              topPID == processID else {
            throw ExternalMetadataFailure.unavailable
        }

        let reader: ChromiumCapture
        do {
            reader = try ChromiumCapture(application: application)
        } catch ChromiumCapture.Failure.needsConsent {
            throw ExternalMetadataFailure.needsConsent
        } catch {
            throw ExternalMetadataFailure.unavailable
        }

        let values = try externalMetadataValues(reader: reader, application: application)

        let selectedAfterRead = NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } ?? 0
        let topAfterRead = topmostOrdinaryWindowPID().map(Int.init)
        guard !application.isTerminated,
              selectedAfterRead == processID,
              topAfterRead == processID else {
            throw ExternalMetadataFailure.unavailable
        }
        return ExternalMetadataSnapshot(
            application: application,
            gate: ExternalMetadataGate(processID: processID, selectedPID: selectedPID,
                                       topWindowPID: topPID, firstWindowID: values.firstWindowID,
                                       mode: values.mode, activeTabID: values.activeTabID))
    }

    private struct ExternalMetadataValues {
        let firstWindowID: Int
        let mode: String
        let activeTabID: Int
    }

    private func externalMetadataValues(reader: ChromiumCapture,
                                        application: NSRunningApplication?,
                                        send: ChromiumCapture.Send? = nil) throws -> ExternalMetadataValues {
        let windowsSpecifier = try externalMetadataWindowsSpecifier()
        let windows = try pidBoundMetadataGet(windowsSpecifier, reader: reader,
                                              application: application, send: send)
        guard windows.descriptorType == typeAEList,
              windows.numberOfItems > 0,
              windows.numberOfItems <= 10_000,
              let firstWindowDescriptor = windows.atIndex(1),
              let firstWindowID = numericIdentifier(firstWindowDescriptor) else {
            throw ExternalMetadataFailure.unavailable
        }

        let remainingSpecifiers = try externalMetadataWindowSpecifiers(firstWindowDescriptor)
        let modeDescriptor = try pidBoundMetadataGet(remainingSpecifiers[0], reader: reader,
                                                     application: application, send: send)
        guard let mode = modeDescriptor.stringValue, mode == "normal" else {
            throw ExternalMetadataFailure.unavailable
        }

        let activeTabIDDescriptor = try pidBoundMetadataGet(remainingSpecifiers[1], reader: reader,
                                                           application: application, send: send)
        guard let activeTabID = numericIdentifier(activeTabIDDescriptor) else {
            throw ExternalMetadataFailure.unavailable
        }
        return ExternalMetadataValues(firstWindowID: firstWindowID, mode: mode, activeTabID: activeTabID)
    }

    private func externalMetadataWindowsSpecifier() throws -> NSAppleEventDescriptor {
        let allWindows = NSAppleEventDescriptor(enumCode: OSType(kAEAll))
        guard let allOrdinal = NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal,
                                                      data: allWindows.data) else {
            throw ExternalMetadataFailure.unavailable
        }
        let windows = try ChromiumCapture.object("cwin", form: formAbsolutePosition,
                                                  key: allOrdinal, container: .null())
        return try ChromiumCapture.property("ID  ", of: windows)
    }

    private func externalMetadataWindowSpecifiers(_ firstWindowID: NSAppleEventDescriptor) throws -> [NSAppleEventDescriptor] {
        let firstWindow = try ChromiumCapture.object("cwin", form: formUniqueID,
                                                      key: firstWindowID, container: .null())
        let activeTab = try ChromiumCapture.property("acTa", of: firstWindow)
        return [
            try ChromiumCapture.property("mode", of: firstWindow),
            try ChromiumCapture.property("ID  ", of: activeTab),
        ]
    }

    private func pidBoundMetadataGet(_ specifier: NSAppleEventDescriptor,
                                     reader: ChromiumCapture,
                                     application: NSRunningApplication?,
                                     send: ChromiumCapture.Send? = nil) throws -> NSAppleEventDescriptor {
        guard application.map({ !$0.isTerminated }) ?? true else {
            throw ExternalMetadataFailure.unavailable
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite),
                                           eventID: AEEventID(kAEGetData),
                                           targetDescriptor: reader.address,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(specifier, forKeyword: keyDirectObject)
        let reply: NSAppleEventDescriptor
        do {
            if let send {
                reply = try send(event, ChromiumCapture.sendOptions)
            } else {
                reply = try event.sendEvent(options: ChromiumCapture.sendOptions, timeout: 2)
            }
        } catch {
            throw ExternalMetadataFailure.appleEvent((error as NSError).code)
        }
        if let errorNumber = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value,
           errorNumber != 0 {
            throw ExternalMetadataFailure.appleEvent(Int(errorNumber))
        }
        guard let value = reply.paramDescriptor(forKeyword: keyDirectObject) else {
            throw ExternalMetadataFailure.unavailable
        }
        return value
    }

    private func numericIdentifier(_ descriptor: NSAppleEventDescriptor) -> Int? {
        if let text = descriptor.stringValue {
            return Self.positiveInteger(text)
        }
        guard descriptor.descriptorType == typeSInt32 else { return nil }
        let value = Int(descriptor.int32Value)
        return value > 0 ? value : nil
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
        return captureTargetState(chrome: chrome)
    }

    /// Uses the same first-window resolver as production capture. The only
    /// AppleScript value read here is the active tab's numeric position, needed
    /// to restore selection after closing the task-owned canary tab.
    private func captureTargetState(chrome: NSRunningApplication) -> ControlledWindowState? {
        guard let metadata = try? ChromiumCapture(application: chrome).activeTabMetadata(),
              metadata.mode == "normal",
              let activeTabID = metadata.activeTabID,
              let windowID = Int(metadata.windowID),
              isSafeTabIdentifier(activeTabID),
              let activeTabIndex = try? scriptInteger("""
              tell application id "com.google.Chrome"
                  set controlledWindow to window id \(windowID)
                  return (active tab index of controlledWindow) as text
              end tell
              """), activeTabIndex > 0 else { return nil }
        return ControlledWindowState(frontWindowID: windowID,
                                     mode: metadata.mode,
                                     activeTabID: activeTabID,
                                     activeTabIndex: activeTabIndex)
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

    func testExternalCanaryGatePinsProcessFirstWindowModeAndActiveTab() {
        let expectedPID = 1360
        let expectedWindowID = 1588750628
        let expectedTabID = 91
        let matching = ExternalMetadataGate(processID: expectedPID,
                                            selectedPID: expectedPID,
                                            topWindowPID: expectedPID,
                                            firstWindowID: expectedWindowID,
                                            mode: "normal",
                                            activeTabID: expectedTabID)
        XCTAssertTrue(Self.matchesExternalCanary(matching,
                                                 expectedPID: expectedPID,
                                                 expectedWindowID: expectedWindowID,
                                                 expectedTabID: expectedTabID))

        let mismatches = [
            ExternalMetadataGate(processID: expectedPID + 1, selectedPID: expectedPID,
                                 topWindowPID: expectedPID, firstWindowID: expectedWindowID,
                                 mode: "normal", activeTabID: expectedTabID),
            ExternalMetadataGate(processID: expectedPID, selectedPID: expectedPID + 1,
                                 topWindowPID: expectedPID, firstWindowID: expectedWindowID,
                                 mode: "normal", activeTabID: expectedTabID),
            ExternalMetadataGate(processID: expectedPID, selectedPID: expectedPID,
                                 topWindowPID: expectedPID + 1, firstWindowID: expectedWindowID,
                                 mode: "normal", activeTabID: expectedTabID),
            ExternalMetadataGate(processID: expectedPID, selectedPID: expectedPID,
                                 topWindowPID: expectedPID, firstWindowID: expectedWindowID + 1,
                                 mode: "normal", activeTabID: expectedTabID),
            ExternalMetadataGate(processID: expectedPID, selectedPID: expectedPID,
                                 topWindowPID: expectedPID, firstWindowID: expectedWindowID,
                                 mode: "incognito", activeTabID: expectedTabID),
            ExternalMetadataGate(processID: expectedPID, selectedPID: expectedPID,
                                 topWindowPID: expectedPID, firstWindowID: expectedWindowID,
                                 mode: "normal", activeTabID: expectedTabID + 1),
        ]
        for observation in mismatches {
            XCTAssertFalse(Self.matchesExternalCanary(observation,
                                                      expectedPID: expectedPID,
                                                      expectedWindowID: expectedWindowID,
                                                      expectedTabID: expectedTabID))
        }
    }

    func testExternalMetadataSenderReadsOnlyWindowIDModeAndActiveTabIDInOrder() throws {
        let expectedPID = pid_t(1360)
        let target = NSAppleEventDescriptor(processIdentifier: expectedPID)
        var events: [NSAppleEventDescriptor] = []
        let reader = try ChromiumCapture(processID: expectedPID, permission: { _ in noErr }, send: { _, _ in
            XCTFail("External metadata must use the injected sender")
            return self.externalReply(.null())
        })
        let values = try externalMetadataValues(reader: reader, application: nil, send: { event, options in
            events.append(event)
            XCTAssertTrue(options.contains(.waitForReply))
            XCTAssertTrue(options.contains(.neverInteract))
            XCTAssertNotEqual(options.rawValue & UInt(kAEDoNotPromptForUserConsent), 0)
            switch events.count {
            case 1: return self.externalReply(self.externalIDs([1588750628]))
            case 2: return self.externalReply(NSAppleEventDescriptor(string: "normal"))
            case 3: return self.externalReply(NSAppleEventDescriptor(int32: 91))
            default:
                XCTFail("Unexpected metadata request")
                return self.externalReply(.null())
            }
        })

        XCTAssertEqual(values.firstWindowID, 1588750628)
        XCTAssertEqual(values.mode, "normal")
        XCTAssertEqual(values.activeTabID, 91)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.eventClass), Array(repeating: AEEventClass(kAECoreSuite), count: 3))
        XCTAssertEqual(events.map(\.eventID), Array(repeating: AEEventID(kAEGetData), count: 3))
        XCTAssertEqual(events.map { $0.attributeDescriptor(forKeyword: keyAddressAttr)?.data },
                       Array(repeating: target.data, count: 3))

        let expectedProperties = ["ID  ", "mode", "ID  "]
        for (event, property) in zip(events, expectedProperties) {
            let specifier = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
            XCTAssertEqual(specifier.descriptorType, typeObjectSpecifier)
            let keyCode = try XCTUnwrap(specifier.forKeyword(AEKeyword(keyAEKeyData))).typeCodeValue
            XCTAssertEqual(Self.textCode(keyCode), property)
        }

        let modeSpecifier = try XCTUnwrap(events[1].paramDescriptor(forKeyword: keyDirectObject))
        let pinnedWindow = try XCTUnwrap(modeSpecifier.forKeyword(AEKeyword(keyAEContainer)))
        XCTAssertEqual(pinnedWindow.forKeyword(AEKeyword(keyAEKeyData))?.int32Value, 1588750628)
        let activeIDSpecifier = try XCTUnwrap(events[2].paramDescriptor(forKeyword: keyDirectObject))
        let activeTabSpecifier = try XCTUnwrap(activeIDSpecifier.forKeyword(AEKeyword(keyAEContainer)))
        XCTAssertEqual(activeTabSpecifier.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue,
                       ChromiumCapture.code("acTa"))
        XCTAssertEqual(activeTabSpecifier.forKeyword(AEKeyword(keyAEContainer))?.data, pinnedWindow.data)
    }

    private func externalReply(_ value: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEAnswer), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        reply.setParam(value, forKeyword: keyDirectObject)
        return reply
    }

    private func externalIDs(_ values: [Int32]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, value) in values.enumerated() {
            list.insert(NSAppleEventDescriptor(int32: value), at: index + 1)
        }
        return list
    }

    private static func textCode(_ value: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
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
        let metadata = try? ChromiumCapture(application: chrome).activeTabMetadata()
        return ForegroundPreflight(
            selectedApplication: selectedApplication,
            selectedPIDMatches: selectedApplication?.processIdentifier == chrome.processIdentifier
                && selectedApplication?.bundleIdentifier == BrowserKind.chrome.bundleIdentifier,
            topWindowPIDMatches: topWindowPID == chrome.processIdentifier,
            captureWindowMatches: metadata?.windowID == String(controlledWindowID),
            windowModeMatches: metadata?.mode == "normal",
            activeTabMatches: metadata?.activeTabID == expectedActiveTabID,
            observedTopWindowPID: topWindowPID,
            observedCaptureWindowID: metadata.flatMap { Int($0.windowID) }
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
        let captureWindowID = preflight.observedCaptureWindowID.map {
            String(describing: $0)
        } ?? "none"
        XCTFail(
            "Native foreground preflight failed checks: \(failures); expectedPID=\(chrome.processIdentifier), observedSelectedPID=\(selectedPID), observedTopWindowPID=\(topWindowPID), expectedWindowID=\(controlledWindowID), observedCaptureWindowID=\(captureWindowID); \(skippedCapture)"
        )
    }

    func testForegroundPreflightWaitsForMetadataConvergence() {
        let samples = [
            ForegroundPreflight(selectedApplication: nil, selectedPIDMatches: false,
                                topWindowPIDMatches: false, captureWindowMatches: true),
            ForegroundPreflight(selectedApplication: nil, selectedPIDMatches: true,
                                topWindowPIDMatches: true, captureWindowMatches: true),
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
                                       topWindowPIDMatches: false, captureWindowMatches: true)
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
