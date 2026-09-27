import AppKit
import Foundation

/// Where a routed link lands: a browser plus an optional Chromium profile
/// directory ("Default", "Profile 1"). Empty profile = the browser's own
/// default profile; Safari never carries a profile (macOS exposes none).
public struct LinkTarget: Codable, Equatable, Sendable, Hashable, Identifiable {
    public var browser: BrowserKind
    public var profile: String
    public var id: String { "\(browser.rawValue)|\(profile)" }
    public var label: String {
        profile.isEmpty ? browser.displayName
                        : "\(browser.displayName) · \(profile)"
    }

    public init(browser: BrowserKind, profile: String = "") {
        self.browser = browser
        self.profile = profile
    }
}

/// First-match rule. Pattern semantics (case-insensitive):
/// - contains "/" → glob against the full URL or host+path
///   ("*github.com/*/pull/*", "github.com/o/r/pull/*")
/// - contains "*" or "?" → glob against the host ("*.internal.*.dev")
/// - otherwise → host equals pattern, or is a subdomain of it
public struct RouteRule: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var pattern: String
    public var target: LinkTarget

    public init(pattern: String, target: LinkTarget) {
        self.pattern = pattern
        self.target = target
    }
}

public struct RouterConfig: Codable, Equatable, Sendable {
    /// Master switch — when off, everything goes to fallback unchanged.
    public var enabled = true
    /// Where unmatched (or disabled) links go. Safari: always installed,
    /// never BrowserDaddy itself — that would loop.
    public var fallback = LinkTarget(browser: .safari)
    public var rules: [RouteRule] = []
    /// Manually declared Chromium profile dirs per browser — merged with
    /// profiles discovered under connected browser roots.
    public var profiles: [String: [String]] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, fallback, rules, profiles
    }

    /// Tolerant decode — configs written before a field existed keep
    /// working (a dropped `clipboardWatch` key is simply ignored).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        fallback = try c.decodeIfPresent(LinkTarget.self, forKey: .fallback)
            ?? LinkTarget(browser: .safari)
        rules = try c.decodeIfPresent([RouteRule].self, forKey: .rules) ?? []
        profiles = try c.decodeIfPresent([String: [String]].self,
                                         forKey: .profiles) ?? [:]
    }
}

/// RouterConfig persistence — lives in the archive meta table like
/// alerts.config; no new files, no network.
public final class RouterStore: @unchecked Sendable {
    private let store: ArchiveStore
    public init(store: ArchiveStore) { self.store = store }

    public func config() -> RouterConfig {
        guard let raw = store.metaGet("router.config"),
              let data = raw.data(using: .utf8),
              let cfg = try? JSONDecoder().decode(RouterConfig.self, from: data)
        else { return RouterConfig() }
        return cfg
    }

    public func save(_ cfg: RouterConfig) {
        guard let data = try? JSONEncoder().encode(cfg),
              let raw = String(data: data, encoding: .utf8) else { return }
        store.metaSet("router.config", raw)
    }
}

public enum RuleEngine {
    public static func match(_ url: URL, rules: [RouteRule]) -> RouteRule? {
        rules.first { matches($0.pattern, url: url) }
    }

