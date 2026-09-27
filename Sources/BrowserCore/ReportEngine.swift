import Foundation

/// Report queries over the archive. Port of stats.py — cross-browser fields
/// only; duration is deliberately absent from leaderboards (unreliable).
public struct ReportEngine: Sendable {
    private let db: SQLiteStore

    public init(store: ArchiveStore) { db = store.db }

    /// Host-extraction expression on the `visits.url` column.
    static let hostSQL = """
        CASE WHEN url LIKE 'http%' THEN
            substr(substr(url, instr(url,'//')+2), 1,
                   instr(substr(url, instr(url,'//')+2)||'/', '/')-1)
        ELSE substr(url, 1, 40) END
    """

    public struct SourceSummary: Sendable {
        public var name: String
        public var visits: Int64
        public var first: String
        public var last: String
    }

    public enum HistoryTagFilter: String, CaseIterable, Sendable {
        case all, tagged, untagged, manual
    }

    public struct HistoryQuery: Equatable, Sendable {
        public var term: String
        public var browser: String
        public var source: String
        public var sinceDays: Int
        public var category: String
        public var tag: HistoryTagFilter

        public init(term: String = "", browser: String = "all", source: String = "all",
                    sinceDays: Int = 0, category: String = "all",
                    tag: HistoryTagFilter = .all) {
            self.term = term
            self.browser = browser
            self.source = source
            self.sinceDays = sinceDays
            self.category = category
            self.tag = tag
        }
    }

    public struct HistoryResult: Equatable, Sendable {
        public let browser: String
        public let profile: String
        public let visitID: Int64
        public let url: String
        public let title: String
        public let visitedAt: Date?
        public let host: String
        public let category: String?
        public let tagSource: String?
        public let tagScope: String?
        public let pageCategory: String?
        public let pageTagSource: String?
        public let domainCategory: String?
        public let domainTagSource: String?
    }

    public struct Count: Sendable {
        public var label: String
        public var value: Int64
        public var extra: String = ""
    }

    public struct Session: Sendable {
        public var source: String
        public var visits: Int64
        public var domains: Int64
        public var spanSeconds: Double
        public var start: Date
    }

    public struct DayPoint: Sendable {
        public var date: String     // yyyy-MM-dd
        public var browser: String
        public var count: Int64
    }

    public struct FocusDay: Sendable {
        public var date: String
        public var activeSeconds: Double
        public var ticks: Int64
    }

    public struct Report: Sendable {
        public var totalVisits: Int64 = 0
        public var uniqueURLs: Int64 = 0
        public var uniqueDomains: Int64 = 0
        public var sources: [SourceSummary] = []
        public var monthlyShare: [String] = []
        public var topDomains: [Count] = []
        public var topSites: [Count] = []
        public var topPerBrowser: [Count] = []
        public var personalities: [Count] = []
        public var hourly: [Count] = []
        public var weekday: [Count] = []
        public var daily: [Count] = []
        public var habit: [Count] = []
        public var revisited: [Count] = []
        public var typedShare: [Count] = []
        public var sessionSummary: [Count] = []
        public var rabbitHoles: [Session] = []
        public var attentionApps: [Count] = []
        public var attentionSites: [Count] = []
        public var searches: [Count] = []
        // time series
        public var dailySeries: [DayPoint] = []      // day × browser counts
        public var heatmap: [Int64] = Array(repeating: 0, count: 7 * 24) // dow*24+hour
        public var focusDaily: [FocusDay] = []
        public var newDomainsPerWeek: [Count] = []
        public var cumulativeDomains: [Count] = []   // cumulative unique domains per month
        public var domainTrends: [(domain: String, monthly: [Count])] = []
        // deeper analytics
        public var profileHours: [(source: String, hours: [Int64])] = [] // 24 each
        public var busiestDays: [Count] = []
        public var dowBySource: [(source: String, days: [Int64])] = []   // 7 each
        public var top10Share: Double = 0       // % of visits in top 10 domains
        public var top100Share: Double = 0
        public var medianVisitsPerDay: Int64 = 0
        public var longestStreak: Int64 = 0     // consecutive days with visits
        public var longestGapDays: Int64 = 0
        public var sharedDomains: [(domain: String, sources: String, visits: Int64)] = []
        public var oneHitDomains: Int64 = 0     // domains visited exactly once
        // trends wave 2
        public var weeklySeries: [DayPoint] = []    // week × browser
        public var monthlySeries: [DayPoint] = []   // month × browser
        public var noveltyWeekly: [Count] = []      // week → % visits to first-seen domains
        public var changedLately: [(host: String, cur: Int64, prev: Int64, pct: Double)] = []
        public var curPeriodLabel = ""            // e.g. "Sep 1–19"
        public var prevPeriodLabel = ""           // e.g. "Aug 1–19"
        public var moversUp: [Count] = []           // domains rising month-over-month
        public var moversDown: [Count] = []
        public var deepRead: [Count] = []           // site → active-minutes per visit
        public var dayStarts: [Count] = []          // most common first-site of the day
        public var dayEnds: [Count] = []            // most common last-site of the day
        public var medianDayStart = ""              // "09:12" local
        public var medianDayEnd = ""
        public var habitual: [Count] = []           // domains on ≥80% of active days
        public var returnGaps: [Count] = []         // domain → median hours between visits
        public var nightShare: [Count] = []         // month → % visits 23:00–05:00
        public var switchesPerFocusHour: Double = 0 // context-switch rate
        public var medianSpanSeconds: Double = 0
        // classifier.dev categories
        public var categories: [Count] = []         // category → visits
        public var categoryTopDomains: [(category: String, domains: [Count])] = []
        public var categoryTrends: [(category: String, monthly: [Count])] = []
        // page-level topics (classifier.dev on titles)
        public var topics: [Count] = []             // topic → visits
        public var topicPages: [(topic: String, pages: [Count])] = [] // top pages
        public var topicTrends: [(topic: String, monthly: [Count])] = []
        public var userDomainTags: Set<String> = [] // manually overridden hosts
        public var userRollupTags: Set<String> = [] // …as eTLD+1 rollups
    }

