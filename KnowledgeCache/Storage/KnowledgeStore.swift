//
//  KnowledgeStore.swift
//  KnowledgeCache
//
//  CRUD for knowledge_items, chunks, and query_history. All local; no network.
//

import Foundation
import SQLite3

final class KnowledgeStore: @unchecked Sendable {
    struct StorageTotals {
        let itemsCount: Int
        let chunksCount: Int
        let rawBytesTotal: Int
        let storedBytesTotal: Int
    }

    private let db: Database

    init(db: Database) {
        self.db = db
    }

    // MARK: - SQLite bind helpers

    /// Bind a non-optional String to a parameter index. Uses SQLITE_TRANSIENT equivalent.
    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    /// Bind an optional String to a parameter index. Binds NULL if nil.
    private func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let v = value {
            bindText(stmt, index: index, value: v)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Bind a Data blob to a parameter index.
    private func bindBlob(_ stmt: OpaquePointer?, index: Int32, data: Data) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        data.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }

    // MARK: - Knowledge items

    func insert(item: KnowledgeItem, chunks: [(String, [Float])], modelId: String = "minilm-l6-v2-v1", embeddingDim: Int = 384) throws {
        try db.inTransaction {
            let insItem = try db.prepare("""
                INSERT INTO knowledge_items (id, title, url, raw_content, created_at, source_display, content_hash, was_truncated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insItem) }

            bindText(insItem, index: 1, value: item.id.uuidString)
            bindText(insItem, index: 2, value: item.title)
            bindOptionalText(insItem, index: 3, value: item.url)
            bindText(insItem, index: 4, value: item.rawContent)
            sqlite3_bind_double(insItem, 5, item.createdAt.timeIntervalSince1970)
            bindText(insItem, index: 6, value: item.sourceDisplay)
            bindOptionalText(insItem, index: 7, value: item.contentHash)
            sqlite3_bind_int(insItem, 8, item.wasTruncated ? 1 : 0)

            if sqlite3_step(insItem) != SQLITE_DONE {
                throw StoreError.insertFailed
            }

            let insChunk = try db.prepare("""
                INSERT INTO chunks (id, knowledge_item_id, "index", text, embedding_blob, embedding_model_id, embedding_dim)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insChunk) }

            for (idx, (text, embedding)) in chunks.enumerated() {
                sqlite3_reset(insChunk)
                bindText(insChunk, index: 1, value: UUID().uuidString)
                bindText(insChunk, index: 2, value: item.id.uuidString)
                sqlite3_bind_int(insChunk, 3, Int32(idx))
                bindText(insChunk, index: 4, value: text)
                let blob = floatsToBlob(embedding)
                bindBlob(insChunk, index: 5, data: blob)
                bindText(insChunk, index: 6, value: modelId)
                sqlite3_bind_int(insChunk, 7, Int32(embeddingDim))

                if sqlite3_step(insChunk) != SQLITE_DONE {
                    throw StoreError.insertFailed
                }
            }
        }
    }

    /// Find existing item by content hash (for dedupe). Returns first match.
    func findByContentHash(_ contentHash: String) throws -> KnowledgeItem? {
        let stmt = try db.prepare("SELECT id, title, url, raw_content, created_at, source_display, content_hash, was_truncated FROM knowledge_items WHERE content_hash = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: contentHash)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToKnowledgeItem(stmt)
    }

    func fetchAllItems() throws -> [KnowledgeItem] {
        let stmt = try db.prepare("SELECT id, title, url, raw_content, created_at, source_display, content_hash, was_truncated FROM knowledge_items ORDER BY created_at DESC")
        defer { sqlite3_finalize(stmt) }
        var items: [KnowledgeItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = rowToKnowledgeItem(stmt) { items.append(item) }
        }
        return items
    }

    func deleteItem(id: UUID) throws {
        try db.inTransaction {
            let delChunks = try db.prepare("DELETE FROM chunks WHERE knowledge_item_id = ?")
            defer { sqlite3_finalize(delChunks) }
            bindText(delChunks, index: 1, value: id.uuidString)
            sqlite3_step(delChunks)

            let delItem = try db.prepare("DELETE FROM knowledge_items WHERE id = ?")
            defer { sqlite3_finalize(delItem) }
            bindText(delItem, index: 1, value: id.uuidString)
            sqlite3_step(delItem)
        }
    }

    func itemExists(id: UUID) throws -> Bool {
        let stmt = try db.prepare("SELECT 1 FROM knowledge_items WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id.uuidString)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Chunks (for retrieval)

    struct ChunkRow {
        let id: String
        let knowledgeItemId: String
        let index: Int
        let text: String
        let embeddingBlob: Data
        let embeddingModelId: String
        let embeddingDim: Int
    }

    func fetchAllChunks() throws -> [ChunkRow] {
        let stmt = try db.prepare("SELECT id, knowledge_item_id, \"index\", text, embedding_blob, embedding_model_id, embedding_dim FROM chunks")
        defer { sqlite3_finalize(stmt) }
        var rows: [ChunkRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let knowledgeItemId = String(cString: sqlite3_column_text(stmt, 1))
            let index = Int(sqlite3_column_int(stmt, 2))
            let text = String(cString: sqlite3_column_text(stmt, 3))
            let blobLen = Int(sqlite3_column_bytes(stmt, 4))
            let blobPtr = sqlite3_column_blob(stmt, 4)!
            let blob = Data(bytes: blobPtr, count: blobLen)
            let modelId = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "minilm-l6-v2-v1"
            let dim = Int(sqlite3_column_int(stmt, 6))
            rows.append(ChunkRow(id: id, knowledgeItemId: knowledgeItemId, index: index, text: text, embeddingBlob: blob, embeddingModelId: modelId, embeddingDim: dim > 0 ? dim : 384))
        }
        return rows
    }

    /// Chunks for one item (for re-index).
    func fetchChunksForItem(knowledgeItemId: UUID) throws -> [(id: String, text: String)] {
        let stmt = try db.prepare("SELECT id, text FROM chunks WHERE knowledge_item_id = ? ORDER BY \"index\"")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: knowledgeItemId.uuidString)
        var out: [(id: String, text: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let text = String(cString: sqlite3_column_text(stmt, 1))
            out.append((id: id, text: text))
        }
        return out
    }

    func updateChunkEmbedding(chunkId: String, embeddingBlob: Data, modelId: String, embeddingDim: Int) throws {
        let stmt = try db.prepare("UPDATE chunks SET embedding_blob = ?, embedding_model_id = ?, embedding_dim = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindBlob(stmt, index: 1, data: embeddingBlob)
        bindText(stmt, index: 2, value: modelId)
        sqlite3_bind_int(stmt, 3, Int32(embeddingDim))
        bindText(stmt, index: 4, value: chunkId)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.insertFailed
        }
    }

    func optimizeStorage() throws {
        try db.optimizeStorage()
    }

    func fetchStorageTotals() throws -> StorageTotals {
        let itemsStmt = try db.prepare("SELECT COUNT(*), COALESCE(SUM(LENGTH(raw_content)), 0) FROM knowledge_items")
        defer { sqlite3_finalize(itemsStmt) }
        let chunksStmt = try db.prepare("SELECT COUNT(*), COALESCE(SUM(LENGTH(text) + LENGTH(embedding_blob)), 0) FROM chunks")
        defer { sqlite3_finalize(chunksStmt) }

        var itemsCount = 0
        var rawBytes = 0
        if sqlite3_step(itemsStmt) == SQLITE_ROW {
            itemsCount = Int(sqlite3_column_int64(itemsStmt, 0))
            rawBytes = Int(sqlite3_column_int64(itemsStmt, 1))
        }

        var chunksCount = 0
        var chunkStoredBytes = 0
        if sqlite3_step(chunksStmt) == SQLITE_ROW {
            chunksCount = Int(sqlite3_column_int64(chunksStmt, 0))
            chunkStoredBytes = Int(sqlite3_column_int64(chunksStmt, 1))
        }

        let storedBytesTotal = rawBytes + chunkStoredBytes
        return StorageTotals(
            itemsCount: itemsCount,
            chunksCount: chunksCount,
            rawBytesTotal: rawBytes,
            storedBytesTotal: storedBytesTotal
        )
    }

    func fetchItem(id: UUID) throws -> KnowledgeItem? {
        let stmt = try db.prepare("SELECT id, title, url, raw_content, created_at, source_display, content_hash, was_truncated FROM knowledge_items WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToKnowledgeItem(stmt)
    }

    private func rowToKnowledgeItem(_ stmt: OpaquePointer?) -> KnowledgeItem? {
        guard let stmt = stmt else { return nil }
        let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
        let title = String(cString: sqlite3_column_text(stmt, 1))
        let url = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let rawContent = String(cString: sqlite3_column_text(stmt, 3))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        let sourceDisplay = String(cString: sqlite3_column_text(stmt, 5))
        let contentHash = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let wasTruncated = sqlite3_column_int(stmt, 7) != 0
        return KnowledgeItem(id: id, title: title, url: url, rawContent: rawContent, createdAt: createdAt, sourceDisplay: sourceDisplay, contentHash: contentHash, wasTruncated: wasTruncated)
    }

    // MARK: - Query history

    func insertHistory(item: QueryHistoryItem) throws {
        let enc = JSONEncoder()
        let sourcesData = try enc.encode(item.sources)
        let sourcesJson = String(data: sourcesData, encoding: .utf8) ?? "[]"
        let stmt = try db.prepare("INSERT INTO query_history (id, question, answer_text, created_at, sources_json) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: item.id.uuidString)
        bindText(stmt, index: 2, value: item.question)
        bindText(stmt, index: 3, value: item.answerText)
        sqlite3_bind_double(stmt, 4, item.createdAt.timeIntervalSince1970)
        bindText(stmt, index: 5, value: sourcesJson)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.insertFailed
        }
    }

    func fetchHistory() throws -> [QueryHistoryItem] {
        let stmt = try db.prepare("SELECT id, question, answer_text, created_at, sources_json FROM query_history ORDER BY created_at DESC")
        defer { sqlite3_finalize(stmt) }
        let dec = JSONDecoder()
        var items: [QueryHistoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let question = String(cString: sqlite3_column_text(stmt, 1))
            let answerText = String(cString: sqlite3_column_text(stmt, 2))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            var sources: [SourceRef] = []
            if let jsonPtr = sqlite3_column_text(stmt, 4) {
                let json = String(cString: jsonPtr)
                if let data = json.data(using: .utf8), let decoded = try? dec.decode([SourceRef].self, from: data) {
                    sources = decoded
                }
            }
            items.append(QueryHistoryItem(id: id, question: question, answerText: answerText, sources: sources, createdAt: createdAt))
        }
        return items
    }

    // MARK: - Helpers

    private func floatsToBlob(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }
}

enum StoreError: Error {
    case insertFailed
}
