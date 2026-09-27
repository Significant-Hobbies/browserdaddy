import Foundation

/// One-time import of the Python prototype archive
/// (~/browserdaddy/out/browserdaddy.db) — schema is identical, so this is a
/// straight INSERT OR IGNORE across all three tables.
public enum ArchiveImporter {
    public static let pythonDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("browserdaddy/out/browserdaddy.db")

    public static var needsImport: Bool {
        FileManager.default.fileExists(atPath: pythonDB.path)
    }

    @discardableResult
    public static func importIfNeeded(into store: ArchiveStore) throws -> Bool {
        let done = try store.db.scalar(
            "SELECT value FROM meta WHERE key='imported_python'",
            as: { $0.text })
        if done == "1" || !needsImport { return false }

        // ATTACH/DETACH can't run inside a BEGIN…COMMIT, so the write
        // transaction wraps only the copy statements. Missing tables in an
        // older prototype schema skip rather than failing the whole import.
        try store.db.transaction {
            try store.db.execute("ATTACH DATABASE ? AS old", [.text(pythonDB.path)])
            defer { _ = try? store.db.execute("DETACH DATABASE old") }
            let oldTables = Set(try store.db.query(
                "SELECT name FROM old.sqlite_master WHERE type='table'")
                .compactMap { $0["name"]?.text })
            try store.db.writeTransaction {
                if oldTables.contains("visits") {
                    try store.db.execute(
                        "INSERT OR IGNORE INTO visits SELECT * FROM old.visits")
                }
                if oldTables.contains("searches") {
                    try store.db.execute(
                        "INSERT OR IGNORE INTO searches SELECT * FROM old.searches")
                }
                if oldTables.contains("focus") {
                    try store.db.execute("""
                        INSERT OR IGNORE INTO focus
                        (start_utc, end_utc, app, url, title, ticks, active_s)
                        SELECT start_utc, end_utc, app, url, title, ticks, active_s
                        FROM old.focus
                    """)
                }
                try store.db.execute(
                    "INSERT OR REPLACE INTO meta (key, value) VALUES ('imported_python','1')")
            }
        }
        return true
    }
}