    /// `source` is "browser/profile"; `sinceDays` = 0 means all time.
    public func build(source: String? = nil, sinceDays: Int = 0) throws -> Report {
        var conds: [String] = []
        if let source, !source.isEmpty {
            let esc = source.replacingOccurrences(of: "'", with: "''")
            conds.append("browser||'/'||profile = '\(esc)'")
        }
        var sinceISO = ""
        if sinceDays > 0 {
            sinceISO = ISO8601.format(
                Date().addingTimeInterval(-Double(sinceDays) * 86400))
            conds.append("visit_time_utc >= '\(sinceISO)'")
        }
        let vw = conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND ")
        let va = conds.isEmpty ? "" : " AND " + conds.joined(separator: " AND ")
        let fw = sinceDays > 0 ? " WHERE start_utc >= '\(sinceISO)'" : ""
        let fa = sinceDays > 0 ? " AND start_utc >= '\(sinceISO)'" : ""
        // searches has no timestamp — source filter only.
        let sw = source.map { " WHERE browser||'/'||profile = '"
            + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? ""
        var r = Report()
        r.totalVisits = try db.scalar(
            "SELECT COUNT(*) FROM visits\(vw)", as: { $0.int }) ?? 0
        r.uniqueURLs = try db.scalar(
            "SELECT COUNT(DISTINCT url) FROM visits\(vw)", as: { $0.int }) ?? 0
        r.uniqueDomains = try db.scalar(
            "SELECT COUNT(DISTINCT \(Self.hostSQL)) FROM visits\(vw)",
            as: { $0.int }) ?? 0

        r.sources = try db.query("""
            SELECT browser||'/'||profile src, COUNT(*) c,
                   strftime('%Y-%m-%d',MIN(visit_time_utc),'localtime') f,
                   strftime('%Y-%m-%d',MAX(visit_time_utc),'localtime') l
            FROM visits\(vw) GROUP BY 1 ORDER BY 2 DESC
        """).map {
            SourceSummary(name: $0["src"]?.text ?? "?",
                          visits: $0["c"]?.int ?? 0,
                          first: $0["f"]?.text ?? "",
                          last: $0["l"]?.text ?? "")
        }

        let months = try db.query("""
            SELECT strftime('%Y-%m',visit_time_utc,'localtime') m, browser, COUNT(*) c
            FROM visits\(vw) GROUP BY m, browser ORDER BY m, c DESC
        """)
        var byMonth: [String: [(String, Int64)]] = [:]
        var order: [String] = []
        for row in months {
            let m = row["m"]?.text ?? ""
            if byMonth[m] == nil { order.append(m) }
            byMonth[m, default: []].append(
                (row["browser"]?.text ?? "?", row["c"]?.int ?? 0))
        }
        r.monthlyShare = order.map { m in
            let lst = byMonth[m]!
            let tot = lst.reduce(0) { $0 + $1.1 }
            let parts = lst.map { "\($0.0) \(Int(Double($0.1)/Double(tot)*100))%" }
                .joined(separator: " · ")
            return "\(m)  \(tot)  \(parts)"
        }

        let hostCounts = try db.query("""
            SELECT \(Self.hostSQL) h, COUNT(*) c FROM visits\(vw)
            GROUP BY h
        """).map { ($0["h"]?.text ?? "?", $0["c"]?.int ?? 0) }
        r.topDomains = hostCounts.sorted { $0.1 > $1.1 }.prefix(20).map {
            Count(label: $0.0, value: $0.1)
        }
        var rollup: [String: Int64] = [:]
        for (h, c) in hostCounts { rollup[Domain.rollup(h), default: 0] += c }
        r.topSites = rollup.sorted { $0.value > $1.value }.prefix(20).map {
            Count(label: $0.key, value: $0.value)
        }

        for src in try db.query(
            "SELECT DISTINCT browser||'/'||profile s FROM visits\(vw)") {
            let s = src["s"]?.text ?? ""
            let top = try db.query("""
                SELECT \(Self.hostSQL) h, COUNT(*) c FROM visits
                WHERE browser||'/'||profile = ?\(va)
                GROUP BY h ORDER BY c DESC LIMIT 5
            """, [.text(s)])
                .map { "\($0["h"]?.text ?? "?") (\($0["c"]?.int ?? 0))" }
                .joined(separator: ", ")
            r.topPerBrowser.append(Count(label: s, value: 0, extra: top))
        }

        r.personalities = try db.query("""
            SELECT browser||'/'||profile s, COUNT(*) c, COUNT(DISTINCT url) u,
                   ROUND(100.0*SUM(CASE WHEN CAST(strftime('%w',visit_time_utc,'localtime')
                         AS INT) IN (0,6) THEN 1 ELSE 0 END)/COUNT(*),1) we,
                   ROUND(100.0*SUM(CASE WHEN CAST(strftime('%H',visit_time_utc,'localtime')
                         AS INT) BETWEEN 18 AND 23 THEN 1 ELSE 0 END)/COUNT(*),1) ev
            FROM visits\(vw) GROUP BY 1 ORDER BY 2 DESC
        """).map {
            Count(label: $0["s"]?.text ?? "?", value: $0["c"]?.int ?? 0,
                  extra: "\($0["u"]?.int ?? 0) urls · \($0["we"]?.double ?? 0)% wknd · \($0["ev"]?.double ?? 0)% eve")
        }

        r.hourly = try db.query("""
            SELECT CAST(strftime('%H',visit_time_utc,'localtime') AS INT) h, COUNT(*) c
            FROM visits\(vw) GROUP BY h ORDER BY h
        """).map {
            Count(label: String(format: "%02d:00", $0["h"]?.int ?? 0),
                  value: $0["c"]?.int ?? 0)
        }
        let dnames = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
        r.weekday = try db.query("""
            SELECT strftime('%w',visit_time_utc,'localtime') d, COUNT(*) c
            FROM visits\(vw) GROUP BY d ORDER BY d
        """).map {
            Count(label: dnames[Int($0["d"]?.text ?? "0") ?? 0],
                  value: $0["c"]?.int ?? 0)
        }
        r.daily = try db.query("""
            SELECT strftime('%Y-%m-%d',visit_time_utc,'localtime') d, COUNT(*) c
            FROM visits\(vw) GROUP BY d ORDER BY d DESC LIMIT 30
        """).reversed().map {
            Count(label: $0["d"]?.text ?? "", value: $0["c"]?.int ?? 0)
        }

        for (lo, hi, label) in [(1,1,"visited once"),(2,5,"2-5 times"),
                                (6,20,"6-20 times"),(21,Int.max,"20+ times")] {
            let n = try db.scalar("""
                SELECT COUNT(*) FROM (
                  SELECT \(Self.hostSQL) h, COUNT(*) n FROM visits\(vw) GROUP BY h)
                WHERE n BETWEEN ? AND ?
            """,
                [.int(Int64(lo)), .int(Int64(hi))], as: { $0.int }) ?? 0
            r.habit.append(Count(label: label, value: n))
        }

        r.revisited = try db.query("""
            SELECT url, MAX(visit_count) c FROM visits\(vw)
            GROUP BY url ORDER BY c DESC LIMIT 15
        """).map {
            Count(label: $0["url"]?.text ?? "?", value: $0["c"]?.int ?? 0)
        }

        r.typedShare = try db.query("""
            SELECT browser||'/'||profile s, SUM(vc) v, SUM(tc) t FROM (
              SELECT browser, profile, url,
                     MAX(visit_count) vc, MAX(typed_count) tc
              FROM visits\(vw) GROUP BY browser, profile, url)
            GROUP BY 1 ORDER BY 2 DESC
        """).map {
            let v = $0["v"]?.double ?? 0, t = $0["t"]?.double ?? 0
            return Count(label: $0["s"]?.text ?? "?",
                         value: Int64(v),
                         extra: String(format: "%.1f%% typed", v > 0 ? t/v*100 : 0))
        }

        // Sessions: 30-min gap per source; rabbit holes = most distinct domains.
        let sess = try db.query("""
            WITH v AS (
              SELECT browser||'/'||profile src, julianday(visit_time_utc) jd,
                     \(Self.hostSQL) h FROM visits\(vw))
            , g AS (
              SELECT src, jd, h,
                     CASE WHEN jd - LAG(jd) OVER (PARTITION BY src ORDER BY jd)
                          > 1800.0/86400 THEN 1 ELSE 0 END ns
              FROM v)
            , s AS (
              SELECT src, jd, h,
                     SUM(ns) OVER (PARTITION BY src ORDER BY jd) sid FROM g)
            SELECT src, sid, COUNT(*) n, COUNT(DISTINCT h) dom,
                   (MAX(jd)-MIN(jd))*86400 span, MIN(jd) start_jd
            FROM s GROUP BY src, sid
        """)
        var agg: [String: (n: Int64, tot: Double, mx: Double)] = [:]
        for s in sess {
            let src = s["src"]?.text ?? "?"
            var a = agg[src] ?? (0, 0, 0)
            a.n += 1
            a.tot += s["span"]?.double ?? 0
            a.mx = max(a.mx, s["span"]?.double ?? 0)
            agg[src] = a
        }
        r.sessionSummary = agg.map { src, a in
            Count(label: src, value: a.n,
                  extra: "avg \(fmtDur(a.tot/Double(a.n))) · longest \(fmtDur(a.mx))")
        }.sorted { $0.value > $1.value }
        r.rabbitHoles = sess.sorted {
            let a = (dom: $0["dom"]?.int ?? 0, span: $0["span"]?.double ?? 0)
            let b = (dom: $1["dom"]?.int ?? 0, span: $1["span"]?.double ?? 0)
            return a.dom != b.dom ? a.dom > b.dom : a.span > b.span
        }.prefix(10).map {
            Session(source: $0["src"]?.text ?? "?",
                    visits: $0["n"]?.int ?? 0,
                    domains: $0["dom"]?.int ?? 0,
                    spanSeconds: $0["span"]?.double ?? 0,
                    start: Date(timeIntervalSince1970:
                        (($0["start_jd"]?.double ?? 0) - 2440587.5) * 86400))
        }

        r.attentionApps = try attentionApps(sinceDays: sinceDays)
        r.attentionSites = try attentionSites(sinceDays: sinceDays)

        r.searches = try db.query("""
            SELECT term, COUNT(*) c FROM searches\(sw)
            GROUP BY lower(term) ORDER BY c DESC LIMIT 15
        """).map {
            Count(label: $0["term"]?.text ?? "?", value: $0["c"]?.int ?? 0)
        }

        // ---- time series ----

        r.dailySeries = try db.query("""
            SELECT strftime('%Y-%m-%d',visit_time_utc,'localtime') d, browser, COUNT(*) c
            FROM visits\(vw) GROUP BY d, browser ORDER BY d
        """).map {
            DayPoint(date: $0["d"]?.text ?? "",
                     browser: $0["browser"]?.text ?? "?",
                     count: $0["c"]?.int ?? 0)
        }

        for row in try db.query("""
            SELECT CAST(strftime('%w',visit_time_utc,'localtime') AS INT) d,
                   CAST(strftime('%H',visit_time_utc,'localtime') AS INT) h, COUNT(*) c
            FROM visits\(vw) GROUP BY d, h
        """) {
            let d = Int(row["d"]?.int ?? 0), h = Int(row["h"]?.int ?? 0)
            if (0...6).contains(d), (0...23).contains(h) {
                r.heatmap[d * 24 + h] = row["c"]?.int ?? 0
            }
        }

        r.focusDaily = try db.query("""
            SELECT strftime('%Y-%m-%d',start_utc,'localtime') d, SUM(active_s) a, SUM(ticks) t
            FROM focus\(fw) GROUP BY d ORDER BY d
        """).map {
            FocusDay(date: $0["d"]?.text ?? "",
                     activeSeconds: $0["a"]?.double ?? 0,
                     ticks: $0["t"]?.int ?? 0)
        }

        // First-seen month per domain → exploration rate + cumulative coverage.
        let firstSeen = try db.query("""
            SELECT fs m, COUNT(*) c FROM (
              SELECT MIN(strftime('%Y-%m',visit_time_utc,'localtime')) fs FROM visits\(vw)
              GROUP BY \(Self.hostSQL)) GROUP BY fs ORDER BY fs
        """).map {
            Count(label: $0["m"]?.text ?? "", value: $0["c"]?.int ?? 0)
        }
        r.newDomainsPerWeek = firstSeen
        var running: Int64 = 0
        r.cumulativeDomains = firstSeen.map {
            running += $0.value
            return Count(label: $0.label, value: running)
        }

        // Monthly trend for the top host-level domains.
        for dom in r.topDomains.prefix(6) {
            let rows = try db.query("""
                SELECT strftime('%Y-%m',visit_time_utc,'localtime') m, COUNT(*) c FROM visits
                WHERE \(Self.hostSQL) = ?\(va) GROUP BY m ORDER BY m
            """, [.text(dom.label)])
            r.domainTrends.append((dom.label, rows.map {
                Count(label: $0["m"]?.text ?? "", value: $0["c"]?.int ?? 0)
            }))
        }

        // ---- deeper analytics ----

        // Per-source hourly curves (for normalized profile comparison).
        var ph: [String: [Int64]] = [:]
        for row in try db.query("""
            SELECT browser||'/'||profile s,
                   CAST(strftime('%H',visit_time_utc,'localtime') AS INT) h, COUNT(*) c
            FROM visits\(vw) GROUP BY s, h
        """) {
            let s = row["s"]?.text ?? "?", h = Int(row["h"]?.int ?? 0)
            if (0...23).contains(h) {
                ph[s, default: Array(repeating: 0, count: 24)][h] = row["c"]?.int ?? 0
            }
        }
        r.profileHours = ph.map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }

        r.busiestDays = try db.query("""
            SELECT strftime('%Y-%m-%d',visit_time_utc,'localtime') d, COUNT(*) c
            FROM visits\(vw) GROUP BY d ORDER BY c DESC LIMIT 10
        """).map { Count(label: $0["d"]?.text ?? "", value: $0["c"]?.int ?? 0) }

        var dowSrc: [String: [Int64]] = [:]
        for row in try db.query("""
            SELECT browser||'/'||profile s,
                   CAST(strftime('%w',visit_time_utc,'localtime') AS INT) d, COUNT(*) c
            FROM visits\(vw) GROUP BY s, d
        """) {
            let s = row["s"]?.text ?? "?", d = Int(row["d"]?.int ?? 0)
            if (0...6).contains(d) {
                dowSrc[s, default: Array(repeating: 0, count: 7)][d] = row["c"]?.int ?? 0
            }
        }
        r.dowBySource = dowSrc.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }

