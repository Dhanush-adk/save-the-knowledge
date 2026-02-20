# Homebrew Distribution

This project ships a Homebrew cask for installing the macOS app bundle.

## User Install

```bash
brew tap Dhanush-adk/save-the-knowledge
brew install --cask save-the-knowledge
```

## Maintainer Release Flow

1. Build artifacts:

```bash
./scripts/package_unsigned_macos.sh
```

2. Update cask version/build/SHA from release manifest:

```bash
bash ./scripts/update_homebrew_cask.sh
```

3. Commit and push cask updates.
4. Publish GitHub release tag `v<version>`.
5. Upload DMG asset generated under `build/release/`.

## Cask Locations

- `Casks/save-the-knowledge.rb` (tap-compatible path)
- `packaging/homebrew/Casks/save-the-knowledge.rb` (packaging template path)

## Notes

- Current release artifact is unsigned and not notarized.
- macOS may show first-launch security prompts.
