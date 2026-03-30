# Claude Usage Menu Bar

A macOS menu bar app that displays your Claude Code session usage at a glance.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![SwiftUI](https://img.shields.io/badge/SwiftUI-MenuBarExtra-purple)

## Features

- Shows 5-hour rolling window usage as a bar chart directly in the menu bar
- Click to see detailed popover with both 5-hour and 7-day usage windows
- Reset time countdown for each window
- Automatically refreshes every 5 minutes
- Adapts to system light/dark theme
- Auto-update: checks GitHub releases hourly and shows an orange dot on the menu bar icon when an update is available, with in-app download, install, and relaunch

## How it works

The app reads your Claude Code OAuth token from the macOS Keychain and polls the Anthropic usage API. On first launch, macOS will ask for permission to access the "Claude Code-credentials" keychain entry — click "Always Allow" to avoid repeated prompts.

If Claude Code credentials are not found, the app falls back to reading the Claude desktop app's encrypted token cache (`~/Library/Application Support/Claude/config.json`), decrypting it using the "Claude Safe Storage" keychain entry (Electron safeStorage v10 format).

**Requirements:**
- macOS 14+
- Claude Code installed and signed in, **or** the Claude desktop app signed in (used as fallback)
- An active Claude Pro/Max subscription

## Installation

Download the latest `ClaudeUsageBar.zip` from [Releases](https://github.com/ItzBubschki/ClaudeUsageMenuBar/releases), unzip it, and move `ClaudeUsageBar.app` to `/Applications/`.

The app checks for updates automatically. When a new version is available, an orange dot appears on the menu bar icon and the popover shows an install button — no need to manually download again.

## Building from source

1. Clone the repo
2. Open `ClaudeUsageBar.xcodeproj` in Xcode
3. Build and run (Cmd+R)

For a universal release build:

```
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

The app runs as a menu-bar-only application (no dock icon).

## Menu bar layout

```
[Claude icon] [67%] [████████░░░░] [1.5h]
```

- Claude sparkle icon (with orange dot when update available)
- Usage percentage
- Horizontal progress bar
- Time until usage resets