        // Concentration: share of visits in top-10 / top-100 domains.
        if r.totalVisits > 0 {
            let sorted = hostCounts.map { $0.1 }.sorted(by: >)
            r.top10Share = Double(sorted.prefix(10).reduce(0, +))
                / Double(r.totalVisits) * 100
            r.top100Share = Double(sorted.prefix(100).reduce(0, +))
                / Double(r.totalVisits) * 100
            r.oneHitDomains = Int64(sorted.filter { $0 == 1 }.count)
        }

        // Day-level stats from the daily series.
        let dayTotals = r.dailySeries.reduce(into: [String: Int64]()) {
            $0[$1.date, default: 0] += $1.count
        }.sorted { $0.key < $1.key }
        if !dayTotals.isEmpty {
            let counts = dayTotals.map(\.value).sorted()
            r.medianVisitsPerDay = counts[counts.count / 2]
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.timeZone = TimeZone(identifier: "UTC")
            var streak: Int64 = 1, prev: Date? = nil
            var gap: Int64 = 0
            for (d, _) in dayTotals {
                guard let date = fmt.date(from: d) else { continue }
                if let p = prev {
                    let diff = Int64(date.timeIntervalSince(p) / 86400)
                    streak = diff == 1 ? streak + 1 : 1
                    gap = max(gap, diff - 1)
                }
                // Outside the prev check — one active day is still a
                // streak of 1.
                r.longestStreak = max(r.longestStreak, streak)
                prev = date
            }
            r.longestGapDays = gap
        }

