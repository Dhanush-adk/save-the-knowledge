#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK_FILE="$ROOT_DIR/packaging/homebrew/Casks/save-the-knowledge.rb"
MANIFEST_FILE="${1:-$ROOT_DIR/build/release/manifest.txt}"
DMG_PATH="${2:-}"

if [[ ! -f "$CASK_FILE" ]]; then
  echo "ERROR: cask file not found: $CASK_FILE" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "ERROR: manifest file not found: $MANIFEST_FILE" >&2
  echo "Run: ./scripts/package_unsigned_macos.sh" >&2
  exit 1
fi

version="$(awk -F= '/^version=/{print $2}' "$MANIFEST_FILE" | tail -n1)"
build="$(awk -F= '/^build=/{print $2}' "$MANIFEST_FILE" | tail -n1)"
dmg_name="$(awk -F= '/^dmg=/{print $2}' "$MANIFEST_FILE" | tail -n1)"
dmg_created="$(awk -F= '/^dmg_created=/{print $2}' "$MANIFEST_FILE" | tail -n1)"

if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$ROOT_DIR/build/release/$dmg_name"
fi

if [[ -z "$version" || -z "$build" ]]; then
  echo "ERROR: version/build not found in manifest: $MANIFEST_FILE" >&2
  exit 1
fi

if [[ "$dmg_created" != "true" ]]; then
  echo "ERROR: DMG was not created in package step. Cannot update cask SHA." >&2
  exit 1
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: DMG not found: $DMG_PATH" >&2
  exit 1
fi

sha="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

# BSD sed on macOS requires -i ''
sed -i '' -E "s/^  version \"[^\"]+\"/  version \"$version\"/" "$CASK_FILE"
sed -i '' -E "s/^  build \"[^\"]+\"/  build \"$build\"/" "$CASK_FILE"
sed -i '' -E "s/^  sha256 \"[^\"]+\"/  sha256 \"$sha\"/" "$CASK_FILE"

echo "Updated $CASK_FILE"
echo " - version: $version"
echo " - build:   $build"
echo " - sha256:  $sha"
echo
echo "Next:"
echo "1) Create/publish GitHub release tag v$version with asset: $dmg_name"
echo "2) Push the cask change to your Homebrew tap repo"
