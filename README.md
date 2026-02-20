# Save the Knowledge

Offline-first macOS knowledge workspace. Save web pages and notes, then ask questions grounded in your own local knowledge base.

## Why this project

Most AI note/search tools are cloud-first. Save the Knowledge is local-first:

- your saved content stays on your Mac,
- retrieval and core answering work from local storage,
- optional components (feedback sync, update checks) can run online.

## Core capabilities

- URL and text ingestion with local extraction/chunking.
- Local semantic retrieval over saved knowledge.
- Citation-backed answers from retrieved evidence.
- Chat experience with history and archived conversations.
- Optional Ollama integration for richer responses.
- Offline queueing for feedback/analytics sync when network returns.

## Architecture (high-level)

- App: SwiftUI macOS app (`KnowledgeCache/`).
- Storage: SQLite for items, chunks, history, chat data.
- Retrieval: embedding + semantic search pipeline.
- Answering: deterministic grounded responses + optional Ollama.
- Companion backend: `feedback-server/` for telemetry/feedback/dashboard.

More detail: `docs/PROJECT-OVERVIEW.md`

## Installation

See the full installation guide: `docs/INSTALLATION.md`

Quick options:

1. Build locally (recommended for contributors):
```bash
xcodegen generate
xcodebuild -project KnowledgeCache.xcodeproj -scheme KnowledgeCache -destination 'platform=macOS' build
```

2. Homebrew distribution (tap templates included):
- Formula: `packaging/homebrew/Formula/save-the-knowledge.rb`
- Cask: `packaging/homebrew/Casks/save-the-knowledge.rb`
- Guide: `docs/HOMEBREW-DISTRIBUTION.md`

## Development

Build:
```bash
xcodebuild -project KnowledgeCache.xcodeproj -scheme KnowledgeCache -destination 'platform=macOS' build
```

Test:
```bash
xcodebuild -project KnowledgeCache.xcodeproj -scheme KnowledgeCache -destination 'platform=macOS' test
```

Quality checks:
```bash
./scripts/run_quality_checks.sh
```

## Repository structure

- `KnowledgeCache/`: macOS app source.
- `Tests/KnowledgeCacheTests/`: XCTest suite.
- `feedback-server/`: feedback + analytics APIs and dashboard.
- `docs/`: architecture, installation, release, and operations docs.
- `scripts/`: packaging and automation scripts.
- `website/`: project landing site.

## Open-source status

This project is being prepared for open source with production-oriented docs and packaging support.

If you plan to contribute, start with:

- `docs/PROJECT-OVERVIEW.md`
- `docs/INSTALLATION.md`
- `CONTRIBUTING.md`

## Security and privacy notes

- Do not commit secrets.
- Keep API keys in local env files.
- Validate input for all `feedback-server/api/*` endpoints.
- Review `docs/feedback-api.md` before deploying backend endpoints publicly.

## License

Add your preferred license file (for example `MIT`) before public launch.
