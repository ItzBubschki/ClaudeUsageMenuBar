# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

macOS menu bar app (SwiftUI, macOS 14+) that displays Claude Code session usage. It reads the OAuth token from the macOS Keychain (`Claude Code-credentials`) and polls `https://api.anthropic.com/api/oauth/usage` every 5 minutes to show 5-hour and 7-day usage windows.

Runs as a menu-bar-only app (no dock icon) using `MenuBarExtra` with `.window` style.

## Build

Open `ClaudeUsageBar.xcodeproj` in Xcode and build with Cmd+R. No package manager dependencies.

For distributable release builds (universal binary, ad-hoc signed):

```
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

## Architecture

Six Swift files in `ClaudeUsageBar/`:

- **ClaudeUsageBarApp.swift** — App entry point. Sets up `MenuBarExtra` with a composited NSImage label and a popover window. `MenuBarImageView` re-renders on model changes and a 60s timer.
- **UsageModel.swift** — `ObservableObject` that owns all state. Fetches usage via URLSession, parses `UsageResponse`/`UsageWindow` (ISO 8601 dates, snake_case keys). Reads the OAuth token from the Keychain via `SecItemCopyMatching`, ranking every credential it finds (see Key details). Refreshes every 300s.
- **Logging.swift** — `AppLog`, the app's `os.Logger` instances (`auth`, `api`, `update`, `app`) under subsystem `com.itzbubschki.ClaudeUsageMenuBar`. Logs token *lengths*, expiries, scopes, and HTTP status codes — never token material.
- **MenuBarLabel.swift** — `BarChartView` (SwiftUI) rendered to `CGImage` via `ImageRenderer`, then composited with the `ClaudeTray` asset into a single template `NSImage` for the menu bar.
- **UpdateManager.swift** — Checks GitHub releases API (`ItzBubschki/ClaudeUsageMenuBar`) hourly for updates, downloads zip assets, replaces the app bundle, and offers relaunch. Owned by `UsageModel`.
- **UsagePopoverView.swift** — Click-to-open popover showing both usage windows with progress bars, reset countdowns, update controls, error display, and a quit button.

## Local development

**Prefer the Debug build for iterating.** Debug uses the bundle id
`com.itzbubschki.ClaudeUsageMenuBar.debug`, so it is a separate identity to macOS: it gets
its own menu bar item, its own preferences, and its own Control Center permission entry.
Churning the Debug identity cannot damage the installed production app. Run it straight
from Xcode (Cmd+R) or from the build directory — do not copy it into `/Applications`.

Only deploy to `/Applications` when you actually need to see the production build.

## Deployment

The app is installed at `/Applications/ClaudeUsageBar.app` and set to launch at login.

```
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

# quit gracefully so the status item is deregistered cleanly, then wait for exit
osascript -e 'quit app "ClaudeUsageBar"'; sleep 2; pkill -x ClaudeUsageBar 2>/dev/null

rm -rf /Applications/ClaudeUsageBar.app
cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeUsageBar-*/Build/Products/Release/ClaudeUsageBar.app /Applications/ClaudeUsageBar.app

# required: an unsigned bundle fails to launch with kLSNoExecutableErr
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: Laurin Niemeyer (V9YWH29X5V)" /Applications/ClaudeUsageBar.app

