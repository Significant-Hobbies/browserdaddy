import AppKit
import CoreGraphics
import Foundation

/// OS-level focus watcher. Polls the frontmost app every `interval` seconds;
/// when it's a scriptable browser, reads the active tab URL+title via
/// AppleScript. Writes compact focus segments into the archive — one row per
/// continuous (app, url) span, with `active_s` counting only ticks where the
/// machine wasn't idle.
///
/// Unknown/private tab state never carries forward a previous URL.
/// Poll gaps close segments; sub-tick blips are dropped.
public final class FocusWatcher: @unchecked Sendable {
    public static let interval: TimeInterval = 2.0
    public static let idleLimit: TimeInterval = 60
    public static let gapLimit: TimeInterval = 30

    /// bundleID → AppleScript application name.
    public static let scriptableBrowsers: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "company.thebrowser.Browser": "Arc",
        "com.operasoftware.Opera": "Opera",
        "org.chromium.Chromium": "Chromium",
        "com.apple.Safari": "Safari",
    ]

    public static var tabCapableBrowsers: [String: String] {
        scriptableBrowsers.filter { tabScript(bundleID: $0.key) != nil }
    }

    private let store: ArchiveStore
    private let queue = DispatchQueue(label: "browserdaddy.focus",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Held while watching so App Nap can't suspend the poll timer.
    private var activity: NSObjectProtocol?
    private var current: (id: Int64, app: String, url: String)?
    private var lastPoll = Date()
    public private(set) var isRunning = false
    /// Fires every poll with (frontmostApp, activeTabURL) — feeds "now" UI.
    public var onTick: ((String, String) -> Void)?
    public var onSegment: ((String, String) -> Void)?  // (app, url) for UI

    public init(store: ArchiveStore) { self.store = store }

    public func start() {
        guard timer == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Measuring frontmost app focus")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        isRunning = true
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRunning = false
        closeSegment()
    }

    private func poll() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastPoll), Self.gapLimit)
        if now.timeIntervalSince(lastPoll) > Self.gapLimit + Self.interval {
            closeSegment()  // slept / suspended — don't stretch the span
        }
        lastPoll = now

        guard let front = NSWorkspace.shared.frontmostApplication else {
            transition(to: "", url: "", title: "", dt: dt, active: false)
            return
        }
        let app = front.localizedName ?? front.bundleIdentifier ?? "unknown"
        let active = idleSeconds() < Self.idleLimit

        var url = "", title = ""
        if let bundleID = front.bundleIdentifier {
            (url, title) = browserTab(bundleID)
        }
        // An unavailable/private tab must close the previous URL immediately;
        // carrying it over would attribute private browsing to a public page.
        recordCapture(app: app, url: url, title: title, dt: dt, active: active)
    }

    /// Shared by native polling and fixture tests; never carries a missing URL forward.
    func recordCapture(app: String, url: String, title: String,
                       dt: TimeInterval, active: Bool) {
        transition(to: app, url: url, title: title, dt: dt, active: active)
        onTick?(app, url)
    }

    private func transition(to app: String, url: String, title: String,
                            dt: TimeInterval, active: Bool) {
        // No frontmost app is a gap, not an app — never write a "" row.
        guard !app.isEmpty else { closeSegment(); return }
        if current == nil {
            openSegment(app: app, url: url, title: title)
        } else if current!.app != app || current!.url != url {
            closeSegment()
            openSegment(app: app, url: url, title: title)
        } else {
            bump(dt: active ? dt : 0)
        }
    }

    private func openSegment(app: String, url: String, title: String) {
        let now = ISO8601.format(Date())
        do {
            try store.db.execute("""
                INSERT INTO focus (start_utc, end_utc, app, url, title)
                VALUES (?,?,?,?,?)
            """,
                [.text(now), .text(now), .text(app), .text(url), .text(title)])
            if let id = try store.db.scalar(
                "SELECT last_insert_rowid()", as: { $0.int }) {
                current = (id, app, url)
                onSegment?(app, url)
            }
        } catch {}
    }

    private func bump(dt: TimeInterval) {
        guard let id = current?.id else { return }
        _ = try? store.db.execute("""
            UPDATE focus SET end_utc=?, ticks=ticks+1, active_s=active_s+?
            WHERE id=?
        """,
            [.text(ISO8601.format(Date())), .double(dt), .int(id)])
    }

    private func closeSegment() {
        guard let id = current?.id else { return }
        // drop blips: segments that never survived one poll
        _ = try? store.db.execute("DELETE FROM focus WHERE id=? AND ticks=0",
                              [.int(id)])
        current = nil
    }

    private func idleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: UInt32.max)!
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyInput)
    }

    /// Chromium-family dictionaries expose an immutable normal/incognito
    /// window `mode`; where a browser's dictionary lacks it the script
    /// errors and the poll records app-only focus — a private URL is never
    /// carried into the archive.
    static func tabScript(bundleID: String) -> String? {
        let chromium: Set<String> = [
            "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
            "com.operasoftware.Opera", "org.chromium.Chromium",
        ]
        guard chromium.contains(bundleID) else { return nil }
        return """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set captureWindow to front window
                if (mode of captureWindow) is not "normal" then return ""
                set captureTab to active tab of captureWindow
                return (URL of captureTab) & (ASCII character 31) & (title of captureTab)
            end tell
            """
    }

    static func decodeTab(_ value: String?) -> (String, String) {
        guard let str = value, let sep = str.range(of: "\u{1f}"),
              !str[..<sep.lowerBound].isEmpty else { return ("", "") }
        return (String(str[..<sep.lowerBound]), String(str[sep.upperBound...]))
    }

    /// No tab is queried when privacy status cannot be verified.
    private func browserTab(_ bundleID: String) -> (String, String) {
        guard let source = Self.tabScript(bundleID: bundleID) else { return ("", "") }
        let script = NSAppleScript(source: source)
        var err: NSDictionary?
        let result = script?.executeAndReturnError(&err)
        guard err == nil else { return ("", "") }
        return Self.decodeTab(result?.stringValue)
    }
}
