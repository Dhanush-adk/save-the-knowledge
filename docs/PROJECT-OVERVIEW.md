# Save the Knowledge: Project Overview

Save the Knowledge is an offline-first macOS app for building a private knowledge base from URLs and text notes.

## Goals

- Keep user knowledge local-first.
- Provide semantic search over saved content.
- Return grounded answers with citations to saved material.
- Support optional local LLM enhancement via Ollama.

## Main Components

- `KnowledgeCache/`: SwiftUI macOS application.
- `Tests/`: XCTest coverage for core behavior.
- `feedback-server/`: telemetry, feedback, issue intake, and dashboard APIs.
- `website/`: landing page and user-facing documentation links.

## App Flow

1. User saves URL/text.
2. Content is extracted/chunked and indexed locally.
3. Search retrieves semantically relevant chunks.
4. Answering layer produces grounded responses from retrieved chunks.

## Data and Privacy

- Core knowledge data is stored locally on device.
- Optional feedback/analytics can sync to backend when configured.
- Offline queueing is used for deferred feedback/analytics delivery.

## Release and Distribution

- Source builds via Xcode.
- Homebrew cask distribution for app install.
- Unsigned/notarized status may require manual macOS approval on first launch.