    public static func matches(_ pattern: String, url: URL) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return false }
        if p.contains("/") {
            let full = url.absoluteString.lowercased()
            // Patterns rarely carry a scheme ("github.com/*/pull/*") — also
            // glob host+path, or a scheme-less slash pattern can never
            // match ("^github\.com/…$" vs "https://github.com/…"). Query and
            // fragment stay out of host+path — "github.com/pulls" should
            // still hit "https://github.com/pulls?tab=x".
            let hostPath = ((url.host ?? "") + url.path).lowercased()
            return glob(p, full) || glob(p, hostPath)
        }
        guard let host = url.host?.lowercased() else { return false }
        if p.contains("*") || p.contains("?") { return glob(p, host) }
        return host == p || host.hasSuffix("." + p)
    }

    /// Tiny fnmatch: `*` any run, `?` one char, everything else literal.
    static func glob(_ pattern: String, _ value: String) -> Bool {
        var rx = "^"
        for ch in pattern {
            switch ch {
            case "*": rx += ".*"
            case "?": rx += "."
            default: rx += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        rx += "$"
        return value.range(of: rx, options: .regularExpression) != nil
    }
}

/// Opens a URL in a specific browser (+ Chromium profile) via `open` —
/// LaunchServices performs the launch, so the target browser never
/// inherits this app's sandbox.
public enum BrowserOpener {
    public enum Failure: LocalizedError, Equatable {
        case notInstalled(String)
        case openFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notInstalled(let b): "\(b) isn't installed."
            case .openFailed(let detail): detail
            }
        }

        /// `open` surfaces TCC/Gatekeeper denials through stderr — show the
        /// user a permission problem, not a raw launch error.
        public var isPermissionDenied: Bool {
            guard case .openFailed(let m) = self else { return false }
            let l = m.lowercased()
            return l.contains("permission") || l.contains("denied")
                || l.contains("-1743") || l.contains("not authorized")
        }
    }

    /// Chromium profile names accepted for --profile-directory.
    public static func supportsProfiles(_ kind: BrowserKind) -> Bool {
        switch kind {
        case .chrome, .brave, .edge, .vivaldi, .chromium, .opera: return true
        case .safari, .firefox, .arc: return false
        }
    }

    public static func appURL(for kind: BrowserKind) -> URL? {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: kind.bundleIdentifier)
    }

    /// argv passed to /usr/bin/open — pure, testable.
    ///
    /// `foreground` selects the mode: background opens carry `-g` — a link
    /// clicked in another app opens as a background tab without stealing
    /// focus. Explicit picks (hotkey picker, DnD "Send to") pass
    /// `foreground: true` so the chosen browser comes forward.
    ///
    /// Non-profile targets use `-a <path>`: delivers the GURL to the running
    /// instance as a normal tab. `-n` is deliberately avoided — it spawns a
    /// *duplicate app instance* per link (verified on macOS 15), and `-b`
    /// without `-n` activates the app but silently drops the URL.
    ///
    /// Profile targets need `-n -b --args`: Chromium ignores
    /// `--profile-directory` on an already-running instance, and `--args`
    /// only works with the bundle-ID form.
    ///
    /// Path wrinkle: `urlForApplication` returns cryptex locations for system
    /// apps (Safari) that `open` refuses — those resolve through the
    /// /Applications stub instead.
    public static func commandLine(url: URL, target: LinkTarget,
                                   foreground: Bool) -> [String] {
        let bid = target.browser.bundleIdentifier
        let wantProfile = supportsProfiles(target.browser)
            && !target.profile.isEmpty
        let g = foreground ? [] : ["-g"]
        if wantProfile {
            return g + ["-n", "-b", bid, "--args",
                        "--profile-directory=\(target.profile)",
                        url.absoluteString]
        }
        if let path = launchPath(for: target.browser) {
            return g + ["-a", path, url.absoluteString]
        }
        return g + ["-n", "-b", bid, url.absoluteString]
    }

    /// A launchable .app path — the /Applications stub for system apps whose
    /// real location is a cryptex `open` can't use.
    static func launchPath(for kind: BrowserKind) -> String? {
        guard let url = appURL(for: kind) else { return nil }
        let path = url.path
        guard path.contains("/Cryptexes/") else { return path }
        let stub = "/Applications/" + url.lastPathComponent
        return FileManager.default.fileExists(atPath: stub) ? stub : nil
    }

    /// `foreground` — the destination browser activates; the default is a
    /// background tab that leaves focus with the app the link came from.
    public static func open(_ url: URL, target: LinkTarget,
                            foreground: Bool = false) throws {
        guard appURL(for: target.browser) != nil else {
            throw Failure.notInstalled(target.browser.displayName)
        }
        let proc = Process()
        let err = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = commandLine(url: url, target: target,
                                   foreground: foreground)
        proc.standardError = err
        // Drain stderr while `open` runs — reading only after waitUntilExit
        // deadlocks if the write end fills the pipe buffer.
        final class ErrBox: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
        }
        let box = ErrBox()
        let reader = err.fileHandleForReading
        reader.readabilityHandler = { h in
            let chunk = h.availableData
            box.lock.withLock { box.data.append(chunk) }
        }
        try proc.run()
        proc.waitUntilExit()
        reader.readabilityHandler = nil
        box.lock.withLock { box.data.append(reader.readDataToEndOfFile()) }
        if proc.terminationStatus != 0 {
            let collected = box.lock.withLock { box.data }
            let msg = String(data: collected,
                             encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.openFailed(
                msg?.isEmpty == false ? msg!
                    : "open exited \(proc.terminationStatus)")
        }
        if foreground { activate(target.browser) }
    }

    /// Bring the target browser forward — profile launches use `-n`, which
    /// delivers the URL without activating the app.
    static func activate(_ kind: BrowserKind) {
        guard let url = appURL(for: kind) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: config) { _, _ in }
    }
}