        // Domains used in more than one browser/profile.
        r.sharedDomains = try db.query("""
            SELECT \(Self.hostSQL) h, COUNT(DISTINCT browser||'/'||profile) n,
                   GROUP_CONCAT(DISTINCT browser) srcs, COUNT(*) c
            FROM visits\(vw) GROUP BY h HAVING n > 1
            ORDER BY c DESC LIMIT 15
        """).map {
            (domain: $0["h"]?.text ?? "?",
             sources: $0["srcs"]?.text ?? "",
             visits: $0["c"]?.int ?? 0)
        }

        // ---- trends wave 2 ----

        // Weekly volume per browser (Monday-start weeks).
        r.weeklySeries = try db.query("""
            SELECT date(visit_time_utc,'localtime','+1 day','weekday 1','-7 days') w,
                   browser, COUNT(*) c
            FROM visits\(vw) GROUP BY w, browser ORDER BY w
        """).map {
            DayPoint(date: $0["w"]?.text ?? "",
                     browser: $0["browser"]?.text ?? "?",
                     count: $0["c"]?.int ?? 0)
        }
        r.monthlySeries = try db.query("""
            SELECT strftime('%Y-%m',visit_time_utc,'localtime') m,
                   browser, COUNT(*) c
            FROM visits\(vw) GROUP BY m, browser ORDER BY m
        """).map {
            DayPoint(date: $0["m"]?.text ?? "",
                     browser: $0["browser"]?.text ?? "?",
                     count: $0["c"]?.int ?? 0)
        }

        // Novelty: % of each week's visits to domains first seen that week.
        r.noveltyWeekly = try db.query("""
            WITH fs AS (
              SELECT \(Self.hostSQL) h,
                     MIN(date(visit_time_utc,'localtime','+1 day','weekday 1','-7 days')) fw
              FROM visits GROUP BY h)
            SELECT date(visit_time_utc,'localtime','+1 day','weekday 1','-7 days') w,
                   ROUND(100.0*SUM(CASE WHEN fs.fw =
                       date(visit_time_utc,'localtime','+1 day','weekday 1','-7 days')
                       THEN 1 ELSE 0 END)/COUNT(*),1) p,
                   COUNT(*) c
            FROM visits JOIN fs ON fs.h = \(Self.hostSQL)\(va)
            GROUP BY w ORDER BY w
        """).map {
            Count(label: $0["w"]?.text ?? "",
                  value: Int64($0["p"]?.double ?? 0),
                  extra: "\($0["c"]?.int ?? 0) visits")
        }

