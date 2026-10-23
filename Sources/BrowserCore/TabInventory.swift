import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// One open tab in a scriptable browser, addressed by window + tab index
/// (1-based, AppleScript numbering).
public struct BrowserTab: Equatable, Sendable, Identifiable, Codable,
                          Transferable {
    public let browser: BrowserKind
    public let window: Int
    public let index: Int
    public let url: String
    public let title: String
    public var id: String { "\(browser.rawValue)|\(window)|\(index)" }
    public var host: String { URL(string: url)?.host ?? url }

    public init(browser: BrowserKind, window: Int, index: Int,
                url: String, title: String) {
        self.browser = browser
        self.window = window
        self.index = index
        self.url = url
        self.title = title
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// Per-browser inventory state — an honest answer, not a fake empty list.
public enum TabSourceState: Equatable, Sendable {
    case tabs([BrowserTab])
    case notRunning
    case noWindows
    case needsConsent
    case unsupported
    case failed(String)
}

/// Enumerates open tabs using PID-addressed Apple events. Incognito windows
/// are filtered before any tab content is requested. Missing window-mode
/// support fails closed; positional tab actions refuse ambiguous processes.
/// Safari is handled by its native extension, which checks the page's
/// Private Browsing flag before sharing.
public enum TabInventory {
    public static func inventory() -> [(kind: BrowserKind, state: TabSourceState)] {
        // The signed sandbox permits Apple events to Chrome only. Keep this
        // list aligned with Support/Release.entitlements.
        [BrowserKind.chrome].compactMap { kind in
            guard BrowserOpener.appURL(for: kind) != nil else { return nil }
            return (kind, state(for: kind))
        }
    }

    public static func state(for kind: BrowserKind) -> TabSourceState {
        guard ChromiumCapture.supportedBundleIDs.contains(kind.bundleIdentifier) else { return .unsupported }
        do {
            let application = try BrowserProcess.application(bundleID: kind.bundleIdentifier)
            return state(for: kind, application: application)
        } catch BrowserProcess.Failure.notRunning { return .notRunning }
        catch BrowserProcess.Failure.ambiguous {
            return .failed("Multiple browser instances are running; bring the intended browser forward")
        } catch { return .failed("Automation couldn’t connect to this browser") }
    }

    static func state(for kind: BrowserKind, application: NSRunningApplication) -> TabSourceState {
        guard application.bundleIdentifier == kind.bundleIdentifier else {
            return .failed("The selected browser process changed")
        }
        do {
            let tabs = try ChromiumCapture(application: application).inventory(browser: kind)
            return tabs.isEmpty ? .noWindows : .tabs(tabs)
        } catch ChromiumCapture.Failure.needsConsent { return .needsConsent }
        catch { return .failed("Automation couldn’t read this browser’s tabs") }
    }

    /// Actively ask macOS for Automation consent to a browser — fires the
    /// system "wants to control" prompt when undecided. Returns true if the
    /// permission is already granted. A past denial won't re-prompt; the
    /// user must flip the toggle in System Settings.
    @discardableResult
    public static func requestConsent(for kind: BrowserKind) -> Bool {
        guard let application = try? BrowserProcess.application(bundleID: kind.bundleIdentifier) else {
            return false
        }
        let address = NSAppleEventDescriptor(processIdentifier: application.processIdentifier)
        return ChromiumCapture.permission(address: address, prompt: true) == noErr
    }

    public static func close(_ tab: BrowserTab) -> TabSourceState {
        guard BrowserProcess.permitsUnboundAction(bundleID: tab.browser.bundleIdentifier) else {
            return .failed("Tab actions are unavailable while browser instances are ambiguous")
        }
        return run("""
            tell application id "\(tab.browser.bundleIdentifier)"
                close tab \(tab.index) of window \(tab.window)
            end tell
            """)
    }

    public static func focus(_ tab: BrowserTab) -> TabSourceState {
        guard BrowserProcess.permitsUnboundAction(bundleID: tab.browser.bundleIdentifier) else {
            return .failed("Tab actions are unavailable while browser instances are ambiguous")
        }
        let raise = tab.browser == .safari
            ? """
                tell application id "\(tab.browser.bundleIdentifier)"
                    activate
                    try
                        set index of window \(tab.window) to 1
                    end try
                    set current tab of window \(tab.window)
                        to tab \(tab.index) of window \(tab.window)
                end tell
                """
            : """
                tell application id "\(tab.browser.bundleIdentifier)"
                    activate
                    try
                        set index of window \(tab.window) to 1
                    end try
                    set active tab index of window \(tab.window)
                        to \(tab.index)
                end tell
                """
        return run(raise)
    }

    private static func run(_ source: String) -> TabSourceState {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        guard let err else { return .tabs([]) }
        let code = err[NSAppleScript.errorNumber] as? Int
        if code == -1743 { return .needsConsent }
        return .failed(err[NSAppleScript.errorMessage] as? String
                       ?? "script error \(code ?? 0)")
    }

}
