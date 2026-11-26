import Foundation

/// A unified host owns an independent archive. Copy the selected SQLite snapshot
/// with its committed WAL rows and publish the completed directory exclusively.
public enum BrowserWorkspaceArchive {
    public static func create(at directory: URL, importing source: URL? = nil) throws {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let scratch = parent.appendingPathComponent(".browser-import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("browserdaddy.db")
        if let source {
            let db = try SQLiteStore(url: source, readOnly: true)
            // BrowserDaddy archives contain plain tables/indexes. Refuse other
            // SQLite programs before executing any schema-dependent statements.
            let unsafe = try db.query("""
                SELECT 1 FROM sqlite_master WHERE type IN ('trigger', 'view')
                OR upper(ltrim(sql)) LIKE 'CREATE VIRTUAL%' LIMIT 1
                """)
            guard unsafe.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            try db.execute("VACUUM INTO ?", [.text(file.path)])
            let copied = try SQLiteStore(url: file)
            for sql in ["SELECT browser,profile,visit_id FROM visits LIMIT 0",
                        "SELECT start_utc,active_s FROM focus LIMIT 0",
                        "SELECT key,value FROM meta LIMIT 0"] {
                _ = try copied.query(sql)
            }
            guard try copied.query("PRAGMA quick_check").first?["quick_check"]?.text == "ok" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try copied.execute("DELETE FROM meta WHERE key IN ('onboarded','classify_optin','classify_consent_version')")
        }
        _ = try ArchiveStore(url: file)
        guard renamex_np(scratch.path, directory.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
