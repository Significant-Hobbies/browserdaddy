import Foundation

/// Threshold alerts on measured attention. All state lives in the local
/// archive; notification delivery is injected by the app so the engine
/// never touches UNUserNotificationCenter (or the network) itself.
public struct AlertConfig: Codable, Equatable, Sendable {
    public var enabled = false
    /// Focused minutes per day across all apps (sums focus.active_s).
    /// 0 disables the rule.
    public var dailyMinutes = 0
    /// Minutes on one app+page without a break before a nudge. 0 = off.
    public var streakMinutes = 0
    /// Agent-suspected browsing minutes per day — a separate tally from
    /// human attention, since agent segments carry ~zero active_s. 0 = off.
    public var agentMinutes = 0
    /// host (e.g. "youtube.com") → focused minutes per day. Only browsers
    /// with captured tab URLs can accrue site time (the Chromium family —
    /// anything that can prove the focused window isn't private).
    public var siteCaps: [String: Int] = [:]

    public init() {}
}

public final class AlertEngine: @unchecked Sendable {
    private let store: ArchiveStore
    private let lock = NSLock()
    private var firedDay = ""
    private var fired: Set<String> = []
    private var evaluating = false

    /// (title, body) — the app injects local-notification delivery.
    public var deliver: (String, String) -> Void = { _, _ in }

    // Suspicion: a focus episode (same browser app, gaps under
    // FocusWatcher.gapLimit) is agent-suspected when it churns through
    // >= suspicionMinURLs distinct URLs while input stays under
    // suspicionInputRatio of frontmost time. Browsers without captured
    // tab URLs can't qualify — this is measured evidence, not inference.
    public static let suspicionMinURLs = 3
    public static let suspicionInputRatio = 0.05

    public init(store: ArchiveStore) {
        self.store = store
        loadFired()
    }

    public func config() -> AlertConfig {
        guard let raw = store.metaGet("alerts.config"),
              let data = raw.data(using: .utf8),
              let cfg = try? JSONDecoder().decode(AlertConfig.self, from: data)
        else { return AlertConfig() }
        return cfg
    }

    public func saveConfig(_ cfg: AlertConfig) {
        guard let data = try? JSONEncoder().encode(cfg),
              let raw = String(data: data, encoding: .utf8) else { return }
        store.metaSet("alerts.config", raw)
    }

    /// Evaluate all rules against today's focus rows; fire each at most once
    /// per day (persisted, so restarts don't re-alert).
    public func evaluate(now: Date = Date()) {
        lock.lock()
        if evaluating { lock.unlock(); return }
        evaluating = true
        lock.unlock()
        defer { lock.lock(); evaluating = false; lock.unlock() }

        let cfg = config()
        guard cfg.enabled else { return }
        guard let day = today() else { return }

        lock.lock()
        if firedDay != day { firedDay = day; fired = [] }
        let already = fired
        lock.unlock()

        var fires: [(key: String, title: String, body: String)] = []

        if cfg.dailyMinutes > 0, !already.contains("daily"),
           let active = try? store.db.scalar("""
               SELECT SUM(active_s) FROM focus
               WHERE strftime('%Y-%m-%d',start_utc,'localtime') = ?
               """, [.text(day)], as: { $0.double }),
           active >= Double(cfg.dailyMinutes) * 60 {
            fires.append(("daily", "Focused browsing cap reached",
                          "\(Int(active / 60)) focused minutes today "
                          + "(cap \(cfg.dailyMinutes))"))
        }

        for (host, mins) in cfg.siteCaps where mins > 0 {
            let key = "site:\(host)"
            // Caps cover the whole site: a "youtube.com" cap must count
            // "www.youtube.com" too — suffix match, never a bare substring
            // ("notyoutube.com" doesn't end in ".youtube.com").
            guard !already.contains(key),
                  let active = try? store.db.scalar("""
                      SELECT SUM(active_s) FROM focus
                      WHERE strftime('%Y-%m-%d',start_utc,'localtime') = ?
                        AND (\(ReportEngine.hostSQL) = ?
                          OR substr(\(ReportEngine.hostSQL), -(length(?) + 1))
                             = '.' || ?)
                      """, [.text(day), .text(host), .text(host), .text(host)],
                      as: { $0.double }),
                  active >= Double(mins) * 60 else { continue }
            fires.append((key, "Site cap reached",
                          "\(Int(active / 60)) focused minutes on \(host) today "
                          + "(cap \(mins))"))
        }

        if cfg.agentMinutes > 0, !already.contains("agent") {
            let suspected = suspectedAgentSeconds(day: day)
            if suspected >= Double(cfg.agentMinutes) * 60 {
                fires.append(("agent", "Agent-driven browsing cap reached",
                              "\(Int(suspected / 60)) suspected agent minutes "
                              + "today (cap \(cfg.agentMinutes))"))
            }
        }

        if cfg.streakMinutes > 0,
           let streak = currentStreak(now: now),
           streak.seconds >= Double(cfg.streakMinutes) * 60 {
            let key = "streak:\(streak.id)"
            if !already.contains(key) {
                fires.append((key, "Still on \(streak.label)",
                              "\(Int(streak.seconds / 60)) minutes straight "
                              + "without switching"))
            }
        }

        guard !fires.isEmpty else { return }
        var toFire: [(String, String)] = []
        lock.lock()
        for f in fires where !fired.contains(f.key) {
            fired.insert(f.key)
            toFire.append((f.title, f.body))
        }
        persistFired()
        lock.unlock()
        for (title, body) in toFire { deliver(title, body) }
    }

