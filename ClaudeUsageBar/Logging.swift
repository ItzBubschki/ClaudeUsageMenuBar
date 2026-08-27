import Foundation
import os

/// Centralized `os.Logger` instances for the app.
///
/// Everything logged through these is deliberately non-secret: token *lengths*,
/// expiry dates, HTTP status codes, candidate counts, and decision points —
/// never token material. Values are interpolated with `privacy: .public` so they
/// survive into `log show` output on someone else's machine; anything that could
/// identify an account (credential keys, URLs beyond the host) stays `.private`.
///
/// To collect logs from a user:
///
///     log show --predicate 'subsystem == "com.itzbubschki.ClaudeUsageMenuBar"' \
///         --last 1h --info --debug --style compact
///
enum AppLog {
    private static let subsystem = "com.itzbubschki.ClaudeUsageMenuBar"

    /// Keychain reads, credential parsing, token selection.
    static let auth = Logger(subsystem: subsystem, category: "auth")
    /// Usage API requests and responses.
    static let api = Logger(subsystem: subsystem, category: "api")
    /// Update checks, downloads, and bundle replacement.
    static let update = Logger(subsystem: subsystem, category: "update")
    /// Launch and lifecycle.
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Formats a date for log output, or "none" when absent. The relative part uses
    /// whichever unit is legible at that distance — an OAuth token that expires in
    /// 40 minutes and one that expired 40 days ago both need to be obvious at a glance.
    static func describe(_ date: Date?) -> String {
        guard let date = date else { return "none" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let delta = date.timeIntervalSinceNow
        let magnitude = abs(delta)
        let relative: String
        if magnitude < 90 * 60 {
            relative = String(format: "%+.0fm", delta / 60)
        } else if magnitude < 48 * 3600 {
            relative = String(format: "%+.1fh", delta / 3600)
        } else {
            relative = String(format: "%+.1fd", delta / 86400)
        }
        return "\(formatter.string(from: date)) (\(relative))"
    }

    /// Strips account and client UUIDs from a desktop credential key, leaving the
    /// scope list. Enough to diagnose a scope problem without logging identifiers.
    static func scopeSummary(fromKey key: String) -> String {
        guard let range = key.range(of: "https://api.anthropic.com:") else { return key }
        return String(key[range.upperBound...])
    }

    /// Logs the bundle path at launch. A path under `AppTranslocation` means the
    /// user launched a quarantined copy from Downloads: the bundle is read-only,
    /// so auto-update cannot replace it.
    static func logLaunchContext() {
        let path = Bundle.main.bundlePath
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        app.notice("launch: version=\(version, privacy: .public) path=\(path, privacy: .public)")
        if path.contains("/AppTranslocation/") {
            app.error("launch: running translocated (quarantined copy, read-only bundle) — auto-update will fail; move the app to /Applications")
        } else if !path.hasPrefix("/Applications/") {
            app.notice("launch: not running from /Applications — auto-update may fail if the bundle is not writable")
        }
    }
}
