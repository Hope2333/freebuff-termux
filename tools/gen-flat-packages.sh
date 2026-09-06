#!/usr/bin/env bash
set -euo pipefail

# gen-flat-packages.sh — generate Packages.gz from a GitHub release's .deb assets.
# Self-contained: derives REPO from git remote, fetches release asset metadata,
# extracts control info from tiny range requests, generates Packages.gz, uploads.
#
# Usage: ./tools/gen-flat-packages.sh [TAG]
#   TAG defaults to the latest release tag.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="${PYTHON:-python3}"

# Derive REPO_SLUG from git remote
REMOTE_URL="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
REPO_SLUG="$(echo "$REMOTE_URL" | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
if [ -z "$REPO_SLUG" ]; then
    echo "ERROR: cannot determine repo slug from remote" >&2
    exit 1
fi
echo "REPO: $REPO_SLUG"

# Resolve tag
TAG="${1:-}"
if [ -z "$TAG" ]; then
    TAG="$(gh release list --repo "$REPO_SLUG" --limit 1 --json tagName --jq '.[0].tagName')"
    if [ -z "$TAG" ]; then
        echo "ERROR: no releases found" >&2
        exit 1
    fi
fi
echo "TAG: $TAG"

# Check prerelease status
PRERELEASE="$(gh release view "$TAG" --repo "$REPO_SLUG" --json isPrerelease --jq '.isPrerelease')"
echo "isPrerelease: $PRERELEASE"

PINNED_URL="https://github.com/$REPO_SLUG/releases/download/$TAG/"
LATEST_URL="https://github.com/$REPO_SLUG/releases/latest/download/"
echo ""
echo "Apt sources line:"
if [ "$PRERELEASE" = "true" ]; then
    echo "  deb [trusted=yes] $PINNED_URL ./"
    echo "  (NOTE: /releases/latest/download/ does NOT resolve to prereleases)"
    echo "  Correct for apt: $PINNED_URL"
else
    echo "  deb [trusted=yes] $PINNED_URL ./"
    echo "  Also works:      deb [trusted=yes] $LATEST_URL ./"
    echo "  (Release is NOT prerelease; /releases/latest/download/ resolves here)"
fi
echo ""

# Create temp working dir
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gen-flat-XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
echo "WORKDIR: $WORKDIR"

# Fetch release assets metadata (id, name, size, digest→sha256)
echo "Fetching release asset metadata..."
gh api "repos/$REPO_SLUG/releases/tags/$TAG" --paginate \
    --jq '.assets[] | select(.name | endswith(".deb")) | "\(.id) \(.name) \(.size) \(.digest | sub("^sha256:"; ""))"' \
    > "$WORKDIR/assets.txt"

DEB_COUNT="$(wc -l < "$WORKDIR/assets.txt" | tr -d ' ')"
echo "Found $DEB_COUNT .deb assets"

if [ "$DEB_COUNT" -lt 1 ]; then
    echo "ERROR: no .deb assets in release $TAG" >&2
    exit 1
fi

# Show asset list
echo "Assets:"
while read -r LINE; do
    AID="$(echo "$LINE" | awk '{print $1}')"
    ANAME="$(echo "$LINE" | awk '{print $2}')"
    ASIZE="$(echo "$LINE" | awk '{print $3}')"
    echo "  $ANAME ($ASIZE bytes, asset $AID)"
done < "$WORKDIR/assets.txt"

# Generate Packages.gz (release mode — downloads only tiny control.tar, not full debs)
PACKAGES_OUT="$WORKDIR/Packages.gz"
echo ""
echo "Generating Packages.gz (release mode — range requests for control headers only)..."
$PYTHON "$SCRIPT_DIR/gen_flat_packages.py" release \
    --repo "$REPO_SLUG" \
    --tag "$TAG" \
    --assets-file "$WORKDIR/assets.txt" \
    --out "$PACKAGES_OUT"

# Guard: assert valid
ENTRY_COUNT="$(zcat "$PACKAGES_OUT" | grep -c '^Package:' || true)"
FILE_SIZE="$(stat -c%s "$PACKAGES_OUT" 2>/dev/null || stat -f%z "$PACKAGES_OUT")"
if [ "$ENTRY_COUNT" -lt 1 ] || [ "$FILE_SIZE" -lt 1 ]; then
    echo "ERROR: Packages.gz invalid (entries=$ENTRY_COUNT, size=$FILE_SIZE)" >&2
    exit 1
fi
echo "Packages.gz: entries=$ENTRY_COUNT, size=$FILE_SIZE bytes"

# Copy to repo root for commit
cp "$PACKAGES_OUT" "$REPO_DIR/Packages.gz"

# Upload to release
echo "Uploading Packages.gz to release $TAG..."
gh release upload "$TAG" --repo "$REPO_SLUG" --clobber "$PACKAGES_OUT"
echo "Upload complete."

# Verify via re-download
echo ""
echo "Verifying re-download..."
VERIFY_DIR="$WORKDIR/verify"
mkdir -p "$VERIFY_DIR"

# Get Packages.gz asset id and download
ASSET_ID="$(gh api "repos/$REPO_SLUG/releases/tags/$TAG" --jq '.assets[] | select(.name == "Packages.gz") | .id')"
gh api "repos/$REPO_SLUG/releases/assets/$ASSET_ID" \
    -H 'Accept: application/octet-stream' > "$VERIFY_DIR/Packages.gz"

# Validate
if ! gzip -t "$VERIFY_DIR/Packages.gz" 2>/dev/null; then
    echo "ERROR: re-downloaded Packages.gz is not valid gzip" >&2
    exit 1
fi
VERIFY_ENTRIES="$(zcat "$VERIFY_DIR/Packages.gz" | grep -c '^Package:' || true)"
VERIFY_SIZE="$(stat -c%s "$VERIFY_DIR/Packages.gz" 2>/dev/null || stat -f%z "$VERIFY_DIR/Packages.gz")"
echo "  Re-downloaded: entries=$VERIFY_ENTRIES, size=$VERIFY_SIZE bytes"

# Show Packages content
echo ""
echo "=== Packages.gz content ==="
zcat "$VERIFY_DIR/Packages.gz"
echo "=== end ==="

echo ""
echo "DONE: $REPO_SLUG — $ENTRY_COUNT entry, $FILE_SIZE bytes"
