#!/usr/bin/env bash
# Cut a new ClaudeUsageBar release.
#
# Usage:
#   scripts/release.sh <version> [--notes-file PATH | --notes "TEXT"] [--no-redeploy] [--dry-run]
#
# Example:
#   scripts/release.sh 1.5.2 --notes-file /tmp/notes.md
#
# Steps:
#   1. Pre-flight: clean tree, on main, in sync with origin, tag doesn't exist, gh authed,
#      Developer ID cert present, notary keychain profile configured.
#   2. Bump MARKETING_VERSION (Debug + Release) in project.pbxproj.
#   3. Build a universal Release binary signed with Developer ID + hardened runtime + secure timestamp.
#   4. Resolve the built .app via -showBuildSettings (no DerivedData wildcard).
#   5. Notarize via xcrun notarytool, then staple the ticket to the .app.
#   6. Pack the stapled bundle into dist/ClaudeUsageBar.zip with `ditto --keepParent`.
#   7. Commit the version bump, push main, create the GitHub release with the zip attached.
#   8. Redeploy to /Applications and relaunch (skip with --no-redeploy).
#
# One-time setup (before first run):
#   xcrun notarytool store-credentials "ClaudeUsageBar-Notary" \
#       --apple-id <your-apple-id> --team-id V9YWH29X5V

set -euo pipefail

# ---------- helpers ----------

repo_root() { git rev-parse --show-toplevel; }
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
fail() { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---------- arg parsing ----------

VERSION=""
NOTES=""
NOTES_FILE=""
REDEPLOY=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --notes) NOTES="${2:-}"; shift 2 ;;
        --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
        --no-redeploy) REDEPLOY=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -*) fail "Unknown flag: $1" ;;
        *)
            if [[ -z "$VERSION" ]]; then VERSION="$1"; else fail "Unexpected argument: $1"; fi
            shift
            ;;
    esac
done

[[ -n "$VERSION" ]] || usage 1
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must look like X.Y.Z (got '$VERSION')"

if [[ -n "$NOTES" && -n "$NOTES_FILE" ]]; then
    fail "Pass --notes or --notes-file, not both."
fi

ROOT="$(repo_root)"
cd "$ROOT"

PBXPROJ="ClaudeUsageBar.xcodeproj/project.pbxproj"
SCHEME="ClaudeUsageBar"
ASSET_NAME="ClaudeUsageBar.zip"
DIST_DIR="$ROOT/dist"
ZIP_PATH="$DIST_DIR/$ASSET_NAME"
INSTALLED_APP="/Applications/ClaudeUsageBar.app"
TEAM_ID="V9YWH29X5V"
SIGN_IDENTITY="Developer ID Application"
NOTARY_PROFILE="ClaudeUsageBar-Notary"

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '\033[2;37m   $ %s\033[0m\n' "$*"
    else
        eval "$@"
    fi
}

# ---------- pre-flight ----------

log "Pre-flight checks"

command -v gh >/dev/null      || fail "gh CLI not installed"
command -v xcodebuild >/dev/null || fail "xcodebuild not on PATH"
command -v ditto >/dev/null    || fail "ditto missing (should ship with macOS)"
command -v xcrun >/dev/null    || fail "xcrun missing (install Xcode command line tools)"

[[ -f "$PBXPROJ" ]] || fail "Cannot find $PBXPROJ — run from the repo root."

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run: gh auth login"

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY: .*($TEAM_ID)"; then
    fail "Signing identity '$SIGN_IDENTITY' for team $TEAM_ID not found in keychain."
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    fail "Notary keychain profile '$NOTARY_PROFILE' missing. Set up with: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id $TEAM_ID"
fi

CURRENT_BRANCH="$(git symbolic-ref --short HEAD)"
[[ "$CURRENT_BRANCH" == "main" ]] || fail "Not on main (on '$CURRENT_BRANCH')."

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty. Commit or stash first."
fi

git fetch --quiet origin main
LOCAL="$(git rev-parse @)"
REMOTE="$(git rev-parse @{u})"
BASE="$(git merge-base @ @{u})"
if   [[ "$LOCAL" == "$REMOTE" ]]; then : # up to date
elif [[ "$LOCAL" == "$BASE"   ]]; then fail "Local main is behind origin/main. Pull first."
elif [[ "$REMOTE" == "$BASE"  ]]; then fail "Local main is ahead of origin/main. Push first."
else fail "Local and remote main have diverged."
fi