        // Movers + Changed Lately: month-to-date vs same day-of-month
        // last month — fair partial-month comparison.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        let cal = Calendar.current
        let curMonth = df.string(from: Date())
        let prevMonth = df.string(from: cal.date(
            byAdding: .month, value: -1, to: Date()) ?? Date())
        let today = cal.component(.day, from: Date())
        let mf = DateFormatter(); mf.dateFormat = "MMM"
        let prevDate = cal.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        r.curPeriodLabel = "\(mf.string(from: Date())) 1–\(today)"
        r.prevPeriodLabel = "\(mf.string(from: prevDate)) 1–\(today)"
        let mtdRows = try db.query("""
            SELECT \(Self.hostSQL) h,
                   SUM(CASE WHEN m = ? THEN 1 ELSE 0 END) cur,
                   SUM(CASE WHEN m = ? AND dd <= ? THEN 1 ELSE 0 END) prev
            FROM (
              SELECT url, browser, profile, visit_time_utc,
                     strftime('%Y-%m',visit_time_utc,'localtime') m,
                     CAST(strftime('%d',visit_time_utc,'localtime') AS INT) dd
              FROM visits\(vw)
            )
            WHERE m IN (?, ?)
            GROUP BY h
        """, [.text(curMonth), .text(prevMonth), .int(Int64(today)),
              .text(curMonth), .text(prevMonth)])
        var changed: [(String, Int64, Int64, Double)] = []
        for row in mtdRows {
            let h = row["h"]?.text ?? "?"
            let cur = row["cur"]?.int ?? 0, prev = row["prev"]?.int ?? 0
            if cur + prev >= 20 {
                let pct = prev > 0 ? 100.0 * Double(cur - prev) / Double(prev)
                                 : (cur > 0 ? 100 : 0)
                changed.append((h, cur, prev, pct))
            }
        }
        // |pct| as the "how much did it move" score — big relative shifts.
        let ranked = changed.sorted { abs($0.3) > abs($1.3) }
        r.moversUp = changed.filter { $0.3 > 0 }
            .sorted { $0.3 > $1.3 }.prefix(8).map {
                Count(label: $0.0, value: $0.1,
                      extra: "\($0.2) → \($0.1) MTD")
            }
        r.moversDown = changed.filter { $0.3 < 0 }
            .sorted { $0.3 < $1.3 }.prefix(8).map {
                Count(label: $0.0, value: $0.1,
                      extra: "\($0.2) → \($0.1) MTD")
            }
        r.changedLately = ranked.prefix(6).map {
            (host: $0.0, cur: $0.1, prev: $0.2, pct: $0.3)
        }

        // Deep-read: active minutes per visit per site (focus ⨯ history).
        var visitsByHost: [String: Int64] = [:]
        for (h, c) in hostCounts { visitsByHost[h] = c }
        var deep: [(String, Double)] = []
        for row in try db.query("""
            SELECT \(Self.hostSQL) h, SUM(active_s) a FROM focus
            WHERE url != ''\(fa) GROUP BY h
        """) {
            let h = row["h"]?.text ?? "?"
            let a = row["a"]?.double ?? 0
            if let v = visitsByHost[h], v >= 5, a > 0 {
                deep.append((h, a / 60 / Double(v)))
            }
        }
        r.deepRead = deep.sorted { $0.1 > $1.1 }.prefix(10).map {
            Count(label: $0.0, value: Int64($0.1 * 60),
                  extra: String(format: "%.1f min active / visit", $0.1))
        }

        // Day edges: most common first/last site of each active day,
        // and median start/end clock times.
        let edges = try db.query("""
            WITH d AS (
              SELECT \(Self.hostSQL) h, visit_time_utc t,
                     strftime('%Y-%m-%d',visit_time_utc,'localtime') day,
                     ROW_NUMBER() OVER (PARTITION BY
                       strftime('%Y-%m-%d',visit_time_utc,'localtime')
                       ORDER BY visit_time_utc) rn,
                     COUNT(*) OVER (PARTITION BY
                       strftime('%Y-%m-%d',visit_time_utc,'localtime')) n
              FROM visits\(vw))
            SELECT h, SUM(rn=1) f, SUM(rn=n) l, COUNT(*) c FROM d
            GROUP BY h
        """)
        r.dayStarts = edges.sorted {
            ($0["f"]?.int ?? 0) > ($1["f"]?.int ?? 0)
        }.prefix(8).map {
            Count(label: $0["h"]?.text ?? "?", value: $0["f"]?.int ?? 0)
        }.filter { $0.value > 0 }
        r.dayEnds = edges.sorted {
            ($0["l"]?.int ?? 0) > ($1["l"]?.int ?? 0)
        }.prefix(8).map {
            Count(label: $0["h"]?.text ?? "?", value: $0["l"]?.int ?? 0)
        }.filter { $0.value > 0 }

        let dayHours = try db.query("""
            SELECT strftime('%Y-%m-%d',visit_time_utc,'localtime') day,
                   MIN(strftime('%H:%M',visit_time_utc,'localtime')) s,
                   MAX(strftime('%H:%M',visit_time_utc,'localtime')) e
            FROM visits\(vw) GROUP BY day
        """).map { ($0["s"]?.text ?? "00:00", $0["e"]?.text ?? "00:00") }
        if !dayHours.isEmpty {
            func medianStr(_ xs: [String]) -> String {
                xs.sorted()[xs.count / 2]
            }
            r.medianDayStart = medianStr(dayHours.map { $0.0 })
            r.medianDayEnd = medianStr(dayHours.map { $0.1 })
        }

        // Habitual: domains present on ≥80% of active days.
        let activeDays = max(1, Set(r.dailySeries.map(\.date)).count)
        r.habitual = try db.query("""
            SELECT \(Self.hostSQL) h,
                   COUNT(DISTINCT
                     strftime('%Y-%m-%d',visit_time_utc,'localtime')) days,
                   COUNT(*) c
            FROM visits\(vw) GROUP BY h HAVING days >= ?
            ORDER BY days DESC, c DESC LIMIT 10
        """, [.int(Int64(Double(activeDays) * 0.8))]).map {
            let days = $0["days"]?.int ?? 0
            let pct = Int(100.0 * Double(days) / Double(activeDays))
            return Count(label: $0["h"]?.text ?? "?", value: days,
                         extra: "\($0["c"]?.int ?? 0) visits · \(pct)% of days")
        }