    /// Frontmost seconds today spent in episodes that look agent-driven.
    func suspectedAgentSeconds(day: String) -> Double {
        let rows = (try? store.db.query("""
            SELECT app, url, start_utc, end_utc, ticks, active_s FROM focus
            WHERE strftime('%Y-%m-%d',start_utc,'localtime') = ?
            ORDER BY start_utc
            """, [.text(day)])) ?? []
        let browserNames = Set(FocusWatcher.scriptableBrowsers.values)

        var suspected = 0.0
        var epURLs = Set<String>()
        var epApp = ""
        var epTicks = 0.0
        var epActive = 0.0
        var epLastEnd: Date?

        func closeEpisode() {
            let open = epTicks * FocusWatcher.interval
            if browserNames.contains(epApp),
               epURLs.count >= Self.suspicionMinURLs,
               epActive < Self.suspicionInputRatio * open {
                suspected += open
            }
            epURLs = []; epApp = ""; epTicks = 0; epActive = 0; epLastEnd = nil
        }

        for r in rows {
            let app = r["app"]?.text ?? ""
            let url = r["url"]?.text ?? ""
            let start = (r["start_utc"]?.text).flatMap(ISO8601.parse) ?? Date()
            let end = (r["end_utc"]?.text).flatMap(ISO8601.parse) ?? start
            if app != epApp
                || (epLastEnd.map { start.timeIntervalSince($0) > FocusWatcher.gapLimit }
                    ?? false) {
                closeEpisode()
            }
            epApp = app
            epTicks += Double(r["ticks"]?.int ?? 0)
            epActive += r["active_s"]?.double ?? 0
            if !url.isEmpty { epURLs.insert(url) }
            epLastEnd = end
        }
        closeEpisode()
        return suspected
    }

    /// The still-open focus segment, if it represents one unbroken
    /// app+page span — the streak candidate.
    private func currentStreak(now: Date)
        -> (id: Int64, label: String, seconds: Double)? {
        guard let row = try? store.db.query("""
            SELECT id, app, url, start_utc, end_utc FROM focus
            ORDER BY id DESC LIMIT 1
            """).first,
              let app = row["app"]?.text, !app.isEmpty,
              let s = row["start_utc"]?.text, let e = row["end_utc"]?.text,
              let start = ISO8601.parse(s), let end = ISO8601.parse(e),
              // still open: bumped within a few polls of now
              now.timeIntervalSince(end) < FocusWatcher.interval * 3
        else { return nil }
        let url = row["url"]?.text ?? ""
        let host = url.isEmpty ? ""
            : (URL(string: url)?.host ?? "")
        return (row["id"]?.int ?? 0,
                host.isEmpty ? app : "\(app) · \(host)",
                end.timeIntervalSince(start))
    }

    private func today() -> String? {
        try? store.db.scalar(
            "SELECT strftime('%Y-%m-%d','now','localtime')",
            as: { $0.text })
    }

    private func loadFired() {
        guard let raw = store.metaGet("alerts.fired"),
              let sep = raw.firstIndex(of: "|") else { return }
        firedDay = String(raw[..<sep])
        fired = Set(raw[sep...].dropFirst().split(separator: ",").map(String.init))
    }

    private func persistFired() {
        store.metaSet("alerts.fired",
                      firedDay + "|" + fired.sorted().joined(separator: ","))
    }
}