if git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1; then
    fail "Tag '$VERSION' already exists locally."
fi
if git ls-remote --exit-code --tags origin "$VERSION" >/dev/null 2>&1; then
    fail "Tag '$VERSION' already exists on origin."
fi

CURRENT_VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/')"
log "Current version: $CURRENT_VERSION  →  new version: $VERSION"

# ---------- notes ----------

NOTES_PATH=""
cleanup_notes() { [[ -n "$NOTES_PATH" && -f "$NOTES_PATH" ]] && rm -f "$NOTES_PATH" || true; }
trap cleanup_notes EXIT

if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || fail "Notes file not found: $NOTES_FILE"
    NOTES_PATH="$NOTES_FILE"
    KEEP_NOTES=1
elif [[ -n "$NOTES" ]]; then
    NOTES_PATH="$(mktemp -t claudeusagebar-notes)"
    printf '%s\n' "$NOTES" > "$NOTES_PATH"
    KEEP_NOTES=0
else
    NOTES_PATH="$(mktemp -t claudeusagebar-notes)"
    KEEP_NOTES=0
    cat > "$NOTES_PATH" <<EOF
## What's New

<!-- Describe user-visible changes for v$VERSION. Lines starting with '#' or '<!--' are kept; empty file aborts the release. -->
EOF
    "${EDITOR:-vi}" "$NOTES_PATH"
fi

# Strip HTML comments and require non-empty content
NOTES_BODY="$(sed -E 's/<!--.*-->//g' "$NOTES_PATH" | awk 'NF{found=1} END{exit !found}' && cat "$NOTES_PATH" || true)"
if [[ -z "$(sed -E 's/<!--.*-->//g' "$NOTES_PATH" | tr -d '[:space:]')" ]]; then
    fail "Release notes are empty — aborting."
fi

# ---------- bump version ----------

log "Bumping MARKETING_VERSION to $VERSION"
if [[ "$DRY_RUN" -eq 0 ]]; then
    # macOS sed needs '' after -i
    sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"

    # Sanity check: every line should now show the new version
    BAD="$(grep 'MARKETING_VERSION = ' "$PBXPROJ" | grep -v "MARKETING_VERSION = $VERSION;" || true)"
    [[ -z "$BAD" ]] || fail "Some MARKETING_VERSION lines didn't update:\n$BAD"
fi

# ---------- build ----------

log "Building Release (universal arm64 + x86_64)"
BUILD_LOG="$(mktemp -t claudeusagebar-build)"
trap 'cleanup_notes; rm -f "$BUILD_LOG"' EXIT

if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! xcodebuild \
        -project ClaudeUsageBar.xcodeproj \
        -scheme "$SCHEME" \
        -configuration Release \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS="arm64 x86_64" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
        build > "$BUILD_LOG" 2>&1; then
        warn "Build failed — last 40 lines:"
        tail -40 "$BUILD_LOG" >&2
        fail "xcodebuild failed (full log: $BUILD_LOG)"
    fi
fi

# Resolve the actual built .app path instead of globbing DerivedData.
# Capture -showBuildSettings to a file first: piping into `awk ... exit` makes
# xcodebuild get SIGPIPE, which `set -o pipefail` then bubbles up as exit 141.
SETTINGS_LOG="$(mktemp -t claudeusagebar-settings)"
xcodebuild \
    -project ClaudeUsageBar.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -showBuildSettings > "$SETTINGS_LOG" 2>/dev/null
BUILT_PRODUCTS_DIR="$(awk '/ BUILT_PRODUCTS_DIR = /{print $3; exit}' "$SETTINGS_LOG")"
rm -f "$SETTINGS_LOG"
APP_PATH="$BUILT_PRODUCTS_DIR/$SCHEME.app"
[[ -d "$APP_PATH" ]] || fail "Built app not found at $APP_PATH"

# Confirm the bundle's version actually matches what we asked for
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || fail "Built bundle reports v$BUNDLE_VERSION, expected v$VERSION"