/// A Chromium profile directory + display name (Local State info_cache).
public struct ChromiumProfile: Equatable, Sendable, Identifiable {
    public var id: String { directory }
    public let directory: String
    public let name: String
    public init(directory: String, name: String) {
        self.directory = directory
        self.name = name
    }
}

/// Reads "Local State" inside a user-connected browser root — never the
/// home directory implicitly. Discovery stays inside granted scopes.
public enum ProfileDiscovery {
    public static func chromiumProfiles(userDataRoot: URL) -> [ChromiumProfile] {
        let localState = userDataRoot.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]]
        else { return [] }
        return cache.keys.sorted().map { dir in
            ChromiumProfile(directory: dir,
                            name: cache[dir]?["name"] as? String ?? dir)
        }
    }
}

/// User-invoked "move this tab": reads the frontmost scriptable browser's
/// active-tab URL. Never logs — the URL only flows to the browser the
/// user picks. Incognito windows are filtered where detectable.
public enum FrontmostTab {
    public enum Result: Equatable {
        case notBrowser(app: String)
        case needsConsent(browser: BrowserKind)
        case unavailable(browser: BrowserKind)
        case url(browser: BrowserKind, value: String)
    }

    public static func capture(
        frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) -> Result {
        guard let app = frontmost,
              let kind = BrowserKind.allCases.first(
                where: { $0.bundleIdentifier == app.bundleIdentifier })
        else { return .notBrowser(app: frontmost?.localizedName ?? "unknown") }
        guard let source = tabScript(kind: kind) else {
            return .unavailable(browser: kind)
        }
        var err: NSDictionary?
        let value = NSAppleScript(source: source)?
            .executeAndReturnError(&err).stringValue ?? ""
        if let err,
           (err[NSAppleScript.errorNumber] as? Int) == -1743 {
            return .needsConsent(browser: kind)
        }
        guard err == nil, !value.isEmpty else { return .unavailable(browser: kind) }
        return .url(browser: kind, value: value)
    }

    static func tabScript(kind: BrowserKind) -> String? {
        switch kind {
        case .safari:
            // Safari AppleScript has no private-window flag. The Safari app
            // extension handles normal tabs after checking that flag.
            return nil
        case .chrome, .brave, .edge, .vivaldi, .arc, .opera, .chromium:
            // Window mode distinguishes normal/incognito in the Chromium
            // scripting dictionary (verified in Chrome + Brave sdefs) — a
            // private tab must never be moved into another browser's
            // history. Where a browser's dictionary lacks `mode` the script
            // errors and we fail closed (.unavailable) rather than risk
            // leaking a private tab.
            return """
                tell application id "\(kind.bundleIdentifier)"
                    if (count of windows) is 0 then return ""
                    if (mode of front window) is not "normal" then return ""
                    return URL of active tab of front window
                end tell
                """
        case .firefox:
            return nil
        }
    }
}
