# Installation Guide

This guide covers local build and Homebrew install options for Save the Knowledge.

## Requirements

- macOS 14+ (Sonoma or newer recommended)
- Xcode (for source build)
- Homebrew (for cask install and optional Ollama install)

## Option 1: Install via Homebrew Cask

```bash
brew tap Dhanush-adk/save-the-knowledge
brew install --cask save-the-knowledge
```

Then open:

```bash
open "/Applications/Save the Knowledge.app"
```

## Option 2: Build from Source

From repo root:

```bash
xcodegen generate
xcodebuild -project KnowledgeCache.xcodeproj -scheme KnowledgeCache -destination 'platform=macOS' build
```

## First Launch Notes

- If macOS blocks launch, go to System Settings -> Privacy & Security and allow/open anyway.
- Initial data stays local on your machine.

## Optional: Ollama for richer local responses

```bash
brew install ollama
ollama pull llama3.2
```

Then enable/use Ollama from app settings.
