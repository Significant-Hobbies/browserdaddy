import Foundation

/// The permanent archive. Merges forever — rows pruned by browsers survive.
public final class ArchiveStore: @unchecked Sendable {
    public let db: SQLiteStore

    public static let defaultURL: URL = {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrowserDaddy", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("browserdaddy.db")
    }()

    public init(url: URL = ArchiveStore.defaultURL) throws {
        db = try SQLiteStore(url: url)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS visits (
                browser TEXT, profile TEXT, visit_id INT, url TEXT, title TEXT,
                visit_time_utc TEXT, visit_count INT, typed_count INT,
                transition TEXT, duration_s REAL, from_visit INT)
        """)
        try db.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_visits_dedup
                ON visits(browser, profile, visit_id)
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_visits_time ON visits(visit_time_utc)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_visits_url ON visits(url)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS searches (
                browser TEXT, profile TEXT, term TEXT, url TEXT, title TEXT)
        """)
        try db.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_searches_dedup
                ON searches(browser, profile, term, url)
        """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS focus (
                id INTEGER PRIMARY KEY,
                start_utc TEXT, end_utc TEXT, app TEXT, url TEXT, title TEXT,
                ticks INT DEFAULT 0, active_s REAL DEFAULT 0)
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_focus_start ON focus(start_utc)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)
        """)
        // Local category cache; optional external tagging requires current consent.
        try db.execute("""
            CREATE TABLE IF NOT EXISTS domain_categories (
                host TEXT PRIMARY KEY, category TEXT, confidence REAL)
        """)
        // Page-level topics share the same optional-classification consent boundary.
        try db.execute("""
            CREATE TABLE IF NOT EXISTS page_categories (
                url TEXT PRIMARY KEY, category TEXT, confidence REAL)
        """)
        // 'source' marks user overrides; tag runs never touch those rows.
        ensureColumn("domain_categories", "source")
        ensureColumn("page_categories", "source")
    }

    private func ensureColumn(_ table: String, _ column: String) {
        let cols = (try? db.query("PRAGMA table_info(\(table))")) ?? []
        if !cols.contains(where: { $0["name"]?.text == column }) {
            _ = try? db.execute(
                "ALTER TABLE \(table) ADD COLUMN \(column) TEXT DEFAULT 'auto'")
        }
    }

    /// Manual override — survives every future classification run.
    public func setDomainCategory(_ host: String, _ category: String) throws {
        try db.execute("""
            INSERT OR REPLACE INTO domain_categories
            (host, category, confidence, source) VALUES (?,?,1,'user')
        """, [.text(host), .text(category)])
    }
    /// Rollup override — tags every seen host under an eTLD+1 domain
    /// (e.g. "youtube.com" covers www./m./music.youtube.com).
    public func setRollupCategory(_ rollup: String, _ category: String) throws {
        let hosts = try db.query("""
            SELECT CASE WHEN url LIKE 'http%' THEN
                substr(substr(url, instr(url,'//')+2), 1,
                       instr(substr(url, instr(url,'//')+2)||'/', '/')-1)
                ELSE substr(url,1,40) END h
            FROM visits GROUP BY h
        """).compactMap { $0["h"]?.text }
            .filter { Domain.rollup($0) == rollup }
        try db.writeTransaction {
            for h in hosts {
                try db.execute("""
                    INSERT OR REPLACE INTO domain_categories
                    (host, category, confidence, source) VALUES (?,?,1,'user')
                """, [.text(h), .text(category)])
            }
        }
    }
    public func setPageCategory(_ url: String, _ category: String) throws {
        try db.execute("""
            INSERT OR REPLACE INTO page_categories
            (url, category, confidence, source) VALUES (?,?,1,'user')
        """, [.text(url), .text(category)])
    }

    public func clearDomainCategory(_ host: String) throws {
        try db.execute("DELETE FROM domain_categories WHERE host = ?", [.text(host)])
    }

    public func clearPageCategory(_ url: String) throws {
        try db.execute("DELETE FROM page_categories WHERE url = ?", [.text(url)])
    }

    public func clearRollupCategory(_ rollup: String) throws {
        let hosts = try db.query("SELECT host FROM domain_categories")
            .compactMap { $0["host"]?.text }
            .filter { Domain.rollup($0) == rollup }
        try db.writeTransaction {
            for host in hosts {
                try db.execute("DELETE FROM domain_categories WHERE host = ?", [.text(host)])
            }
        }
    }

    /// Small key-value flags (onboarding state, consent, import markers).
    public func metaGet(_ key: String) -> String? {
        (try? db.scalar("SELECT value FROM meta WHERE key = ?",
                        [.text(key)], as: { $0.text })) ?? nil
    }
    public func metaSet(_ key: String, _ value: String) {
        _ = try? db.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?,?)",
            [.text(key), .text(value)])
    }

    /// INSERT OR IGNORE; returns count actually inserted.
    @discardableResult
    public func merge(visits: [HistoryVisit], source: HistorySource) throws -> Int {
        try db.writeTransaction {
            var inserted = 0
            for v in visits {
                inserted += try db.execute("""
                    INSERT OR IGNORE INTO visits
                    (browser, profile, visit_id, url, title, visit_time_utc,
                     visit_count, typed_count, transition, duration_s, from_visit)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """,
                    [.text(source.browser), .text(source.profile), .int(v.visitID),
                     .text(v.url), .text(v.title),
                     .text(ISO8601.format(v.visitedAt)), .int(Int64(v.visitCount)),
                     .int(Int64(v.typedCount)),
                     v.transition.map(DBValue.text) ?? .null,
                     v.duration.map(DBValue.double) ?? .null,
                     v.fromVisit.map(DBValue.int) ?? .null])
            }
            return inserted
        }
    }

    @discardableResult
    public func merge(searches: [(term: String, url: String, title: String)],
                      source: HistorySource) throws -> Int {
        try db.writeTransaction {
            var inserted = 0
            for s in searches {
                inserted += try db.execute("""
                    INSERT OR IGNORE INTO searches
                    (browser, profile, term, url, title) VALUES (?,?,?,?,?)
                """,
                    [.text(source.browser), .text(source.profile), .text(s.term),
                     .text(s.url), .text(s.title)])
            }
            return inserted
        }
    }
}

public enum ISO8601 {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    public static func format(_ d: Date) -> String { formatter.string(from: d) }
    public static func parse(_ s: String) -> Date? { formatter.date(from: s) }
}