# Confirm the bundle is actually Developer ID signed (not ad-hoc)
if [[ "$DRY_RUN" -eq 0 ]]; then
    SIG_OUTPUT="$(codesign -dvv "$APP_PATH" 2>&1 || true)"
    SIG_AUTHORITY="$(printf '%s\n' "$SIG_OUTPUT" | awk -F'=' '/^Authority=/{print $2; exit}')"
    [[ "$SIG_AUTHORITY" == "$SIGN_IDENTITY: "* ]] || fail "Bundle signed by '$SIG_AUTHORITY', expected '$SIGN_IDENTITY: ...'"
fi

# ---------- notarize ----------

log "Notarizing $APP_PATH (profile: $NOTARY_PROFILE)"
if [[ "$DRY_RUN" -eq 0 ]]; then
    NOTARY_DIR="$(mktemp -d -t claudeusagebar-notary)"
    NOTARY_ZIP="$NOTARY_DIR/ClaudeUsageBar.zip"
    ( cd "$BUILT_PRODUCTS_DIR" && /usr/bin/ditto -c -k --keepParent "$SCHEME.app" "$NOTARY_ZIP" )

    log "  Uploading to Apple notary service (this can take a few minutes)..."
    NOTARY_LOG="$NOTARY_DIR/submit.log"
    # notarytool returns 0 even when Apple's *result* is "Invalid", so we have
    # to inspect the printed status, not just the exit code.
    xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait > "$NOTARY_LOG" 2>&1 || true
    cat "$NOTARY_LOG"

    NOTARY_STATUS="$(awk '/^[[:space:]]*status:/{s=$2} END{print s}' "$NOTARY_LOG")"
    SUBMISSION_ID="$(awk '/^[[:space:]]*id:/{print $2; exit}' "$NOTARY_LOG")"

    if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
        warn "Notarization failed (status: ${NOTARY_STATUS:-unknown})"
        if [[ -n "$SUBMISSION_ID" ]]; then
            warn "Detailed log for submission $SUBMISSION_ID:"
            xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        rm -rf "$NOTARY_DIR"
        fail "Notarization rejected by Apple."
    fi
    rm -rf "$NOTARY_DIR"

    log "  Stapling notarization ticket to bundle"
    xcrun stapler staple "$APP_PATH"

    log "  Verifying signature + notarization"
    xcrun stapler validate "$APP_PATH"
    spctl --assess --verbose=2 --type execute "$APP_PATH"
fi

# ---------- package ----------

log "Packing $APP_PATH → $ZIP_PATH"
mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
if [[ "$DRY_RUN" -eq 0 ]]; then
    ( cd "$BUILT_PRODUCTS_DIR" && /usr/bin/ditto -c -k --keepParent "$SCHEME.app" "$ZIP_PATH" )
fi

# ---------- commit + push ----------

log "Committing version bump and pushing to origin/main"
if [[ "$DRY_RUN" -eq 0 ]]; then
    git add "$PBXPROJ"
    git commit -m "Release v$VERSION"
    git push origin main
fi

# ---------- release ----------

log "Creating GitHub release $VERSION"
if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! gh release create "$VERSION" "$ZIP_PATH" \
        --title "v$VERSION" \
        --notes-file "$NOTES_PATH"; then
        warn "gh release create failed. The version bump is already committed and pushed."
        warn "Once the issue is fixed, finish manually with:"
        warn "  gh release create $VERSION $ZIP_PATH --title v$VERSION --notes-file <path>"
        exit 1
    fi
fi

# ---------- redeploy ----------

if [[ "$REDEPLOY" -eq 1 ]]; then
    log "Redeploying to $INSTALLED_APP"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        pkill -x ClaudeUsageBar 2>/dev/null || true
        sleep 1
        rm -rf "$INSTALLED_APP"
        cp -R "$APP_PATH" "$INSTALLED_APP"
        open "$INSTALLED_APP"
    fi
else
    log "Skipping redeploy (--no-redeploy)"
fi

log "Done. Released v$VERSION → https://github.com/ItzBubschki/ClaudeUsageMenuBar/releases/tag/$VERSION"
