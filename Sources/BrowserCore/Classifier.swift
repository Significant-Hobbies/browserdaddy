import Foundation

/// Optional enrichment via classifier.dev. Runs ONLY when the user has
/// granted current consent and explicitly taps "Classify".
public struct Classifier: Sendable {
    public let db: SQLiteStore
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport
    public static let disclosure = "Optional classification sends domain names, page titles (up to 140 characters) and URL paths (up to 60 characters) to classifier.dev when you choose Tag. Domain hints include up to three short page titles. URL credentials, query strings and fragments are excluded, but titles and paths may still contain personal information. These requests are not anonymous; the service also receives your network address. Turning this off cancels active requests and stops remaining batches. Data already sent cannot be recalled; existing local tags are kept. Skip this and all local browsing features still work."
    private static let endpoint = URL(
        string: "https://classifier.dev/v1/classify")!

    public static let domainLabels = [
        "development", "ai-tools", "cloud-infra", "documentation",
        "social-media", "video", "music", "news", "shopping", "finance",
        "communication", "productivity", "search", "gaming",
        "entertainment", "education", "travel", "health", "other",
    ]
    public static let pageLabels = [
        "programming", "devops-infra", "ai-ml", "web-dev", "data",
        "news", "entertainment", "gaming", "finance", "shopping",
        "social-media", "music", "video-entertainment", "tutorial-docs",
        "science", "politics", "sports", "health", "travel", "food",
        "productivity", "communication", "search-homepage", "nsfw", "other",
    ]

    public init(db: SQLiteStore, transport: @escaping Transport = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.db = db
        self.transport = transport
    }

    static func pageInput(url: String, title: String) -> String? {
        guard let parsed = URL(string: url),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              let host = parsed.host, !host.isEmpty else { return nil }
        let path = parsed.path.count > 1 ? " \(parsed.path.prefix(60))" : ""
        return "\(host)\(path) — \(title.prefix(140))"
    }

    public struct Result: Sendable {
        public var domains = 0
        public var pages = 0
        public var coveragePct = 0.0
    }

    /// Classify every unclassified domain, then top-N unclassified pages.
    /// Progress strings go to `log`.
    public func run(pageLimit: Int = 5000,
                    log: @Sendable (String) -> Void) async throws -> Result {
        var out = Result()
        try Task.checkCancellation()

        let hosts = try db.query("""
            SELECT \(ReportEngine.hostSQL) h, COUNT(*) c FROM visits
            WHERE lower(url) LIKE 'https://%' OR lower(url) LIKE 'http://%'
            GROUP BY h ORDER BY c DESC
        """).map { $0["h"]?.text ?? "" }
        // 'user' rows are manual overrides — never reclassify them.
        let knownD = Set(try db.query("SELECT host FROM domain_categories")
            .compactMap { $0["host"]?.text })
        let newHosts = hosts.filter { !$0.isEmpty && !knownD.contains($0) }
        if !newHosts.isEmpty {
            // Enrich bare hostnames with their top page titles — thin
            // inputs ("paddoxtechnologies.com") label poorly on their own.
            var inputs: [String] = []
            for h in newHosts {
                let tops = try db.query("""
                    SELECT MAX(title) t, COUNT(*) c FROM visits
                    WHERE \(ReportEngine.hostSQL) = ? AND title != ''
                    GROUP BY url ORDER BY c DESC LIMIT 3
                """, [.text(h)])
                let hint = tops.compactMap { $0["t"]?.text }
                    .map { String($0.prefix(60)) }
                    .joined(separator: " | ")
                let host = URL(string: "https://" + h)?.host ?? ""
                inputs.append("\(host) — \(hint.isEmpty ? host : String(hint.prefix(220)))")
            }
            let pairs = try await classify(texts: inputs,
                                   labels: Self.domainLabels, log: log)
            try db.writeTransaction {
                try Task.checkCancellation()
                for (i, p) in pairs.enumerated() {
                    try db.execute("""
                        INSERT OR REPLACE INTO domain_categories
                        (host, category, confidence) VALUES (?,?,?)
                    """, [.text(newHosts[i]), .text(p.1), .double(p.2)])
                }
            }
            out.domains = pairs.count
            log("\(pairs.count) domains classified")
        }

        let pages = try db.query("""
            SELECT url, MAX(title) t, COUNT(*) c FROM visits
            WHERE title != '' AND url LIKE 'http%'
            GROUP BY url ORDER BY c DESC LIMIT ?
        """, [.int(Int64(pageLimit))])
        let knownP = Set(try db.query("SELECT url FROM page_categories")
            .compactMap { $0["url"]?.text })
        let newPages = pages.compactMap { r -> (String, String)? in
            guard let u = r["url"]?.text, !u.isEmpty, !knownP.contains(u),
                  let t = r["t"]?.text, !t.isEmpty else { return nil }
            guard let input = Self.pageInput(url: u, title: t) else { return nil }
            return (u, input)
        }
        if !newPages.isEmpty {
            let pairs = try await classify(texts: newPages.map(\.1),
                                   labels: Self.pageLabels, log: log)
            try db.writeTransaction {
                try Task.checkCancellation()
                for (i, p) in pairs.enumerated() {
                    try db.execute("""
                        INSERT OR REPLACE INTO page_categories
                        (url, category, confidence) VALUES (?,?,?)
                    """, [.text(newPages[i].0), .text(p.1), .double(p.2)])
                }
            }
            out.pages = pairs.count
            log("\(pairs.count) pages classified")
        }

        let covered = try db.scalar("""
            SELECT COUNT(*) FROM visits v JOIN domain_categories c
            ON c.host = CASE WHEN v.url LIKE 'http%' THEN
                substr(substr(v.url, instr(v.url,'//')+2), 1,
                       instr(substr(v.url, instr(v.url,'//')+2)||'/', '/')-1)
                ELSE substr(v.url,1,40) END
        """, as: { $0.int }) ?? 0
        let tot = try db.scalar("SELECT COUNT(*) FROM visits",
                                as: { $0.int }) ?? 1
        out.coveragePct = 100.0 * Double(covered) / Double(tot)
        return out
    }

    private func classify(texts: [String], labels: [String],
                          log: @Sendable (String) -> Void) async throws
        -> [(String, String, Double)] {
        var out: [(String, String, Double)] = []
        for chunkStart in stride(from: 0, to: texts.count, by: 1000) {
            try Task.checkCancellation()
            let chunk = Array(texts[chunkStart..<min(chunkStart + 1000,
                                                    texts.count)])
            var req = URLRequest(url: Self.endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "inputs": chunk, "labels": labels])
            log("classifying \(chunk.count)…")
            let (data, resp) = try await transport(req)
            try Task.checkCancellation()
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200
            else {
                throw NSError(domain: "classifier", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                  "classifier.dev request failed"])
            }
            let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
            let results = json?["results"] as? [[String: Any]] ?? []
            guard results.count == chunk.count,
                  results.allSatisfy({ row in
                      guard let label = row["label"] as? String,
                            let confidence = row["confidence"] as? Double else { return false }
                      return labels.contains(label) && confidence.isFinite && (0...1).contains(confidence)
                  }) else {
                throw NSError(domain: "classifier", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid classifier response; no tags saved for this stage."])
            }
            for (i, r) in results.enumerated() {
                out.append((chunk[i],
                            r["label"] as? String ?? "other",
                            r["confidence"] as? Double ?? 0))
            }
        }
        return out
    }
}
