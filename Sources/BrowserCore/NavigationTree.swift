import Foundation

/// A local, read-only view of the links recorded by a browser history store.
/// The path above the selected visit and its descendants are the only visits
/// shown; unrelated branches elsewhere in the browsing session are omitted.
public struct NavigationTree: Sendable {
    public struct Node: Identifiable, Sendable {
        public let visitID: Int64
        public let parentID: Int64?
        public let title: String
        public let url: String
        public let visitedAt: Date?
        public let depth: Int
        public let isSelected: Bool

        public var id: Int64 { visitID }
    }

    public let nodes: [Node]
    public let missingParentID: Int64?
    public let cycleDetected: Bool
    public let truncated: Bool
}

extension ArchiveStore {
    /// Visit IDs are scoped to one browser/profile. Never infer a link from a
    /// matching ID in another source, or from a URL match.
    public func navigationTree(browser: String, profile: String,
                               visitID: Int64) throws -> NavigationTree? {
        struct Visit {
            let id: Int64
            let parent: Int64?
            let title: String
            let url: String
            let time: Date?
        }

        func positiveID(_ value: DBValue?) -> Int64? {
            guard case .int(let id) = value, id > 0 else { return nil }
            return id
        }

        func visit(_ id: Int64) throws -> Visit? {
            try db.query("""
                SELECT visit_id, from_visit, title, url, visit_time_utc
                FROM visits WHERE browser = ? AND profile = ? AND visit_id = ?
                  AND typeof(visit_id) = 'integer'
            """, [.text(browser), .text(profile), .int(id)]).first.flatMap { row in
                guard let visitID = positiveID(row["visit_id"]) else { return nil }
                return Visit(id: visitID,
                             parent: positiveID(row["from_visit"]),
                             title: row["title"]?.text ?? "",
                             url: row["url"]?.text ?? "",
                             time: ISO8601.parse(row["visit_time_utc"]?.text ?? ""))
            }
        }

        guard visitID > 0 else { return nil }
        guard let selected = try visit(visitID) else { return nil }
        var ancestors = [selected]
        var seen: Set<Int64> = [visitID]
        var missingParentID: Int64?
        var cycleDetected = false
        var truncated = false
        while let parent = ancestors.last?.parent {
            if seen.contains(parent) {
                cycleDetected = true
                break
            }
            if ancestors.count >= 64 {
                truncated = true
                break
            }
            guard let next = try visit(parent) else {
                missingParentID = parent
                break
            }
            seen.insert(parent)
            ancestors.append(next)
        }

        let path = ancestors.reversed().enumerated().map { depth, item in
            NavigationTree.Node(visitID: item.id, parentID: item.parent,
                                title: item.title, url: item.url,
                                visitedAt: item.time, depth: depth,
                                isSelected: item.id == visitID)
        }

        // One extra row detects a real visit-count limit, and depth 33 detects
        // children beyond the 32-step display limit. The slash-delimited path
        // prevents cycle expansion without inventing links to malformed IDs.
        let rows = try db.query("""
            WITH RECURSIVE descendants(visit_id, from_visit, title, url,
                                       visit_time_utc, depth, path) AS (
                SELECT visit_id, from_visit, title, url, visit_time_utc, 0,
                       printf('/%lld/', visit_id)
                FROM visits
                WHERE browser = ? AND profile = ? AND visit_id = ?
                  AND typeof(visit_id) = 'integer' AND visit_id > 0
                UNION ALL
                SELECT child.visit_id, child.from_visit, child.title, child.url,
                       child.visit_time_utc, parent.depth + 1,
                       parent.path || child.visit_id || '/'
                FROM visits child JOIN descendants parent
                  ON child.from_visit = parent.visit_id
                WHERE child.browser = ? AND child.profile = ?
                  AND typeof(child.visit_id) = 'integer' AND child.visit_id > 0
                  AND typeof(child.from_visit) = 'integer' AND child.from_visit > 0
                  AND parent.depth < 33
                  AND instr(parent.path, '/' || child.visit_id || '/') = 0
                ORDER BY 6 ASC, 1 ASC
                LIMIT 252
            )
            SELECT visit_id, from_visit, title, url, visit_time_utc, depth
            FROM descendants
        """, [.text(browser), .text(profile), .int(visitID),
              .text(browser), .text(profile)])

        struct Descendant {
            let visit: Visit
            let depth: Int
        }
        let descendants = rows.dropFirst().compactMap { row -> Descendant? in
            guard let id = positiveID(row["visit_id"]),
                  let parent = positiveID(row["from_visit"]) else { return nil }
            return Descendant(visit: Visit(
                id: id,
                parent: parent,
                title: row["title"]?.text ?? "",
                url: row["url"]?.text ?? "",
                time: ISO8601.parse(row["visit_time_utc"]?.text ?? "")),
                depth: Int(row["depth"]?.int ?? 0))
        }
        var children: [Int64: [Descendant]] = [:]
        let ancestorIDs = Set(ancestors.map(\.id))
        for child in descendants.filter({ $0.depth <= 32 }).prefix(250) {
            if ancestorIDs.contains(child.visit.id) { continue }
            if let parent = child.visit.parent {
                children[parent, default: []].append(child)
            }
        }
        for parent in children.keys {
            children[parent]?.sort {
                if $0.visit.time != $1.visit.time {
                    return ($0.visit.time ?? .distantPast) < ($1.visit.time ?? .distantPast)
                }
                return $0.visit.id < $1.visit.id
            }
        }
        var nodes = path
        func appendChildren(of id: Int64, depth: Int) {
            for child in children[id] ?? [] {
                nodes.append(.init(visitID: child.visit.id,
                                   parentID: child.visit.parent,
                                   title: child.visit.title, url: child.visit.url,
                                   visitedAt: child.visit.time, depth: depth,
                                   isSelected: false))
                appendChildren(of: child.visit.id, depth: depth + 1)
            }
        }
        appendChildren(of: visitID, depth: path.count)
        return NavigationTree(nodes: nodes, missingParentID: missingParentID,
                              cycleDetected: cycleDetected,
                              truncated: truncated || rows.count > 251
                                  || descendants.contains(where: { $0.depth > 32 }))
    }
}
