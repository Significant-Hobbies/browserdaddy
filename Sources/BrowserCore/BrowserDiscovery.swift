import Foundation

/// Finds history stores only below browser roots explicitly selected by a user.
public enum BrowserDiscovery {
    public static func isValid(root: BrowserRoot) -> Bool {
        !discover(root: root).isEmpty
    }

    public static func discover(roots: [BrowserRoot]) -> [HistorySource] {
        roots.flatMap(discover(root:))
    }

    public static func discover(root: BrowserRoot) -> [HistorySource] {
        var sources: [HistorySource] = []
        let fm = FileManager.default
        let selected = root.url.standardizedFileURL.resolvingSymlinksInPath()

        switch root.kind {
        case .firefox:
            // The user may select either the Profiles folder or one profile dir.
            let own = selected.appendingPathComponent("places.sqlite")
            if isReadableDescendant(own, of: selected) {
                return [HistorySource(browser: root.kind.rawValue,
                    profile: selected.lastPathComponent, path: own, engine: .firefox)]
            }
            guard let profiles = try? fm.contentsOfDirectory(
                at: selected, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
            for profile in profiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let db = profile.appendingPathComponent("places.sqlite")
                if isReadableDescendant(db, of: selected) {
                    sources.append(HistorySource(browser: root.kind.rawValue,
                        profile: profile.lastPathComponent, path: db, engine: .firefox))
                }
            }
        case .safari:
            let db = selected.appendingPathComponent("History.db")
            if isReadableDescendant(db, of: selected) {
                sources.append(HistorySource(browser: root.kind.rawValue,
                    profile: "default", path: db, engine: .safari))
            }
        default:
            // Accept a profile dir itself (e.g. Chrome's "Default") — its
            // History file sits inside, not in a child folder.
            let own = selected.appendingPathComponent("History")
            if isReadableDescendant(own, of: selected) {
                return [HistorySource(browser: root.kind.rawValue,
                    profile: selected.lastPathComponent, path: own, engine: .chromium)]
            }
            let profiles: [URL]
            if root.kind == .opera {
                profiles = [selected]
            } else if let listing = try? fm.contentsOfDirectory(
                at: selected, includingPropertiesForKeys: [.isDirectoryKey]) {
                profiles = listing.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey])
                        .isDirectory) == true && !$0.lastPathComponent.hasPrefix(".")
                }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                return []
            }
            for profile in profiles {
                let db = profile.appendingPathComponent("History")
                if isReadableDescendant(db, of: selected) {
                    sources.append(HistorySource(browser: root.kind.rawValue,
                        profile: profile.lastPathComponent, path: db, engine: .chromium))
                }
            }
        }
        return sources
    }

    private static func isReadableDescendant(_ candidate: URL, of root: URL) -> Bool {
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return resolved.path.hasPrefix(rootPath)
            && FileManager.default.isReadableFile(atPath: resolved.path)
    }

    /// Copy the DB (+wal/shm) to a temp dir — a running browser's lock
    /// doesn't matter. A -journal sidecar is deliberately skipped: a hot
    /// journal would force recovery on open, which a read-only connection
    /// cannot perform.
    public static func snapshot(_ src: HistorySource, into tmp: URL) throws -> URL {
        let dst = tmp.appendingPathComponent(
            "\(src.browser)_\(src.profile.replacingOccurrences(of: " ", with: "_")).db")
        try FileManager.default.copyItem(at: src.path, to: dst)
        for suffix in ["-wal", "-shm"] {
            let side = src.path.deletingLastPathComponent()
                .appendingPathComponent(src.path.lastPathComponent + suffix)
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.copyItem(
                    at: side, to: dst.deletingLastPathComponent()
                        .appendingPathComponent(dst.lastPathComponent + suffix))
            }
        }
        return dst
    }
}
