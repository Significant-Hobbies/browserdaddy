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

/// Enumerates and manipulates open tabs across scriptable browsers via
/// AppleScript. Incognito windows are filtered via the Chromium window mode
/// (verified on Chrome and Brave; requested for every Chromium-family sdef —
/// where `mode` is missing the script errors and the caller fails closed).
/// Safari is handled by its native extension, which checks the page's
/// Private Browsing flag before sharing.
public enum TabInventory {
    private static let fs = "\u{1f}"  // unit separator, same as FocusWatcher

    public static func inventory() -> [(kind: BrowserKind, state: TabSourceState)] {
        // The signed sandbox permits Apple events to Chrome only. Keep this
        // list aligned with Support/Release.entitlements.
        [BrowserKind.chrome].compactMap { kind in
            guard BrowserOpener.appURL(for: kind) != nil else { return nil }
            return (kind, state(for: kind))
        }
    }

    public static func state(for kind: BrowserKind) -> TabSourceState {
        guard let script = listScript(kind: kind) else { return .unsupported }
        guard let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: kind.bundleIdentifier).first else {
            return .notRunning
        }
        let address = NSAppleEventDescriptor(
            processIdentifier: runningApp.processIdentifier)
        let permission = withExtendedLifetime(address) {
            AEDeterminePermissionToAutomateTarget(
                address.aeDesc, AEEventClass(typeWildCard),
                AEEventID(typeWildCard), false)
        }
        if permission == errAEEventNotPermitted
            || permission == errAEEventWouldRequireUserConsent {
            return .needsConsent
        }
        guard permission == noErr else {
            return .failed("Automation couldn’t connect to this browser")
        }
        var err: NSDictionary?
        let raw = NSAppleScript(source: script)?
            .executeAndReturnError(&err).stringValue ?? ""
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int
            if code == -1743 { return .needsConsent }
            return .failed(err[NSAppleScript.errorMessage] as? String
                           ?? "script error \(code ?? 0)")
        }
        let tabs = parse(raw, browser: kind)
        return tabs.isEmpty ? .noWindows : .tabs(tabs)
    }

    /// Actively ask macOS for Automation consent to a browser — fires the
    /// system "wants to control" prompt when undecided. Returns true if the
    /// permission is already granted. A past denial won't re-prompt; the
    /// user must flip the toggle in System Settings.
    @discardableResult
    public static func requestConsent(for kind: BrowserKind) -> Bool {
        guard let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: kind.bundleIdentifier).first else { return false }
        let address = NSAppleEventDescriptor(
            processIdentifier: runningApp.processIdentifier)
        // Check the broad grant needed for tab enumeration, not just a
        // single Apple event that macOS may allow without consent.
        return withExtendedLifetime(address) {
            AEDeterminePermissionToAutomateTarget(
                address.aeDesc, AEEventClass(typeWildCard),
                AEEventID(typeWildCard), true) == noErr
        }
    }

    public static func close(_ tab: BrowserTab) -> TabSourceState {
        run("""
            tell application id "\(tab.browser.bundleIdentifier)"
                close tab \(tab.index) of window \(tab.window)
            end tell
            """)
    }

    public static func focus(_ tab: BrowserTab) -> TabSourceState {
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

    /// Rows of `window␟index␟url␟title` per line.
    private static func parse(_ raw: String, browser: BrowserKind) -> [BrowserTab] {
        raw.split(separator: "\n").compactMap { line in
            let f = line.split(separator: Character(fs), omittingEmptySubsequences: false)
            guard f.count >= 3,
                  let w = Int(f[0]), let t = Int(f[1]) else { return nil }
            let url = String(f[2])
            guard !url.isEmpty else { return nil }
            let title = f.count > 3 ? f[3...].joined(separator: fs) : ""
            return BrowserTab(browser: browser, window: w, index: t,
                              url: url, title: title)
        }
    }

    static func listScript(kind: BrowserKind) -> String? {
        let tabProps: String
        switch kind {
        case .safari: return nil
        case .firefox: return nil
        default:      tabProps = "(URL of tab t of window w) & s & (title of tab t of window w)"
        }
        let body = """
                    repeat with t from 1 to (count of tabs of window w)
                        try
                            set out to out & w & s & t & s & \(tabProps) & linefeed
                        end try
                    end repeat
            """
        // Every kind reaching this point is Chromium-family — its sdef
        // ships the window `mode` property, so anything that isn't normal
        // (incognito) is skipped. A dictionary without `mode` makes the
        // whole script error, which fails closed in `state(for:)`.
        let loop = """
            repeat with w from 1 to (count of windows)
                if (mode of window w) is "normal" then
        \(body)
                end if
            end repeat
        """
        return """
            tell application id "\(kind.bundleIdentifier)"
                set s to (ASCII character 31)
                set out to ""
            \(loop)
                return out
            end tell
            """
    }
}
