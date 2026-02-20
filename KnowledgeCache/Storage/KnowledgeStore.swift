//
//  KnowledgeStore.swift
//  KnowledgeCache
//
//  CRUD for knowledge_items, chunks, and query_history. All local; no network.
//

import Foundation
import SQLite3

final class KnowledgeStore: @unchecked Sendable {
    struct ChatAnalyticsSummary {
        let activeThreads: Int
        let archivedThreads: Int
        let totalMessages: Int
        let userMessages: Int
        let assistantMessages: Int
        let assistantMessagesWithSources: Int
        let sourceHitRate: Double
        let avgMessagesPerActiveThread: Double
        let mostRecentMessageAt: Date?
    }

    struct ChatThreadStat: Identifiable {
        let thread: ChatThread
        let messageCount: Int
        let userMessageCount: Int
        let assistantMessageCount: Int

        var id: UUID { thread.id }
    }

    struct StorageTotals {
        let itemsCount: Int
        let chunksCount: Int
        let rawBytesTotal: Int
        let storedBytesTotal: Int
    }

    struct PageVisit: Sendable {
        let id: UUID
        let url: String
        let tabId: UUID?
        let startedAt: Date
        let endedAt: Date?
        let dwellMs: Int
        let scrollPct: Double
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

    func updateItemCaptureMetadata(
        itemId: UUID,
        canonicalURL: String?,
        savedFrom: String,
        savedAt: Date,
        fullSnapshotPath: String?
    ) throws {
        let stmt = try db.prepare("""
            UPDATE knowledge_items
            SET canonical_url = ?, saved_from = ?, saved_at = ?, full_snapshot_path = ?
            WHERE id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        bindOptionalText(stmt, index: 1, value: canonicalURL)
        bindText(stmt, index: 2, value: savedFrom)
        sqlite3_bind_double(stmt, 3, savedAt.timeIntervalSince1970)
        bindOptionalText(stmt, index: 4, value: fullSnapshotPath)
        bindText(stmt, index: 5, value: itemId.uuidString)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.insertFailed
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

    func searchChunksFTS(query: String, limit: Int = 40) throws -> [(chunkId: String, rank: Double)] {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace }
            .map { String($0).replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return [] }

        let stmt = try db.prepare("""
            SELECT chunk_id, bm25(chunks_fts) AS rank
            FROM chunks_fts
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: normalized)
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))
        var out: [(chunkId: String, rank: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let chunkPtr = sqlite3_column_text(stmt, 0) else { continue }
            let chunkId = String(cString: chunkPtr)
            let rank = sqlite3_column_double(stmt, 1)
            out.append((chunkId: chunkId, rank: rank))
        }
        return out
    }