open /Applications/ClaudeUsageBar.app
```

**Always remove the old bundle before copying.** `cp -R` over an existing `.app` can leave
stale nested files inside it.

**The `codesign` step is not optional.** The `CODE_SIGNING_ALLOWED=NO` build is only
linker-signed (`Sealed Resources=none`), and LaunchServices rejects it with
`kLSNoExecutableErr: The executable is missing` even though the binary is present.

Rules that keep the menu bar item healthy — breaking them can permanently block it (see
Troubleshooting):

- Launch with `open`, never by running `Contents/MacOS/ClaudeUsageBar` directly. A direct
  launch that gets SIGKILLed mid-registration is what corrupts the permission entry.
- Never use `open -n`. Two instances fight over the same status item slot.
- Quit with `osascript -e 'quit app "ClaudeUsageBar"'` and wait, rather than `pkill -9`.
- Avoid tight rebuild/reinstall loops against `/Applications`. Use the Debug build instead.

Deploy whenever you've made meaningful changes the user should see (bug fixes, UI tweaks,
new features).

## Troubleshooting: menu bar icon appears for a moment, then disappears

The icon flashes and vanishes, and the app exits straight away. It survives reinstalling,
re-signing, resetting Control Center, `tccutil reset`, deleting the app's preferences,
logging out, and rebooting.

Confirm it with ControlCenter's own log:

```
log show --last 10m --predicate 'process == "ControlCenter"' --info --debug | grep appStatusItems
```

A blocked item looks like this — note that a healthy item's trace simply stops after
`Created ephemaral instance`:

```
Host properties initialized; (bid:com.itzbubschki.ClaudeUsageMenuBar-Item-0-NNN). clientRequestsVisibility: true
Starting to track host; ...
Created ephemaral instance ... with positioning .ephemeral
Moving host to blocked list; ...          <- the failure
Requesting blocked host to not be visible; ...
```

**Cause.** macOS keeps per-app menu bar permissions in `trackedApplications` inside
`~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`.
Menu bar item churn can leave this app's bundle id listed in *another* app's
`menuItemLocations`. If that other app's entry has `isAllowed = false`, the item is blocked
— even though this app's own entry still says `isAllowed = true`. That is why none of the
usual resets help: the poisoned reference lives under a different app's key. Note
`defaults domains` does not enumerate group containers, so the value is invisible to a
normal preferences search.

**Fix.**

```
scripts/fix-menubar-item.sh              # report only
scripts/fix-menubar-item.sh --fix        # back up, repair, restart cfprefsd + ControlCenter
```

Then relaunch the app. This is machine-local state — it is not fixed by shipping new code,
and it has to be repaired on each affected machine.

Changing the bundle id also "fixes" it, by escaping the poisoned group rather than
repairing it. Commit `3e0cf96` did exactly that in March 2026; the abandoned id
`com.claudeusagebar.app` is still stuck inside `dev.warp.Warp-Stable`'s entry as evidence.
Prefer the repair script — a bundle id change breaks the auto-update identity for existing
installs.

## Releasing

Use `scripts/release.sh <version>` to cut a release. It bumps both `MARKETING_VERSION` lines, builds the universal Release binary, packages the bundle with `ditto --keepParent` into `dist/ClaudeUsageBar.zip`, commits + pushes the version bump, creates the GitHub release with the zip attached, and redeploys to `/Applications`.

```
scripts/release.sh 1.5.2                          # opens $EDITOR for release notes
scripts/release.sh 1.5.2 --notes-file notes.md    # use a prepared notes file
scripts/release.sh 1.5.2 --notes "Fix ..."        # inline notes
scripts/release.sh 1.5.2 --no-redeploy            # skip the /Applications copy
scripts/release.sh 1.5.2 --dry-run                # show what would happen
```

Pre-flight refuses to run if the working tree is dirty, you're not on `main`, `main` isn't synced with `origin`, or the tag already exists. The `gh release create` step requires `gh auth login` first.

## Key details

- The menu bar image is a **template image** (`isTemplate = true`) so it adapts to light/dark mode automatically.
- **Token selection**: a credential blob routinely holds several tokens for different accounts, clients, and scope sets — some long expired. `extractAccessTokenWithExpiry` collects every candidate (root-level and one level down, `accessToken` or `token`) and ranks them: `user:profile` scope first, then not-expired, then furthest expiry, with the source key as a deterministic tie-break. Do not iterate a `Dictionary` and take the first match — Swift randomizes dictionary order per process, so that picks a different (possibly expired) token on each launch.
- Scope is read from the credential key (Claude desktop packs it into the composite cache key) *or* from a `scopes` array on the value (Claude Code's format).
- Claude desktop is read from `oauth:tokenCacheV2` first, falling back to `oauth:tokenCache`. Recent desktop builds leave the older key behind un-refreshed, so its far-future expiries are not evidence of validity. The desktop path is a fallback only — Claude Code wins when both are present. Set `CLAUDEUSAGEBAR_TOKEN_SOURCE=code|desktop` to isolate one source when diagnosing a report.
- Keychain reads use `kSecMatchLimitAll` to consider every item sharing a service name, since duplicates are common. Note that `kSecMatchLimitAll` with `kSecReturnData` fails with `errSecParam (-50)` on the login keychain, so accounts are enumerated first and each item is fetched individually.
- **Logs**: `log show --predicate 'subsystem == "com.itzbubschki.ClaudeUsageMenuBar"' --last 1h --info --debug --style compact`. Use `notice`/`info`, never `debug` — debug-level messages are not persisted and would be missing from logs collected off a user's machine.
- **Bundle ids**: Release is `com.itzbubschki.ClaudeUsageMenuBar`; Debug is `...MenuBar.debug` so development cannot damage the production app's menu bar permission entry.
- API requires `anthropic-beta: oauth-2025-04-20` header.
- Image assets live in `ClaudeUsageBar/Assets.xcassets` (includes `ClaudeTray` for menu bar icon and `ClaudeIcon` for popover).
- **Version bumps**: When fixing bugs or adding features, always increment `MARKETING_VERSION` in `project.pbxproj` (both Debug and Release configurations). Use semantic versioning (MAJOR.MINOR.PATCH). The auto-update mechanism compares this against GitHub release tags. `scripts/release.sh` handles this for you.
- **Auto-update**: `UpdateManager.swift` checks GitHub releases hourly. GitHub release tags must match the version format (e.g., `1.1` or `v1.1`). Release assets should include a `.zip` file containing the `.app` bundle (use `ditto -c -k --keepParent`, not `zip`, to preserve the bundle).
