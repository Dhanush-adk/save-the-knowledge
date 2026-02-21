#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_SLUG="save-the-knowledge"
TAP_REPO="homebrew-save-the-knowledge"
CASK_TEMPLATE_PATH="packaging/homebrew/Casks/save-the-knowledge.rb"
CASK_TAP_PATH="Casks/save-the-knowledge.rb"
WEBSITE_PATH="website/index.html"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

require_cmd git
require_cmd awk
require_cmd sed
require_cmd shasum
require_cmd curl

origin_url="$(git remote get-url origin)"
if [[ "$origin_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
  GITHUB_OWNER="${BASH_REMATCH[1]}"
  GITHUB_REPO="${BASH_REMATCH[2]}"
else
  echo "ERROR: could not parse GitHub owner/repo from origin URL: $origin_url" >&2
  exit 1
fi

auth_prefix=""
if [[ "$origin_url" =~ ^https://([^@]+)@github\.com/ ]]; then
  auth_prefix="${BASH_REMATCH[1]}@"
fi

echo "[1/8] Build unsigned release artifact..."
bash ./scripts/package_unsigned_macos.sh

MANIFEST_FILE="$ROOT_DIR/build/release/manifest.txt"
if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "ERROR: missing manifest file: $MANIFEST_FILE" >&2
  exit 1
fi

version="$(awk -F= '/^version=/{print $2}' "$MANIFEST_FILE" | tail -n1)"
build="$(awk -F= '/^build=/{print $2}' "$MANIFEST_FILE" | tail -n1)"
dmg_name="$(awk -F= '/^dmg=/{print $2}' "$MANIFEST_FILE" | tail -n1)"
dmg_created="$(awk -F= '/^dmg_created=/{print $2}' "$MANIFEST_FILE" | tail -n1)"
tag="v${version}"

if [[ -z "$version" || -z "$build" || -z "$dmg_name" ]]; then
  echo "ERROR: invalid manifest content in $MANIFEST_FILE" >&2
  exit 1
fi
if [[ "$dmg_created" != "true" ]]; then
  echo "ERROR: DMG build failed; aborting release." >&2
  exit 1
fi

DMG_PATH="$ROOT_DIR/build/release/$dmg_name"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: expected DMG missing: $DMG_PATH" >&2
  exit 1
fi

echo "[2/8] Update Homebrew cask metadata..."
bash ./scripts/update_homebrew_cask.sh "$MANIFEST_FILE" "$DMG_PATH"

echo "[3/8] Sync tap cask path..."
cp "$CASK_TEMPLATE_PATH" "$CASK_TAP_PATH"

release_url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v${version}/${APP_SLUG}-macOS-v${version}-b${build}-unsigned.dmg"
echo "[4/8] Update website download links -> $release_url"
sed -i '' -E \
  "s#https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v[0-9.]+/${APP_SLUG}-macOS-v[0-9.]+-b[0-9]+-unsigned.dmg#${release_url}#g" \
  "$WEBSITE_PATH"

echo "[5/8] Commit release metadata changes..."
git add "$CASK_TEMPLATE_PATH" "$CASK_TAP_PATH" "$WEBSITE_PATH"
if ! git diff --cached --quiet; then
  git commit -m "release: ${tag} build ${build} (artifact links + cask sha)"
else
  echo "No metadata changes to commit."
fi

echo "[6/8] Push main and tag..."
git push origin main
if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "Tag $tag already exists locally; reusing existing tag."
else
  git tag -a "$tag" -m "Release ${tag} (build ${build})"
fi
git push origin "$tag"

echo "[7/8] Create/update GitHub release and upload DMG..."
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$DMG_PATH" --clobber
  else
    gh release create "$tag" "$DMG_PATH" \
      --title "$tag" \
      --notes "Release $tag (build $build)."
  fi
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  api="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}"
  release_json="$(curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$api/releases/tags/$tag" || true)"
  release_id="$(echo "$release_json" | sed -n 's/.*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
  if [[ -z "$release_id" ]]; then
    create_json="$(curl -sS -X POST "$api/releases" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -d "{\"tag_name\":\"$tag\",\"name\":\"$tag\",\"body\":\"Release $tag (build $build).\"}")"
    release_id="$(echo "$create_json" | sed -n 's/.*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
  fi
  if [[ -z "$release_id" ]]; then
    echo "ERROR: failed to create/find GitHub release for $tag." >&2
    exit 1
  fi
  curl -sS -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    "https://uploads.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/${release_id}/assets?name=${dmg_name}" \
    --data-binary @"$DMG_PATH" >/dev/null
else
  echo "WARNING: gh auth/GITHUB_TOKEN not available. Release upload skipped."
  echo "Upload manually: $DMG_PATH to release $tag"
fi

echo "[8/8] Sync cask to tap repo ${GITHUB_OWNER}/${TAP_REPO}..."
tmpdir="$(mktemp -d)"
tap_url="https://${auth_prefix}github.com/${GITHUB_OWNER}/${TAP_REPO}.git"
if git clone "$tap_url" "$tmpdir/tap" >/dev/null 2>&1; then
  mkdir -p "$tmpdir/tap/Casks"
  cp "$CASK_TAP_PATH" "$tmpdir/tap/Casks/save-the-knowledge.rb"
  (
    cd "$tmpdir/tap"
    git add Casks/save-the-knowledge.rb
    if ! git diff --cached --quiet; then
      git commit -m "release: ${tag} build ${build}"
      git push origin main
    else
      echo "Tap cask already up to date."
    fi
  )
else
  echo "WARNING: could not clone ${GITHUB_OWNER}/${TAP_REPO}; tap sync skipped."
fi
rm -rf "$tmpdir"

echo
echo "Release pipeline complete:"
echo " - tag: $tag"
echo " - dmg: $DMG_PATH"
echo " - website URL: $release_url"
