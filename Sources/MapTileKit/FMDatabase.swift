//
//  FMDatabase.swift
//  MapTileKit
//
//  Minimal Swift SQLite wrapper covering the subset of the FMDB API this app
//  actually uses (open a database by path, run a query, walk the result rows,
//  read a blob column) rather than a line-for-line port of the full library.
//

import Foundation
import SQLite3

final class FMResultSet {
    private let statement: OpaquePointer
    private let ownsStatement: Bool

    fileprivate init(statement: OpaquePointer, ownsStatement: Bool) {
        self.statement = statement
        self.ownsStatement = ownsStatement
    }

    deinit {
        if ownsStatement {
            sqlite3_finalize(statement)
        }
    }

    func next() -> Bool {
        sqlite3_step(statement) == SQLITE_ROW
    }

    func data(forColumn columnName: String) -> Data? {
        guard let index = columnIndex(for: columnName) else { return nil }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: length)
    }

    private func columnIndex(for columnName: String) -> Int32? {
        let count = sqlite3_column_count(statement)
        for i in 0..<count {
            if let name = sqlite3_column_name(statement, i), String(cString: name) == columnName {
                return i
            }
        }
        return nil
    }
}

final class FMDatabase {
    private let path: String
    private var db: OpaquePointer?

    // Tile lookups reuse the same handful of queries (with different bound
    // values) on every draw call, so the compiled statement is kept around
    // and re-bound rather than re-parsed from SQL text each time.
    private var cachedStatements: [String: OpaquePointer] = [:]

    init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    @discardableResult
    func open() -> Bool {
        // The mbtiles file is bundled, read-only content - opening read-only
        // skips SQLite's write-path setup (rollback journal checks, etc.),
        // which also matters on-device where the app bundle isn't writable.
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
    }

    func close() {
        for (_, statement) in cachedStatements {
            sqlite3_finalize(statement)
        }
        cachedStatements.removeAll()
        guard let db = db else { return }
        sqlite3_close_v2(db)
        self.db = nil
    }

    /// Runs `sql` (with `?` placeholders) bound to `bindings`, reusing a
    /// cached compiled statement for the same SQL text across calls.
    func executeQuery(_ sql: String, bindings: [Int32] = []) -> FMResultSet? {
        guard let db = db else { return nil }

        let statement: OpaquePointer
        if let cached = cachedStatements[sql] {
            statement = cached
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        } else {
            var newStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &newStatement, nil) == SQLITE_OK, let prepared = newStatement else {
                return nil
            }
            statement = prepared
            cachedStatements[sql] = statement
        }

        for (i, value) in bindings.enumerated() {
            sqlite3_bind_int(statement, Int32(i + 1), value)
        }

        return FMResultSet(statement: statement, ownsStatement: false)
    }
}
