import Foundation
import SQLite3

/// Resolves Box item IDs to on-disk paths inside the Box Drive mount, using Box
/// Drive's own local metadata. No Box API, no network, no credentials.
enum ResolveError: String, Error {
    case noSyncRoot = "no_sync_root"
    case boxNotRunning = "box_not_running"
    case notFound = "not_found"
    case outsideRoot = "outside_root"
}

/// Box stores files and folders in one ID namespace keyed by (box_id, item_type).
enum ItemType: Int32 {
    case file = 0
    case folder = 1
}

struct PathResolver {
    let syncRoot: URL
    private let db: OpaquePointer
    private let snapshotDir: URL

    /// Box Drive's data directory for the current user.
    static var dataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Box/Box/data")
    }

    /// The mount root, read from Box Drive's own preferences rather than guessed.
    /// Stale mounts like "Box-Box (3-20-25 11:29 AM)" sit alongside the live one,
    /// so globbing ~/Library/CloudStorage/Box-Box* would pick the wrong directory.
    static func readSyncRoot() -> URL? {
        guard let defaults = UserDefaults(suiteName: "com.box.desktop"),
              let path = defaults.string(forKey: "preferences/sync_directory_path"),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    init() throws {
        guard let root = PathResolver.readSyncRoot() else { throw ResolveError.noSyncRoot }
        syncRoot = root

        let fm = FileManager.default
        let source = PathResolver.dataDir.appendingPathComponent("sync.db")
        guard fm.fileExists(atPath: source.path) else { throw ResolveError.boxNotRunning }

        // sync.db is WAL-mode and held locked by the running Box Drive process.
        // A read-only open fails outright, and opening with immutable=1 silently
        // ignores the -wal file — which drops recently synced items on the floor.
        // Copying db + wal + shm and opening the copy replays the WAL and gives a
        // consistent, current snapshot.
        snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxreveal-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        for suffix in ["", "-wal", "-shm"] {
            let src = PathResolver.dataDir.appendingPathComponent("sync.db\(suffix)")
            guard fm.fileExists(atPath: src.path) else { continue }  // -wal/-shm may be absent
            let dst = snapshotDir.appendingPathComponent("sync.db\(suffix)")
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }

        var handle: OpaquePointer?
        let dbPath = snapshotDir.appendingPathComponent("sync.db").path
        // Read-write so SQLite is allowed to replay and checkpoint the copied WAL.
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle
        else {
            try? fm.removeItem(at: snapshotDir)
            throw ResolveError.boxNotRunning
        }
        db = handle
    }

    func close() {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: snapshotDir)
    }

    /// Walks the parent chain to the Box root (box_id '0') and returns the path
    /// components, outermost first.
    ///
    /// Ancestors are always matched with item_type = 1: only the starting item can
    /// be a file, and a file ID can collide with an unrelated folder ID.
    func pathComponents(id: String, type: ItemType) throws -> [String] {
        let sql = """
        WITH RECURSIVE up(box_id, name, parent_item_id, depth) AS (
            SELECT box_id, name, parent_item_id, 0
              FROM box_item WHERE box_id = ?1 AND item_type = ?2
            UNION ALL
            SELECT b.box_id, b.name, b.parent_item_id, up.depth + 1
              FROM box_item b
              JOIN up ON b.box_id = up.parent_item_id AND b.item_type = 1
             WHERE up.depth < 10000
        )
        SELECT name FROM up WHERE box_id != '0' ORDER BY depth DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ResolveError.notFound
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, type.rawValue)

        var parts: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: c)
            // Box should never hand back a name that can escape the mount, but a
            // corrupt row must not be able to walk us out of the sync root.
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw ResolveError.outsideRoot
            }
            parts.append(name)
        }
        guard !parts.isEmpty else { throw ResolveError.notFound }
        return parts
    }

    /// Full on-disk URL for an item. The path is confirmed to sit inside the sync
    /// root before it is handed back — the extension only ever supplies an ID, and
    /// this keeps a corrupt DB or a crafted message from turning the host into an
    /// arbitrary-path revealer.
    func resolve(id: String, type: ItemType) throws -> URL {
        let parts = try pathComponents(id: id, type: type)

        // Assembled as a string, and turned into a URL exactly once with an
        // explicit isDirectory. Both `appendPathComponent` and `standardizedFileURL`
        // stat the filesystem — the former to decide on a trailing slash — and on a
        // File Provider mount every one of those stats is a network round trip to
        // Box. Going through URL cost ~0.6s per lookup; this costs nothing.
        let rootPath = syncRoot.path
        let target = ([rootPath] + parts).joined(separator: "/")

        // Components are already validated as single, non-traversing segments, so a
        // string prefix check is sufficient to prove containment in the sync root.
        guard target == rootPath || target.hasPrefix(rootPath + "/") else {
            throw ResolveError.outsideRoot
        }
        return URL(fileURLWithPath: target, isDirectory: type == .folder)
    }

    /// Nearest ancestor of `url` that exists on disk, for folders Box knows about
    /// but has not materialized locally yet.
    func nearestExisting(_ url: URL) -> URL? {
        // String-based for the same reason as `resolve`: URL path manipulation on a
        // File Provider mount triggers filesystem round trips.
        let rootPath = syncRoot.path
        var candidate = url.path
        while candidate.hasPrefix(rootPath) && candidate != rootPath {
            if FileManager.default.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
            guard let slash = candidate.lastIndex(of: "/") else { break }
            candidate = String(candidate[candidate.startIndex..<slash])
        }
        return FileManager.default.fileExists(atPath: rootPath) ? syncRoot : nil
    }

    /// Random sample of items, used by --verify to check resolution against the
    /// real filesystem.
    func sampleItems(limit: Int) -> [(id: String, type: ItemType)] {
        let sql = """
        SELECT box_id, item_type FROM box_item
         WHERE box_id != '0' ORDER BY RANDOM() LIMIT ?1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [(String, ItemType)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0),
                  let t = ItemType(rawValue: sqlite3_column_int(stmt, 1))
            else { continue }
            out.append((String(cString: c), t))
        }
        return out
    }
}
