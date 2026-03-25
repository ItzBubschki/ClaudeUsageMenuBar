# Claude Usage Menu Bar

A macOS menu bar app that displays your Claude Code session usage at a glance.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![SwiftUI](https://img.shields.io/badge/SwiftUI-MenuBarExtra-purple)

## Features

- Shows 5-hour rolling window usage as a bar chart directly in the menu bar
- Click to see detailed popover with both 5-hour and 7-day usage windows
- Reset time countdown for each window
- Automatically refreshes every 2 minutes
- Adapts to system light/dark theme

## How it works

The app reads your Claude Code OAuth token from the macOS Keychain and polls the Anthropic usage API. On first launch, macOS will ask for permission to access the "Claude Code-credentials" keychain entry — click "Always Allow" to avoid repeated prompts.

**Requirements:**
- macOS 14+
- Claude Code installed and signed in (the app reads its stored credentials)
- An active Claude Pro/Max subscription

## Building

1. Clone the repo
2. Open `ClaudeUsageBar.xcodeproj` in Xcode
3. Build and run (Cmd+R)

The app runs as a menu-bar-only application (no dock icon).

## Menu bar layout

```
[Claude icon] [67%] [████████░░░░] [1.5h]
```

- Claude sparkle icon
- Usage percentage
- Horizontal progress bar
- Time until usage resets
