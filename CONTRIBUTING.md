# Contributing to Save the Knowledge

Thanks for considering a contribution.

## Development setup

1. Clone the repository.
2. Generate Xcode project:
```bash
xcodegen generate
```
3. Build:
```bash
xcodebuild -project KnowledgeCache.xcodeproj -scheme KnowledgeCache -destination 'platform=macOS' build
```
4. Run tests:
```bash
xcodebuild -project KnowledgeCache.xcodeproj -scheme KnowledgeCache -destination 'platform=macOS' test
```

## Contribution flow

1. Fork and create a feature branch.
2. Keep changes scoped and focused.
3. Add or update tests when behavior changes.
4. Run build/tests before opening PR.
5. Open PR with:
   - clear purpose,
   - impacted modules/files,
   - test evidence.

## Code style

- Swift API Design Guidelines.
- 4-space indentation.
- Explicit naming for services/components.
- Keep UI state in `AppState`/view models.

See `README.md` and `docs/PROJECT-OVERVIEW.md` for project conventions.

## Commit guidance

- Use imperative commit subjects.
- Prefer small, reviewable commits.
- Avoid mixing unrelated refactors with functional changes.

## Reporting issues

When filing bugs, include:

- macOS version
- app version/build
- reproduction steps
- expected vs actual behavior
- logs/screenshots if available

## Security

Do not post secrets, tokens, or private documents in issues.
For sensitive reports, open a private security contact channel first.
