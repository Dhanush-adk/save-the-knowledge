# App logs (debugging across sessions)

The app writes logs to a **file** so you can inspect them in the next session when debugging.

## Where logs are stored

The app is sandboxed, so logs go into its container:

- **Directory:** `~/Library/Containers/com.knowledgecache.app/Data/Library/Application Support/KnowledgeCache/logs/`
- **File:** `KnowledgeCache.log` (appended to each run)

## How to view logs

**Open the log folder in Finder:**

```bash
open ~/Library/Containers/com.knowledgecache.app/Data/Library/Application\ Support/KnowledgeCache/logs/
```

**Tail the log in terminal (updates as the app runs):**

```bash
tail -f ~/Library/Containers/com.knowledgecache.app/Data/Library/Application\ Support/KnowledgeCache/logs/KnowledgeCache.log
```

**Open the log in your editor:**

```bash
open -a "Cursor" ~/Library/Containers/com.knowledgecache.app/Data/Library/Application\ Support/KnowledgeCache/logs/KnowledgeCache.log
```

## What gets logged

- **Startup:** App start, embedding available (yes/no), tokenizer/model load failures
- **Save:** URL or pasted save started, success (title), or error message
- **Ingestion:** Ingest start (title/source), chunk count, embedding errors, store success

Log lines look like:

```
[2026-02-09T22:50:00.000Z] [INFO] App started; embedding available=false
[2026-02-09T22:50:01.000Z] [ERROR] EmbeddingService: EmbeddingModel failed to load: ...
[2026-02-09T22:50:02.000Z] [INFO] Save started: https://example.com
[2026-02-09T22:50:05.000Z] [ERROR] Ingest: embedding unavailable
```

Check this file after a run to see why a save failed or why the embedding model wasn’t found.
