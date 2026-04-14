import Foundation
import SQLite3

/// Lightweight SQLite reader for VS Code-style state.vscdb databases.
enum SQLiteHelper {

    /// Read a string value from an ItemTable key-value store.
    static func readValue(dbPath: String, key: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        guard let cString = sqlite3_column_text(stmt, 0) else {
            return nil
        }

        return String(cString: cString)
    }

    /// Read multiple key-value pairs.
    static func readValues(dbPath: String, keys: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            if let value = readValue(dbPath: dbPath, key: key) {
                result[key] = value
            }
        }
        return result
    }
}
