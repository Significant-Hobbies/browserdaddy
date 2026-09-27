import AppKit
import Foundation

/// Honest permission state — probe reality, don't assume.
public enum Permissions {
    public enum AutomationState: Sendable, Equatable {
        case granted, denied, notRunning, unknown
    }

    /// Per-browser Automation consent. Asks the AE permission API rather
    /// than running a probe script — a status check must not fire consent
    /// prompts just because the Permissions page opened. `scriptName` is
    /// unused today; kept as the display key callers store state under.
    public static func automationState(
        bundleID: String, scriptName _: String
    ) -> AutomationState {
        guard let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID).first else { return .notRunning }
        let address = NSAppleEventDescriptor(
            processIdentifier: running.processIdentifier)
        let status = withExtendedLifetime(address) {
            AEDeterminePermissionToAutomateTarget(
                address.aeDesc, AEEventClass(typeWildCard),
                AEEventID(typeWildCard), false)
        }
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        // Would-require-consent and everything else: undecided/unknown —
        // the UI's "Allow" button asks explicitly.
        default: return .unknown
        }
    }

    public static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
