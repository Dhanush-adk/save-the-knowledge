//
//  DatabaseMigrationSafetyTests.swift
//  KnowledgeCacheTests
//
//  Migration safety coverage for partially applied schema states.
//

import XCTest
import SQLite3
@testable import KnowledgeCache

final class DatabaseMigrationSafetyTests: XCTestCase {

    func testOpenResumesFromPartiallyAppliedV3Columns() throws {
        let path = NSTemporaryDirectory() + "test_migration_partial_\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedV2SchemaWithPartialV3Column(path: path)

        let db = Database(path: path)
        XCTAssertNoThrow(try db.open())
        defer { db.close() }

        let versionStmt = try db.prepare("PRAGMA user_version")
        defer { sqlite3_finalize(versionStmt) }
        XCTAssertEqual(sqlite3_step(versionStmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(versionStmt, 0), Database.schemaVersion)

        XCTAssertTrue(hasColumn(db: db, table: "knowledge_items", column: "canonical_url"))
        XCTAssertTrue(hasColumn(db: db, table: "knowledge_items", column: "saved_from"))
        XCTAssertTrue(hasColumn(db: db, table: "knowledge_items", column: "saved_at"))
        XCTAssertTrue(hasColumn(db: db, table: "chat_threads", column: "archived_at"))
    }

    private func seedV2SchemaWithPartialV3Column(path: String) throws {
        var conn: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &conn), SQLITE_OK)
        guard let conn else { XCTFail("sqlite open failed"); return }
        defer { sqlite3_close(conn) }

        try exec(conn, """
            CREATE TABLE knowledge_items (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                url TEXT,
                raw_content TEXT NOT NULL,
                created_at REAL NOT NULL,
                source_display TEXT NOT NULL,
                content_hash TEXT,
                was_truncated INTEGER NOT NULL DEFAULT 0
            );
            """)
        try exec(conn, """
            CREATE TABLE chunks (
                id TEXT PRIMARY KEY,
                knowledge_item_id TEXT NOT NULL REFERENCES knowledge_items(id) ON DELETE CASCADE,
                "index" INTEGER NOT NULL,
                text TEXT NOT NULL,
                embedding_blob BLOB NOT NULL,
                embedding_model_id TEXT NOT NULL DEFAULT 'apple-nlembedding-en-v1',
                embedding_dim INTEGER NOT NULL DEFAULT 512
            );
            """)
        try exec(conn, """
            CREATE TABLE query_history (
                id TEXT PRIMARY KEY,
                question TEXT NOT NULL,
                answer_text TEXT NOT NULL,
                created_at REAL NOT NULL,
                sources_json TEXT
            );
            """)

        // Simulate crash/interruption: one v3 column exists but user_version is still 2.
        try exec(conn, "ALTER TABLE knowledge_items ADD COLUMN canonical_url TEXT;")
        try exec(conn, "PRAGMA user_version = 2;")
    }

    private func exec(_ conn: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(conn, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite error \(rc)"
            sqlite3_free(err)
            XCTFail("SQL failed: \(msg)")
            throw NSError(domain: "DatabaseMigrationSafetyTests", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func hasColumn(db: Database, table: String, column: String) -> Bool {
        guard let stmt = try? db.prepare("PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1),
               String(cString: namePtr) == column {
                return true
            }
        }
        return false
    }
}
