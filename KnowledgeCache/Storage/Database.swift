//
//  Database.swift
//  KnowledgeCache
//
//  SQLite connection and schema (PRAGMA user_version for migrations).
//

import Foundation
import SQLite3

final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let path: String

    static let schemaVersion: Int32 = 5

    init(path: String) {
        self.path = path
    }

    func open() throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw DatabaseError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try execute("PRAGMA foreign_keys = ON")
        try runMigrationsIfNeeded()
    }

    /// Optimize storage: PRAGMA optimize; VACUUM. Run optionally (e.g. from settings).
    func optimizeStorage() throws {
        try execute("PRAGMA optimize")
        try execute("VACUUM")
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    private func runMigrationsIfNeeded() throws {
        let current = try getSchemaVersion()
        if current < Database.schemaVersion {
            try runMigrations(from: current, to: Database.schemaVersion)
            try setSchemaVersion(Database.schemaVersion)
        }
    }

    private func getSchemaVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0)
        }
        return 0
    }

    private func setSchemaVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    private func runMigrations(from current: Int32, to target: Int32) throws {
        if current < 1 && target >= 1 {
            try execute("""
                CREATE TABLE IF NOT EXISTS knowledge_items (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    url TEXT,
                    raw_content TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    source_display TEXT NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_knowledge_items_created_at ON knowledge_items(created_at)")
            try execute("""
                CREATE TABLE IF NOT EXISTS chunks (
                    id TEXT PRIMARY KEY,
                    knowledge_item_id TEXT NOT NULL REFERENCES knowledge_items(id) ON DELETE CASCADE,
                    \"index\" INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    embedding_blob BLOB NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_chunks_knowledge_item_id ON chunks(knowledge_item_id)")
            try execute("""
                CREATE TABLE IF NOT EXISTS query_history (
                    id TEXT PRIMARY KEY,
                    question TEXT NOT NULL,
                    answer_text TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    sources_json TEXT
                )
                """)
        }
        if current < 2 && target >= 2 {
            try execute("ALTER TABLE knowledge_items ADD COLUMN content_hash TEXT")
            try execute("ALTER TABLE knowledge_items ADD COLUMN was_truncated INTEGER NOT NULL DEFAULT 0")
            try execute("CREATE INDEX IF NOT EXISTS idx_knowledge_items_content_hash ON knowledge_items(content_hash)")
            try execute("ALTER TABLE chunks ADD COLUMN embedding_model_id TEXT NOT NULL DEFAULT 'apple-nlembedding-en-v1'")
            try execute("ALTER TABLE chunks ADD COLUMN embedding_dim INTEGER NOT NULL DEFAULT 512")
        }
        if current < 3 && target >= 3 {
            try execute("ALTER TABLE knowledge_items ADD COLUMN canonical_url TEXT")
            try execute("ALTER TABLE knowledge_items ADD COLUMN saved_from TEXT NOT NULL DEFAULT 'manual'")
            try execute("ALTER TABLE knowledge_items ADD COLUMN saved_at REAL")
            try execute("ALTER TABLE knowledge_items ADD COLUMN snapshot_version INTEGER NOT NULL DEFAULT 1")
            try execute("ALTER TABLE knowledge_items ADD COLUMN full_snapshot_path TEXT")

            try execute("""
                CREATE TABLE IF NOT EXISTS page_visits (
                    id TEXT PRIMARY KEY,
                    url TEXT NOT NULL,
                    tab_id TEXT,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    dwell_ms INTEGER NOT NULL DEFAULT 0,
                    scroll_pct REAL NOT NULL DEFAULT 0
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_page_visits_url ON page_visits(url)")
            try execute("CREATE INDEX IF NOT EXISTS idx_page_visits_started_at ON page_visits(started_at)")

            try execute("""
                CREATE TABLE IF NOT EXISTS snapshots (
                    id TEXT PRIMARY KEY,
                    knowledge_item_id TEXT NOT NULL REFERENCES knowledge_items(id) ON DELETE CASCADE,
                    type TEXT NOT NULL,
                    path TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL DEFAULT 0,
                    content_hash TEXT,
                    created_at REAL NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_snapshots_item_id ON snapshots(knowledge_item_id)")
            try execute("CREATE INDEX IF NOT EXISTS idx_snapshots_type ON snapshots(type)")

            try execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                    chunk_id UNINDEXED,
                    title,
                    source_display,
                    text
                )
                """)
            try execute("""
                INSERT INTO chunks_fts (chunk_id, title, source_display, text)
                SELECT c.id, k.title, k.source_display, c.text
                FROM chunks c
                JOIN knowledge_items k ON k.id = c.knowledge_item_id
                """)
            try execute("""
                CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
                    INSERT INTO chunks_fts (chunk_id, title, source_display, text)
                    SELECT NEW.id, k.title, k.source_display, NEW.text
                    FROM knowledge_items k
                    WHERE k.id = NEW.knowledge_item_id;
                END
                """)
            try execute("""
                CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
                    DELETE FROM chunks_fts WHERE chunk_id = OLD.id;
                END
                """)
            try execute("""
                CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
                    DELETE FROM chunks_fts WHERE chunk_id = OLD.id;
                    INSERT INTO chunks_fts (chunk_id, title, source_display, text)
                    SELECT NEW.id, k.title, k.source_display, NEW.text
                    FROM knowledge_items k
                    WHERE k.id = NEW.knowledge_item_id;
                END
                """)
        }
        if current < 4 && target >= 4 {
            try execute("""
                CREATE TABLE IF NOT EXISTS chat_threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    last_message_preview TEXT NOT NULL DEFAULT ''
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_chat_threads_updated_at ON chat_threads(updated_at DESC)")

            try execute("""
                CREATE TABLE IF NOT EXISTS chat_messages (
                    id TEXT PRIMARY KEY,
                    thread_id TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    sources_json TEXT,
                    suggestions_json TEXT
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS idx_chat_messages_thread_created ON chat_messages(thread_id, created_at)")
        }
        if current < 5 && target >= 5 {
            try execute("CREATE TABLE IF NOT EXISTS chat_threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, last_message_preview TEXT NOT NULL DEFAULT '', archived_at REAL)")
            if !table("chat_threads", hasColumn: "archived_at") {
                try execute("ALTER TABLE chat_threads ADD COLUMN archived_at REAL")
            }
            try execute("CREATE INDEX IF NOT EXISTS idx_chat_threads_archived_at ON chat_threads(archived_at)")
        }
    }

    private func table(_ tableName: String, hasColumn columnName: String) -> Bool {
        guard let stmt = try? prepare("PRAGMA table_info(\(tableName))") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1) {
                if String(cString: namePtr) == columnName {
                    return true
                }
            }
        }
        return false
    }

    func execute(_ sql: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return s
    }

    func inTransaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN TRANSACTION")
        do {
            let result = try block()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var connection: OpaquePointer? { db }
}

enum DatabaseError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case execFailed(String)
}
