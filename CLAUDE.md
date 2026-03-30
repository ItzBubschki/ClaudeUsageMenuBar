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

Five Swift files in `ClaudeUsageBar/`:

- **ClaudeUsageBarApp.swift** — App entry point. Sets up `MenuBarExtra` with a composited NSImage label and a popover window. `MenuBarImageView` re-renders on model changes and a 60s timer.
- **UsageModel.swift** — `ObservableObject` that owns all state. Fetches usage via URLSession, parses `UsageResponse`/`UsageWindow` (ISO 8601 dates, snake_case keys). Reads OAuth token by shelling out to `/usr/bin/security find-generic-password`. Refreshes every 300s.
- **MenuBarLabel.swift** — `BarChartView` (SwiftUI) rendered to `CGImage` via `ImageRenderer`, then composited with the `ClaudeTray` asset into a single template `NSImage` for the menu bar.
- **UpdateManager.swift** — Checks GitHub releases API (`ItzBubschki/ClaudeUsageMenuBar`) hourly for updates, downloads zip assets, replaces the app bundle, and offers relaunch. Owned by `UsageModel`.
- **UsagePopoverView.swift** — Click-to-open popover showing both usage windows with progress bars, reset countdowns, update controls, error display, and a quit button.

## Deployment

The app is installed at `/Applications/ClaudeUsageBar.app` and set to launch at login. After making changes, rebuild and copy the updated app:

```
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
pkill -x ClaudeUsageBar; rm -rf /Applications/ClaudeUsageBar.app
cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeUsageBar-*/Build/Products/Release/ClaudeUsageBar.app /Applications/ClaudeUsageBar.app
```

**Important:** Always remove the old `/Applications/ClaudeUsageBar.app` before copying the new build. Using `cp -R` over an existing `.app` can leave stale nested files inside the bundle.

Then restart: `open /Applications/ClaudeUsageBar.app`

Do this whenever you've made meaningful changes that the user should see (bug fixes, UI tweaks, new features).

## Key details

- The menu bar image is a **template image** (`isTemplate = true`) so it adapts to light/dark mode automatically.
- Token extraction handles both flat (`{"accessToken": "..."}`) and nested JSON structures from the keychain.
- API requires `anthropic-beta: oauth-2025-04-20` header.
- Image assets live in `ClaudeUsageBar/Assets.xcassets` (includes `ClaudeTray` for menu bar icon and `ClaudeIcon` for popover).
- **Version bumps**: When fixing bugs or adding features, always increment `MARKETING_VERSION` in `project.pbxproj` (both Debug and Release configurations). Use semantic versioning (MAJOR.MINOR.PATCH). The auto-update mechanism compares this against GitHub release tags.
- **Auto-update**: `UpdateManager.swift` checks GitHub releases hourly. GitHub release tags must match the version format (e.g., `1.1` or `v1.1`). Release assets should include a `.zip` file containing the `.app` bundle.