    func insertPageVisit(_ visit: PageVisit) throws {
        let stmt = try db.prepare("""
            INSERT INTO page_visits (id, url, tab_id, started_at, ended_at, dwell_ms, scroll_pct)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: visit.id.uuidString)
        bindText(stmt, index: 2, value: visit.url)
        bindOptionalText(stmt, index: 3, value: visit.tabId?.uuidString)
        sqlite3_bind_double(stmt, 4, visit.startedAt.timeIntervalSince1970)
        if let endedAt = visit.endedAt {
            sqlite3_bind_double(stmt, 5, endedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_int(stmt, 6, Int32(max(0, visit.dwellMs)))
        sqlite3_bind_double(stmt, 7, max(0, min(100, visit.scrollPct)))
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.insertFailed
        }
    }

    func insertSnapshot(
        itemId: UUID,
        type: String,
        path: String,
        sizeBytes: Int,
        contentHash: String?
    ) throws {
        let stmt = try db.prepare("""
            INSERT INTO snapshots (id, knowledge_item_id, type, path, size_bytes, content_hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: UUID().uuidString)
        bindText(stmt, index: 2, value: itemId.uuidString)
        bindText(stmt, index: 3, value: type)
        bindText(stmt, index: 4, value: path)
        sqlite3_bind_int64(stmt, 5, sqlite3_int64(max(0, sizeBytes)))
        bindOptionalText(stmt, index: 6, value: contentHash)
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
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

    // MARK: - Chat threads/messages

    func insertChatThread(_ thread: ChatThread) throws {
        let stmt = try db.prepare("""
            INSERT INTO chat_threads (id, title, created_at, updated_at, last_message_preview, archived_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: thread.id.uuidString)
        bindText(stmt, index: 2, value: thread.title)
        sqlite3_bind_double(stmt, 3, thread.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, thread.updatedAt.timeIntervalSince1970)
        bindText(stmt, index: 5, value: thread.lastMessagePreview)
        if let archivedAt = thread.archivedAt {
            sqlite3_bind_double(stmt, 6, archivedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.insertFailed
        }
    }

    func updateChatThread(
        threadId: UUID,
        title: String? = nil,
        updatedAt: Date = Date(),
        lastMessagePreview: String? = nil,
        archivedAt: Date? = nil
    ) throws {
        let stmt = try db.prepare("""
            UPDATE chat_threads
            SET title = COALESCE(?, title),
                updated_at = ?,
                last_message_preview = COALESCE(?, last_message_preview),
                archived_at = COALESCE(?, archived_at)
            WHERE id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        bindOptionalText(stmt, index: 1, value: title)
        sqlite3_bind_double(stmt, 2, updatedAt.timeIntervalSince1970)
        bindOptionalText(stmt, index: 3, value: lastMessagePreview)
        if let archivedAt {
            sqlite3_bind_double(stmt, 4, archivedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        bindText(stmt, index: 5, value: threadId.uuidString)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.insertFailed
        }
    }

    func fetchChatThreads(limit: Int = 200) throws -> [ChatThread] {
        let stmt = try db.prepare("""
            SELECT id, title, created_at, updated_at, last_message_preview, archived_at
            FROM chat_threads
            WHERE archived_at IS NULL
            ORDER BY updated_at DESC
            LIMIT ?
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))
        var out: [ChatThread] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let preview = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let archivedAt: Date?
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                archivedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            } else {
                archivedAt = nil
            }
            out.append(
                ChatThread(
                    id: id,
                    title: title,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    lastMessagePreview: preview,
                    archivedAt: archivedAt
                )
            )
        }
        return out
    }

    func fetchArchivedChatThreads(limit: Int = 200) throws -> [ChatThread] {
        let stmt = try db.prepare("""
            SELECT id, title, created_at, updated_at, last_message_preview, archived_at
            FROM chat_threads
            WHERE archived_at IS NOT NULL
            ORDER BY archived_at DESC, updated_at DESC
            LIMIT ?
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))
        var out: [ChatThread] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let preview = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let archivedAt: Date?
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                archivedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            } else {
                archivedAt = nil
            }
            out.append(
                ChatThread(
                    id: id,
                    title: title,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    lastMessagePreview: preview,
                    archivedAt: archivedAt
                )
            )
        }
        return out
    }

    func deleteChatThread(threadId: UUID) throws {
        let stmt = try db.prepare("DELETE FROM chat_threads WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: threadId.uuidString)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.insertFailed
        }
    }

    func archiveChatThread(threadId: UUID, at date: Date = Date()) throws {
        let stmt = try db.prepare("""
            UPDATE chat_threads
            SET archived_at = ?, updated_at = ?
            WHERE id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
        bindText(stmt, index: 3, value: threadId.uuidString)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.insertFailed
        }
    }

    func unarchiveChatThread(threadId: UUID, at date: Date = Date()) throws {
        let stmt = try db.prepare("""
            UPDATE chat_threads
            SET archived_at = NULL, updated_at = ?
            WHERE id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        bindText(stmt, index: 2, value: threadId.uuidString)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.insertFailed
        }
    }

    func insertChatMessage(_ message: ChatMessage) throws {
        let enc = JSONEncoder()
        let sourcesData = try enc.encode(message.sources)
        let suggestionsData = try enc.encode(message.suggestions)
        let sourcesJson = String(data: sourcesData, encoding: .utf8) ?? "[]"
        let suggestionsJson = String(data: suggestionsData, encoding: .utf8) ?? "[]"

        try db.inTransaction {
            let stmt = try db.prepare("""
                INSERT INTO chat_messages (id, thread_id, role, content, created_at, sources_json, suggestions_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: message.id.uuidString)
            bindText(stmt, index: 2, value: message.threadId.uuidString)
            bindText(stmt, index: 3, value: message.role.rawValue)
            bindText(stmt, index: 4, value: message.content)
            sqlite3_bind_double(stmt, 5, message.createdAt.timeIntervalSince1970)
            bindText(stmt, index: 6, value: sourcesJson)
            bindText(stmt, index: 7, value: suggestionsJson)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw StoreError.insertFailed
            }

            let preview = message.content.replacingOccurrences(of: "\n", with: " ")
            let truncatedPreview = String(preview.prefix(140))
            try updateChatThread(
                threadId: message.threadId,
                updatedAt: message.createdAt,
                lastMessagePreview: truncatedPreview
            )
        }
    }

    func fetchChatMessages(threadId: UUID) throws -> [ChatMessage] {
        let stmt = try db.prepare("""
            SELECT id, thread_id, role, content, created_at, sources_json, suggestions_json
            FROM chat_messages
            WHERE thread_id = ?
            ORDER BY created_at ASC
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: threadId.uuidString)
        let dec = JSONDecoder()
        var out: [ChatMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let tid = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 1))) ?? threadId
            let roleRaw = String(cString: sqlite3_column_text(stmt, 2))
            let role = ChatRole(rawValue: roleRaw) ?? .assistant
            let content = String(cString: sqlite3_column_text(stmt, 3))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            var sources: [SourceRef] = []
            var suggestions: [String] = []
            if let sourcesPtr = sqlite3_column_text(stmt, 5),
               let data = String(cString: sourcesPtr).data(using: .utf8),
               let decoded = try? dec.decode([SourceRef].self, from: data) {
                sources = decoded
            }
            if let suggestionsPtr = sqlite3_column_text(stmt, 6),
               let data = String(cString: suggestionsPtr).data(using: .utf8),
               let decoded = try? dec.decode([String].self, from: data) {
                suggestions = decoded
            }
            out.append(
                ChatMessage(
                    id: id,
                    threadId: tid,
                    role: role,
                    content: content,
                    sources: sources,
                    suggestions: suggestions,
                    createdAt: createdAt
                )
            )
        }
        return out
    }

    func fetchChatAnalyticsSummary() throws -> ChatAnalyticsSummary {
        let activeThreads = try scalarInt("SELECT COUNT(*) FROM chat_threads WHERE archived_at IS NULL")
        let archivedThreads = try scalarInt("SELECT COUNT(*) FROM chat_threads WHERE archived_at IS NOT NULL")
        let totalMessages = try scalarInt("""
            SELECT COUNT(*)
            FROM chat_messages m
            JOIN chat_threads t ON t.id = m.thread_id
            WHERE t.archived_at IS NULL
            """)
        let userMessages = try scalarInt("""
            SELECT COUNT(*)
            FROM chat_messages m
            JOIN chat_threads t ON t.id = m.thread_id
            WHERE t.archived_at IS NULL AND m.role = 'user'
            """)
        let assistantMessages = try scalarInt("""
            SELECT COUNT(*)
            FROM chat_messages m
            JOIN chat_threads t ON t.id = m.thread_id
            WHERE t.archived_at IS NULL AND m.role = 'assistant'
            """)
        let assistantWithSources = try scalarInt("""
            SELECT COUNT(*)
            FROM chat_messages m
            JOIN chat_threads t ON t.id = m.thread_id
            WHERE t.archived_at IS NULL
              AND m.role = 'assistant'
              AND COALESCE(m.sources_json, '[]') != '[]'
            """)
        let mostRecent = try scalarDouble("""
            SELECT MAX(m.created_at)
            FROM chat_messages m
            JOIN chat_threads t ON t.id = m.thread_id
            WHERE t.archived_at IS NULL
            """)

        let sourceHitRate: Double = assistantMessages > 0
            ? Double(assistantWithSources) / Double(assistantMessages)
            : 0
        let avgMessages: Double = activeThreads > 0
            ? Double(totalMessages) / Double(activeThreads)
            : 0

        return ChatAnalyticsSummary(
            activeThreads: activeThreads,
            archivedThreads: archivedThreads,
            totalMessages: totalMessages,
            userMessages: userMessages,
            assistantMessages: assistantMessages,
            assistantMessagesWithSources: assistantWithSources,
            sourceHitRate: sourceHitRate,
            avgMessagesPerActiveThread: avgMessages,
            mostRecentMessageAt: mostRecent.map { Date(timeIntervalSince1970: $0) }
        )
    }

    func fetchTopChatThreadStats(limit: Int = 10) throws -> [ChatThreadStat] {
        let stmt = try db.prepare("""
            SELECT
              t.id,
              t.title,
              t.created_at,
              t.updated_at,
              t.last_message_preview,
              COUNT(m.id) AS message_count,
              SUM(CASE WHEN m.role = 'user' THEN 1 ELSE 0 END) AS user_count,
              SUM(CASE WHEN m.role = 'assistant' THEN 1 ELSE 0 END) AS assistant_count
            FROM chat_threads t
            LEFT JOIN chat_messages m ON m.thread_id = t.id
            WHERE t.archived_at IS NULL
            GROUP BY t.id, t.title, t.created_at, t.updated_at, t.last_message_preview
            ORDER BY t.updated_at DESC
            LIMIT ?
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))
        var out: [ChatThreadStat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let preview = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let messageCount = Int(sqlite3_column_int(stmt, 5))
            let userCount = Int(sqlite3_column_int(stmt, 6))
            let assistantCount = Int(sqlite3_column_int(stmt, 7))
            let thread = ChatThread(
                id: id,
                title: title,
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastMessagePreview: preview,
                archivedAt: nil
            )
            out.append(
                ChatThreadStat(
                    thread: thread,
                    messageCount: messageCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount
                )
            )
        }
        return out
    }

    // MARK: - Helpers

    private func scalarInt(_ sql: String) throws -> Int {
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func scalarDouble(_ sql: String) throws -> Double? {
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL {
            return nil
        }
        return sqlite3_column_double(stmt, 0)
    }

    private func floatsToBlob(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }
}

enum StoreError: Error {
    case insertFailed
}
