# Knowledge Cache — Offline Knowledge Memory (macOS MVP)

A macOS app that remembers what you save (URLs or pasted text) and answers questions using **only** your locally stored knowledge. Fully offline after initial URL fetch; no cloud, no accounts.

## Features

- **Save**: URL or pasted text (reader-style extraction for URLs).
- **Store**: SQLite locally; embeddings stored as Float32 BLOBs (384-dim, L2-normalized).
- **Search**: Semantic search over saved chunks (dot product); answers built from retrieved chunks only, with sources. If **Ollama** is installed and running, the app uses it for richer, synthesized answers (same sources); otherwise it uses a fast deterministic summary.
- **History**: Past questions and answers stored; "Source no longer available" when an item was deleted.
- **Production**: Content hash dedupe (no re-embed of same content); max extracted chars and max chunks per item; truncation flag; **Optimize storage** (PRAGMA optimize; VACUUM) and **Re-index all** from Saved tab.

## Requirements

- macOS 13+ (or 14+ if your Core ML model requires it).
- Xcode 15+.
- An embedding model in Core ML format (see [docs/embedding-model.md](docs/embedding-model.md)).

## Setup and run

### Option A: Xcode (recommended)

1. **Create a new macOS App in Xcode**
   - File → New → Project → macOS → **App**.
   - Product Name: `KnowledgeCache`, Interface: **SwiftUI**, Language: **Swift**.
   - Set **Minimum Deployments** to **macOS 13.0** (or 14.0).

2. **Replace the default source**
   - Delete the default `ContentView.swift` and `KnowledgeCacheApp.swift` that Xcode created.
   - In Finder, drag the entire **KnowledgeCache** folder (from this repo) into the Xcode project navigator so that all subfolders (App, Models, Storage, Ingestion, Embedding, Retrieval, Answering, UI) and their Swift files are added. Ensure "Copy items if needed" is unchecked and "Create groups" is selected, and the **KnowledgeCache** target is checked for all added files.

3. **Add the embedding model**
   - Export a sentence-embedding model (e.g. **all-MiniLM-L6-v2**) to Core ML (`.mlmodel` then compile to `.mlmodelc`). See [docs/embedding-model.md](docs/embedding-model.md).
   - Add the `.mlmodel` or `.mlmodelc` to the Xcode project and ensure it’s in **Copy Bundle Resources** for the KnowledgeCache target. Name it `EmbeddingModel` (or set the same name in `EmbeddingModel.swift` / `EmbeddingService.swift`).

4. **Build and run**
   - Select the **KnowledgeCache** scheme and run (⌘R). The app will create the SQLite DB in `~/Library/Application Support/KnowledgeCache/`.

### Option B: XcodeGen

If you have [XcodeGen](https://github.com/yonaskolb/XcodeGen) installed:

```bash
brew install xcodegen   # if needed
cd /path/to/knowledge-cache
xcodegen generate
open KnowledgeCache.xcodeproj
```

Then add your embedding model as in step 3 above and build.

## Embedding model

The app uses **all-MiniLM-L6-v2**–style embedding:

- **Tokenization in Swift**: WordPiece via `MiniLMTokenizer` (vocab: `minilm_vocab.txt` in bundle). Same input → same tokens (deterministic).
- **Core ML model** must accept `input_ids` and `attention_mask` (Int32, shape 1×256) and output a 384-dim vector (`sentence_embedding` or mean-pooled `last_hidden_state`). See [docs/embedding-model.md](docs/embedding-model.md).
- Embeddings are **L2-normalized** before storage and at query time.
- **Schema**: `chunks` store `embedding_model_id` and `embedding_dim`. If the model or dimension changes, use **Re-index all** (Saved tab) so search works; otherwise the app shows "Re-index required".

BLOB format: Float32, 384 × 4 bytes, native byte order. See [docs/embedding-schema.md](docs/embedding-schema.md).

## Richer answers (optional)

For more natural, synthesized answers (still grounded in your saved content and with the same sources), install [Ollama](https://ollama.com) and pull a small model once:

```bash
# Install Ollama from https://ollama.com, then:
ollama pull llama3.2:latest
```

Keep Ollama running (or start it when you use the app). The app will use it automatically when you ask a question; if Ollama isn’t available, it falls back to the built-in summary. No model is shipped with the app.

## Project layout

```
KnowledgeCache/
  App/          — Entry point, AppState
  Models/       — KnowledgeItem, Chunk, SourceRef, AnswerWithSources, QueryHistoryItem
  Storage/      — Database (SQLite), KnowledgeStore
  Ingestion/    — TextExtractor, Chunker, IngestionPipeline
  Embedding/    — MiniLMTokenizer, EmbeddingModel (Core ML), EmbeddingService
  Retrieval/    — SemanticSearch, SearchOutcome, RetrievalResult
  Storage/      — ReindexController
  Answering/    — AnswerGenerator
  UI/           — ContentView, SaveView, SearchView, SavedItemsView, HistoryView
```

## Docs

- [docs/plan-validation-and-notes.md](docs/plan-validation-and-notes.md) — Plan validation and implementation notes.
- [docs/implementation-notes-from-validation.md](docs/implementation-notes-from-validation.md) — Chunking, export, entitlements, UX.
- [docs/embedding-model.md](docs/embedding-model.md) — How to obtain and convert the embedding model (create from template below if missing).
- [docs/embedding-schema.md](docs/embedding-schema.md) — BLOB layout for embeddings.
- [docs/feedback-api.md](docs/feedback-api.md) — Backend API for offline-queued feedback and optional minimal analytics.

## Feedback and analytics

In **Settings** you can report bugs or send feedback. When the device is **offline**, reports are stored locally and sent automatically when back **online**. You can host a small backend (see [docs/feedback-api.md](docs/feedback-api.md)) and set its URL in `KnowledgeCache/Feedback/FeedbackConfig.swift`. Optional minimal usage stats (e.g. app version, saves count, once per day) are sent only if enabled in Settings.

## License

Use as you like.
