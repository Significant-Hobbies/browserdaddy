import Foundation

/// A unified host owns an independent archive. Copy the selected SQLite snapshot
/// with its committed WAL rows and publish the completed directory exclusively.
public enum BrowserWorkspaceArchive {
    public static func create(at directory: URL, importing source: URL? = nil) throws {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        // System-managed replacement storage is on the destination volume and
        // remains reclaimable if the process exits in the middle of a copy.
        let replacement = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                     appropriateFor: parent, create: true)
        defer { try? fm.removeItem(at: replacement) }
        let scratch = replacement.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = scratch.appendingPathComponent("browserdaddy.db")
        do {
            let destination = try ArchiveStore(url: file)
            if let source { try importSnapshot(source, into: destination.db) }
        }
        guard renamex_np(scratch.path, directory.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func importSnapshot(_ source: URL, into db: SQLiteStore) throws {
        try db.execute("PRAGMA trusted_schema=OFF")
        var uri = URLComponents(url: source, resolvingAgainstBaseURL: true)
        uri?.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let path = uri?.string else { throw CocoaError(.fileReadInvalidFileName) }
        try db.execute("ATTACH DATABASE ? AS original", [.text(path)])
        defer { _ = try? db.execute("DETACH DATABASE original") }
        let tables = ["visits", "focus", "meta", "searches", "domain_categories", "page_categories"]
        try db.writeTransaction {
            let original = try db.query("""
                SELECT name, type, sql FROM original.sqlite_master
                WHERE type != 'index' AND name NOT GLOB 'sqlite_*'
                """)
            let names = Set(original.compactMap { $0["name"]?.text })
            guard names.isSubset(of: Set(tables)), Set(["visits", "focus", "meta"]).isSubset(of: names),
                  original.allSatisfy({ row in
                      row["type"]?.text == "table" &&
                        row["sql"]?.text?.uppercased().hasPrefix("CREATE TABLE") == true
                  })
            else { throw CocoaError(.fileReadCorruptFile) }
            for table in tables where names.contains(table) {
                let expected = try db.query("PRAGMA main.table_info(\(table))").compactMap { $0["name"]?.text }
                let existing = Set(try db.query("PRAGMA original.table_xinfo(\(table))").compactMap { $0["name"]?.text })
                // Category provenance was added by migration. Older sources can
                // omit it. Unknown data requires a newer importer.
                guard existing.isSubset(of: Set(expected)),
                      Set(expected.filter { $0 != "source" }).isSubset(of: existing) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let columns = expected.filter { existing.contains($0) }.joined(separator: ", ")
                try db.execute("INSERT INTO main.\(table) (\(columns)) SELECT \(columns) FROM original.\(table)")
            }
            try db.execute("DELETE FROM meta WHERE key IN ('onboarded','classify_optin','classify_consent_version')")
        }
    }
}