        // Return gap: median hours between consecutive visits, top domains.
        let topHosts = Array(r.topDomains.prefix(8).map(\.label))
        if !topHosts.isEmpty {
            let ph = topHosts.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
                .joined(separator: ",")
            let gaps = try db.query("""
                SELECT h, gap FROM (
                  SELECT \(Self.hostSQL) h,
                         julianday(visit_time_utc)
                         - LAG(julianday(visit_time_utc)) OVER (
                             PARTITION BY \(Self.hostSQL)
                             ORDER BY visit_time_utc) gap
                  FROM visits\(vw))
                WHERE gap IS NOT NULL AND h IN (\(ph))
            """)
            var byHost: [String: [Double]] = [:]
            for g in gaps {
                byHost[g["h"]?.text ?? "?", default: []]
                    .append((g["gap"]?.double ?? 0) * 24)
            }
            r.returnGaps = byHost.map { h, gs in
                let s = gs.sorted()
                return Count(label: h, value: Int64(s[s.count / 2] * 60),
                             extra: String(format: "%.1fh median gap",
                                           s[s.count / 2]))
            }.sorted { $0.value < $1.value }
        }

        // Night-owl share per month (23:00–05:00 local).
        r.nightShare = try db.query("""
            SELECT strftime('%Y-%m',visit_time_utc,'localtime') m,
                   ROUND(100.0*SUM(CASE WHEN
                     CAST(strftime('%H',visit_time_utc,'localtime') AS INT)
                     IN (23,0,1,2,3,4) THEN 1 ELSE 0 END)/COUNT(*),1) p
            FROM visits\(vw) GROUP BY m ORDER BY m
        """).map {
            Count(label: $0["m"]?.text ?? "",
                  value: Int64($0["p"]?.double ?? 0))
        }

        // Fragmentation: segments per focused hour + median span.
        let spans = try db.query(
            "SELECT active_s FROM focus\(fw) ORDER BY start_utc")
            .map { $0["active_s"]?.double ?? 0 }
        if !spans.isEmpty {
            let tot = spans.reduce(0, +)
            r.switchesPerFocusHour = tot > 0
                ? Double(spans.count) / (tot / 3600) : 0
            let s = spans.sorted()
            r.medianSpanSeconds = s[s.count / 2]
        }

        // ---- categories (classifier.dev, batch-imported) ----

        r.categories = try db.query("""
            SELECT COALESCE(c.category,'unclassified') cat, COUNT(*) n
            FROM visits LEFT JOIN domain_categories c
                 ON c.host = \(Self.hostSQL)\(vw)
            GROUP BY cat ORDER BY n DESC
        """).map {
            Count(label: $0["cat"]?.text ?? "?", value: $0["n"]?.int ?? 0)
        }

        // Top domains within each category (top 3 shown).
        let perCat = try db.query("""
            SELECT COALESCE(c.category,'unclassified') cat,
                   \(Self.hostSQL) h, COUNT(*) n
            FROM visits LEFT JOIN domain_categories c
                 ON c.host = \(Self.hostSQL)\(vw)
            GROUP BY cat, h ORDER BY cat, n DESC
        """)
        var catMap: [String: [Count]] = [:]
        for row in perCat {
            let cat = row["cat"]?.text ?? "?"
            catMap[cat, default: []].append(
                Count(label: row["h"]?.text ?? "?",
                      value: row["n"]?.int ?? 0))
        }
        r.categoryTopDomains = catMap.map { ($0.key, Array($0.value.prefix(3))) }

        // Monthly trend for the top 5 categories.
        let catMonthly = try db.query("""
            SELECT COALESCE(c.category,'unclassified') cat,
                   strftime('%Y-%m',visit_time_utc,'localtime') m, COUNT(*) n
            FROM visits LEFT JOIN domain_categories c
                 ON c.host = \(Self.hostSQL)\(vw)
            GROUP BY cat, m ORDER BY m
        """)
        var catSeries: [String: [Count]] = [:]
        for row in catMonthly {
            catSeries[row["cat"]?.text ?? "?", default: []].append(
                Count(label: row["m"]?.text ?? "",
                      value: row["n"]?.int ?? 0))
        }
        r.categoryTrends = r.categories.prefix(5).compactMap { c in
            catSeries[c.label].map { (c.label, $0) }
        }

        // ---- page topics (classifier.dev on page titles) ----

        r.topics = try db.query("""
            SELECT COALESCE(p.category,'unclassified') t, COUNT(*) n
            FROM visits LEFT JOIN page_categories p ON p.url = visits.url\(vw)
            GROUP BY t ORDER BY n DESC
        """).map {
            Count(label: $0["t"]?.text ?? "?", value: $0["n"]?.int ?? 0)
        }

        let perTopic = try db.query("""
            SELECT COALESCE(p.category,'unclassified') t, visits.url u,
                   COUNT(*) n
            FROM visits LEFT JOIN page_categories p ON p.url = visits.url\(vw)
            GROUP BY t, u ORDER BY t, n DESC
        """)
        var topicMap: [String: [Count]] = [:]
        for row in perTopic {
            topicMap[row["t"]?.text ?? "?", default: []].append(
                Count(label: row["u"]?.text ?? "?",
                      value: row["n"]?.int ?? 0))
        }
        r.topicPages = topicMap.map { ($0.key, Array($0.value.prefix(3))) }

        let topicMonthly = try db.query("""
            SELECT COALESCE(p.category,'unclassified') t,
                   strftime('%Y-%m',visit_time_utc,'localtime') m, COUNT(*) n
            FROM visits LEFT JOIN page_categories p ON p.url = visits.url\(vw)
            GROUP BY t, m ORDER BY m
        """)
        var topicSeries: [String: [Count]] = [:]
        for row in topicMonthly {
            topicSeries[row["t"]?.text ?? "?", default: []].append(
                Count(label: row["m"]?.text ?? "",
                      value: row["n"]?.int ?? 0))
        }
        r.topicTrends = r.topics.prefix(5).compactMap { t in
            topicSeries[t.label].map { (t.label, $0) }
        }

        r.userDomainTags = Set(try db.query(
            "SELECT host FROM domain_categories WHERE source = 'user'")
            .compactMap { $0["host"]?.text })
        r.userRollupTags = Set(r.userDomainTags.map { Domain.rollup($0) })
        return r
    }

    private func focusWhere(_ sinceDays: Int) -> String {
        guard sinceDays > 0 else { return "" }
        let iso = ISO8601.format(
            Date().addingTimeInterval(-Double(sinceDays) * 86400))
        return " WHERE start_utc >= '\(iso)'"
    }
    private func focusAnd(_ sinceDays: Int) -> String {
        guard sinceDays > 0 else { return "" }
        let iso = ISO8601.format(
            Date().addingTimeInterval(-Double(sinceDays) * 86400))
        return " AND start_utc >= '\(iso)'"
    }

    public func attentionApps(sinceDays: Int = 0) throws -> [Count] {
        try db.query("""
            SELECT app, SUM(active_s) a, SUM(ticks)*\(FocusWatcher.interval) o
            FROM focus\(focusWhere(sinceDays))
            GROUP BY app ORDER BY a DESC LIMIT 15
        """).map {
            Count(label: $0["app"]?.text ?? "?",
                  value: Int64($0["a"]?.double ?? 0),
                  extra: "open \(fmtDur($0["o"]?.double ?? 0))")
        }
    }

    public struct FocusSegRow: Sendable, Identifiable {
        public var id: Int64
        public var start: Date?
        public var end: Date?
        public var app: String
        public var url: String
        public var activeSeconds: Double
        public var ticks: Int64
    }

    /// Raw focus segments for a local day (yyyy-MM-dd) — the timeline view.
    public func focusSegments(day: String) throws -> [FocusSegRow] {
        try db.query("""
            SELECT id, start_utc, end_utc, app, url, active_s, ticks
            FROM focus WHERE strftime('%Y-%m-%d',start_utc,'localtime') = ? ORDER BY start_utc
        """, [.text(day)]).map {
            FocusSegRow(id: $0["id"]?.int ?? 0,
                        start: ISO8601.parse($0["start_utc"]?.text ?? ""),
                        end: ISO8601.parse($0["end_utc"]?.text ?? ""),
                        app: $0["app"]?.text ?? "?",
                        url: $0["url"]?.text ?? "",
                        activeSeconds: $0["active_s"]?.double ?? 0,
                        ticks: $0["ticks"]?.int ?? 0)
        }
    }

    public struct SiteCheck: Sendable {
        public var host = ""
        public var thisMonth: Int64 = 0         // month-to-date
        public var lastMonthSameDays: Int64 = 0 // same day-of-month, last month
        public var deltaPct: Double = 0
        public var daily: [Count] = []          // last 60 days
        public var focusThisWeek: Double = 0    // active seconds, last 7d
        public var focusPrevWeek: Double = 0
    }

    /// "Did X change?" — fair month-to-date comparison vs the same
    /// day-of-month last month, plus a 7-day focus-window comparison.
    public func siteCheck(_ host: String) throws -> SiteCheck {
        var c = SiteCheck(host: host)
        c.thisMonth = try db.scalar("""
            SELECT COUNT(*) FROM visits
            WHERE \(Self.hostSQL) = ?
              AND strftime('%Y-%m',visit_time_utc,'localtime')
                  = strftime('%Y-%m','now','localtime')
        """, [.text(host)], as: { $0.int }) ?? 0
        c.lastMonthSameDays = try db.scalar("""
            SELECT COUNT(*) FROM visits
            WHERE \(Self.hostSQL) = ?
              AND strftime('%Y-%m',visit_time_utc,'localtime')
                  = strftime('%Y-%m','now','localtime','-1 month')
              AND CAST(strftime('%d',visit_time_utc,'localtime') AS INT)
                  <= CAST(strftime('%d','now','localtime') AS INT)
        """, [.text(host)], as: { $0.int }) ?? 0
        c.deltaPct = c.lastMonthSameDays > 0
            ? 100.0 * Double(c.thisMonth - c.lastMonthSameDays)
                  / Double(c.lastMonthSameDays)
            : (c.thisMonth > 0 ? 100 : 0)
        c.daily = try db.query("""
            SELECT strftime('%Y-%m-%d',visit_time_utc,'localtime') d, COUNT(*) c
            FROM visits
            WHERE \(Self.hostSQL) = ?
              AND visit_time_utc >= datetime('now','-60 days')
            GROUP BY d ORDER BY d
        """, [.text(host)]).map {
            Count(label: $0["d"]?.text ?? "", value: $0["c"]?.int ?? 0)
        }
        for row in try db.query("""
            SELECT CASE WHEN start_utc >= datetime('now','-7 days')
                        THEN 1 ELSE 0 END recent, SUM(active_s) a
            FROM focus
            WHERE \(Self.hostSQL) = ?
              AND start_utc >= datetime('now','-14 days')
            GROUP BY recent
        """, [.text(host)]) {
            if row["recent"]?.int == 1 { c.focusThisWeek = row["a"]?.double ?? 0 }
            else { c.focusPrevWeek = row["a"]?.double ?? 0 }
        }
        return c
    }

    /// Days that have focus data, newest first.
    public func focusDays(sinceDays: Int = 0) throws -> [String] {
        try db.query("""
            SELECT strftime('%Y-%m-%d',start_utc,'localtime') d, SUM(active_s) a
            FROM focus\(focusWhere(sinceDays)) GROUP BY d ORDER BY d DESC
        """).compactMap { $0["d"]?.text }
    }

    /// Active seconds by hour-of-day — when attention actually happens.
    public func attentionHourly(sinceDays: Int = 0) throws -> [Int64] {
        var hours = Array(repeating: Int64(0), count: 24)
        for row in try db.query("""
            SELECT CAST(strftime('%H',start_utc,'localtime') AS INT) h,
                   SUM(active_s) a FROM focus\(focusWhere(sinceDays)) GROUP BY h
        """) {
            let h = Int(row["h"]?.int ?? 0)
            if (0...23).contains(h) { hours[h] = Int64(row["a"]?.double ?? 0) }
        }
        return hours
    }

    /// Per-app totals: active vs open vs segment count vs longest span.
    public func attentionAppsDetailed(sinceDays: Int = 0) throws -> [Count] {
        try db.query("""
            SELECT app, SUM(active_s) a, SUM(ticks)*\(FocusWatcher.interval) o,
                   COUNT(*) n, MAX(active_s) longest
            FROM focus\(focusWhere(sinceDays)) GROUP BY app ORDER BY a DESC
        """).map {
            Count(label: $0["app"]?.text ?? "?",
                  value: Int64($0["a"]?.double ?? 0),
                  extra: "\(fmtDur($0["o"]?.double ?? 0)) open · "
                         + "\($0["n"]?.int ?? 0) spans · longest "
                         + "\(fmtDur($0["longest"]?.double ?? 0))")
        }
    }

    /// Per-site totals with open-vs-active split.
    public func attentionSitesDetailed(sinceDays: Int = 0) throws -> [Count] {
        try db.query("""
            SELECT \(Self.hostSQL) h, SUM(active_s) a, SUM(ticks)*\(FocusWatcher.interval) o,
                   COUNT(*) n
            FROM focus WHERE url != ''\(focusAnd(sinceDays))
            GROUP BY h ORDER BY a DESC LIMIT 20
        """).map {
            Count(label: $0["h"]?.text ?? "?",
                  value: Int64($0["a"]?.double ?? 0),
                  extra: "\(fmtDur($0["o"]?.double ?? 0)) open · "
                         + "\($0["n"]?.int ?? 0) spans")
        }
    }

    public func attentionSites(sinceDays: Int = 0) throws -> [Count] {
        try db.query("""
            SELECT \(Self.hostSQL) h, SUM(active_s) a FROM focus
            WHERE url != ''\(focusAnd(sinceDays))
            GROUP BY h ORDER BY a DESC LIMIT 15
        """).map {
            Count(label: $0["h"]?.text ?? "?",
                  value: Int64($0["a"]?.double ?? 0))
        }
    }

    /// Unified history search for the History surface. Every user-controlled
    /// value is bound, including LIKE terms and date cutoffs.
    public func searchHistory(_ query: HistoryQuery = HistoryQuery(),
                              limit: Int = 500) throws -> [HistoryResult] {
        var sql = """
            WITH enriched AS (
                SELECT browser, profile, visit_id, url, title, visit_time_utc,
                       \(Self.hostSQL) host
                FROM visits
            )
            SELECT e.browser, e.profile, e.visit_id, e.url, e.title,
                   e.visit_time_utc, e.host,
                   COALESCE(p.category, d.category) category,
                   COALESCE(p.source, d.source) tag_source,
                   CASE WHEN p.category IS NOT NULL THEN 'page'
                        WHEN d.category IS NOT NULL THEN 'domain' END tag_scope,
                   p.category page_category, p.source page_tag_source,
                   d.category domain_category, d.source domain_tag_source
            FROM enriched e
            LEFT JOIN page_categories p ON p.url = e.url
            LEFT JOIN domain_categories d ON d.host = e.host
            WHERE 1=1
        """
        var params: [DBValue] = []
        if !query.term.isEmpty {
            sql += " AND (e.url LIKE ? OR e.title LIKE ?)"
            params += [.text("%\(query.term)%"), .text("%\(query.term)%")]
        }
        if query.browser != "all" {
            sql += " AND e.browser = ?"
            params.append(.text(query.browser))
        }
        if query.source != "all" {
            sql += " AND e.browser || '/' || e.profile = ?"
            params.append(.text(query.source))
        }
        if query.sinceDays > 0 {
            sql += " AND e.visit_time_utc >= ?"
            params.append(.text(ISO8601.format(
                Date().addingTimeInterval(-Double(query.sinceDays) * 86_400))))
        }
        if query.category != "all" {
            sql += " AND COALESCE(p.category, d.category) = ?"
            params.append(.text(query.category))
        }
        switch query.tag {
        case .all: break
        case .tagged: sql += " AND COALESCE(p.category, d.category) IS NOT NULL"
        case .untagged: sql += " AND COALESCE(p.category, d.category) IS NULL"
        case .manual: sql += " AND COALESCE(p.source, d.source) = 'user'"
        }
        sql += " ORDER BY e.visit_time_utc DESC LIMIT ?"
        params.append(.int(Int64(limit)))
        return try db.query(sql, params).map { row in
            HistoryResult(
                browser: row["browser"]?.text ?? "",
                profile: row["profile"]?.text ?? "",
                visitID: row["visit_id"]?.int ?? 0,
                url: row["url"]?.text ?? "",
                title: row["title"]?.text ?? "",
                visitedAt: ISO8601.parse(row["visit_time_utc"]?.text ?? ""),
                host: row["host"]?.text ?? "",
                category: row["category"]?.text,
                tagSource: row["tag_source"]?.text,
                tagScope: row["tag_scope"]?.text,
                pageCategory: row["page_category"]?.text,
                pageTagSource: row["page_tag_source"]?.text,
                domainCategory: row["domain_category"]?.text,
                domainTagSource: row["domain_tag_source"]?.text
            )
        }
    }

    public func browsers() throws -> [String] {
        try db.query("SELECT DISTINCT browser FROM visits ORDER BY 1")
            .compactMap { $0["browser"]?.text }
    }

    public func historySources() throws -> [String] {
        try db.query("SELECT DISTINCT browser || '/' || profile source FROM visits ORDER BY 1")
            .compactMap { $0["source"]?.text }
    }

    public func historyCategories() throws -> [String] {
        try db.query("""
            SELECT category FROM domain_categories
            UNION SELECT category FROM page_categories
            ORDER BY 1
        """).compactMap { $0["category"]?.text }
    }
}

public enum Domain {
    static let multipartTLDs: Set<String> = [
        "co.uk","co.in","co.jp","co.nz","com.au","com.br","com.sg",
        "org.uk","net.au","ac.uk","gov.uk",
        "github.io","gitlab.io","pages.dev","workers.dev","web.app",
        "vercel.app","netlify.app","herokuapp.com","blogspot.com",
        "appspot.com","myshopify.com","amazonaws.com","googleapis.com",
        "cloudfront.net","readthedocs.io","firebaseapp.com",
    ]

    /// Crude registrable-domain rollup; keeps localhost:port/IPs as-is.
    public static func rollup(_ host: String) -> String {
        let base = host.split(separator: ":")[0].description
        let labels = base.split(separator: ".")
        if labels.count <= 2 || labels.last!.allSatisfy(\.isNumber) {
            return host
        }
        let last2 = labels.suffix(2).joined(separator: ".")
        if multipartTLDs.contains(last2) {
            return labels.suffix(3).joined(separator: ".")
        }
        return last2
    }
}

public func fmtDur(_ s: Double) -> String {
    s >= 3600 ? String(format: "%.1fh", s/3600)
              : String(format: "%.0fm", s/60)
}
