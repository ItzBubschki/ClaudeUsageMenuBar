import SwiftUI
import Combine
import Security
import CommonCrypto

/// Holds a token and its optional expiry date extracted from the credential JSON.
private struct TokenResult {
    let token: Data
    let expiresAt: Date?
}

/// One token found in a credential blob, with the metadata used to rank it.
///
/// A credential blob routinely holds several tokens for different accounts,
/// clients, and scope sets — some of them long expired. Ranking them explicitly
/// keeps selection deterministic; iterating a `Dictionary` and taking the first
/// match does not, because Swift randomizes dictionary order per process.
private struct TokenCandidate {
    let token: String
    let expiresAt: Date?
    /// The JSON key this came from, or "" for a root-level token.
    let sourceKey: String
    /// Whether the credential advertises the `user:profile` scope the usage API needs.
    let hasProfileScope: Bool

    /// Expired tokens are still returned as a last resort — a 401 with a clear
    /// error beats silently having no token at all — but they rank below every
    /// live one. A missing expiry counts as live, since we cannot prove otherwise.
    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// Sort key, highest first: usable scope, then not expired, then furthest expiry.
    /// Scope outranks freshness because the usage API rejects a token without
    /// `user:profile` no matter how fresh it is.
    var rank: (Int, Int, TimeInterval) {
        (hasProfileScope ? 1 : 0,
         isExpired ? 0 : 1,
         expiresAt?.timeIntervalSince1970 ?? 0)
    }
}

class UsageModel: ObservableObject {
    @Published var usagePercent: Double = 0.0        // 0–100 (5h window)
    @Published var fiveHourResetsAt: Date?           // absolute time of 5h reset
    @Published var weeklyUsagePercent: Double = 0.0  // 0–100 (7d window)
    @Published var sevenDayResetsAt: Date?           // absolute time of 7d reset
    @Published var lastError: String?
    @Published var isRefreshing: Bool = false

    let updateManager = UpdateManager()
    private var updateCancellable: AnyCancellable?
    private var refreshTimer: AnyCancellable?
    private var resetCheckTimer: AnyCancellable?
    private var minimumSpinnerEnd: Date?
    private var rateLimitRetryTask: DispatchWorkItem?
    private var consecutiveRateLimits: Int = 0

    private static let cachedTokenService = "ClaudeUsageBar-token"
    private static let cachedTokenExpiryKey = "tokenExpiryTimestamp"
    private static let tokenCacheFallbackMaxAge: TimeInterval = 24 * 3600 // 1 day fallback when no expiry is available
    /// Safety margin: expire the cache slightly before the real token expiry
    /// to avoid using a token that's about to become invalid.
    private static let tokenExpiryMargin: TimeInterval = 5 * 60 // 5 minutes
    private static let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        return URLSession(configuration: config, delegate: APISessionDelegate(), delegateQueue: nil)
    }()

    var resetTimeFormatted: String {
        Self.formatMinutes(Self.minutesUntil(fiveHourResetsAt))
    }

    var weeklyResetTimeFormatted: String {
        Self.formatMinutes(Self.minutesUntil(sevenDayResetsAt))
    }

    private static func minutesUntil(_ date: Date?) -> Int {
        guard let date = date else { return 0 }
        return max(0, Int(date.timeIntervalSinceNow / 60))
    }

    static func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 1440 {
            let d = Double(minutes) / 1440.0
            return String(format: "%.1fd", d)
        }
        if minutes >= 60 {
            let h = Double(minutes) / 60.0
            return String(format: "%.1fh", h)
        }
        return "\(minutes)m"
    }

    init() {
        updateCancellable = updateManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        fetchUsage()
        refreshTimer = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] (_: Date) in
                // Skip if a rate-limit backoff retry is already scheduled,
                // otherwise the timer would race the backoff and ratchet it up.
                guard self?.rateLimitRetryTask == nil else { return }
                self?.fetchUsage()
            }
        resetCheckTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshIfWindowReset() }
    }

    /// If a stored reset date has elapsed, the window has rolled over and our
    /// cached usage is stale — refresh now instead of waiting for the 5-minute timer.
    private func refreshIfWindowReset() {
        guard rateLimitRetryTask == nil, !isRefreshing else { return }
        let now = Date()
        let fiveHourExpired = fiveHourResetsAt.map { $0 <= now } ?? false
        let sevenDayExpired = sevenDayResetsAt.map { $0 <= now } ?? false
        if fiveHourExpired || sevenDayExpired {
            fetchUsage()
        }
    }

    func fetchUsage(forceTokenRefresh: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        minimumSpinnerEnd = Date().addingTimeInterval(1)

        guard var tokenData = Self.getOAuthTokenData(forceRefresh: forceTokenRefresh) else {
            DispatchQueue.main.async {
                AppLog.auth.error("aborting usage fetch: could not read a token from the Keychain")
                self.lastError = "Could not read token from Keychain"
                self.finishRefreshing()
            }
            return
        }

        // Build the Authorization header value as Data: "Bearer " + token
        var authValue = Data("Bearer ".utf8)
        authValue.append(tokenData)

        // Zero out the raw token data
        tokenData.resetBytes(in: 0..<tokenData.count)

        guard let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            DispatchQueue.main.async {
                self.lastError = "Invalid API URL"
                self.finishRefreshing()
            }
            return
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.setValue(String(data: authValue, encoding: .utf8), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Zero out the auth value after setting the header
        authValue.resetBytes(in: 0..<authValue.count)

        Self.apiSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                defer { self?.finishRefreshing() }

                if let error = error {
                    AppLog.api.error("usage request failed: \(error.localizedDescription, privacy: .public)")
                    self?.lastError = error.localizedDescription
                    return
                }

                guard let data = data else {
                    AppLog.api.error("usage request returned no data")
                    self?.lastError = "No data received"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    AppLog.api.error("usage request returned a non-HTTP response")
                    self?.lastError = "Invalid response"
                    return
                }

                AppLog.api.notice("usage response: HTTP \(httpResponse.statusCode, privacy: .public) (\(data.count, privacy: .public) bytes)")

                if httpResponse.statusCode == 429 {
                    // First 429 with a possibly-stale cached token: drop the cache and
                    // retry once with a fresh token. Claude Code rotates the OAuth token
                    // and the previous one can get rate-limited independently.
                    if !forceTokenRefresh && self?.consecutiveRateLimits == 0 {
                        Self.deleteCachedToken()
                        self?.finishRefreshing()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            self?.isRefreshing = false
                            self?.fetchUsage(forceTokenRefresh: true)
                        }
                        return
                    }
                    self?.handleRateLimit(retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    return
                }

                // On 401/403, invalidate cached token and retry once from source
                if [401, 403].contains(httpResponse.statusCode) && !forceTokenRefresh {
                    AppLog.api.notice("HTTP \(httpResponse.statusCode, privacy: .public): dropping the cached token and retrying once from source")
                    Self.deleteCachedToken()
                    self?.finishRefreshing()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.isRefreshing = false
                        self?.fetchUsage(forceTokenRefresh: true)
                    }
                    return
                }

                // Reset backoff on successful non-429 response
                self?.rateLimitRetryTask?.cancel()
                self?.rateLimitRetryTask = nil
                self?.consecutiveRateLimits = 0

                guard (200...299).contains(httpResponse.statusCode) else {
                    if [401, 403].contains(httpResponse.statusCode) {
                        AppLog.api.error("HTTP \(httpResponse.statusCode, privacy: .public) again after a fresh token — the stored credential is being rejected; sign in to Claude Code again")
                    }
                    self?.lastError = "HTTP \(httpResponse.statusCode)"
                    return
                }

                do {
                    let usage = try UsageResponse.decoder.decode(UsageResponse.self, from: data)
                    AppLog.api.notice("usage ok: 5h=\(Int(usage.fiveHour.utilization), privacy: .public)% 7d=\(Int(usage.sevenDay.utilization), privacy: .public)%")
                    self?.lastError = nil

                    self?.usagePercent = usage.fiveHour.utilization

                    self?.fiveHourResetsAt = usage.fiveHour.resetsAt
                        ?? Date().addingTimeInterval(5 * 3600)

                    self?.weeklyUsagePercent = usage.sevenDay.utilization
                    self?.sevenDayResetsAt = usage.sevenDay.resetsAt
                } catch {
                    AppLog.api.error("failed to decode usage response: \(String(describing: error), privacy: .public)")
                    self?.lastError = "Failed to parse usage data"
                }
            }
        }.resume()
    }

    /// Ensures isRefreshing stays true for at least 2 seconds, then clears it.
    private func finishRefreshing() {
        let remaining = (minimumSpinnerEnd ?? Date()).timeIntervalSinceNow
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.isRefreshing = false
            }
        } else {
            isRefreshing = false
        }
    }

    /// Handles a 429 response with exponential backoff, respecting Retry-After if present.
    private func handleRateLimit(retryAfterHeader: String?) {
        consecutiveRateLimits += 1

        // Use Retry-After header if present (seconds), otherwise exponential backoff
        let delay: TimeInterval
        if let retryAfter = retryAfterHeader, let seconds = TimeInterval(retryAfter) {
            delay = min(seconds, 600) // Cap at 10 minutes
        } else {
            // Exponential backoff: 30s, 60s, 120s, 240s, capped at 600s
            delay = min(30.0 * pow(2.0, Double(consecutiveRateLimits - 1)), 600)
        }

        AppLog.api.notice("rate limited (\(self.consecutiveRateLimits, privacy: .public) consecutive), retrying in \(Int(delay), privacy: .public)s, Retry-After=\(retryAfterHeader ?? "none", privacy: .public)")
        lastError = "Rate limited, retrying in \(Int(delay))s"

        rateLimitRetryTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.rateLimitRetryTask = nil
            self?.fetchUsage()
        }
        rateLimitRetryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// Reads the OAuth token, using a local cache to avoid repeated Keychain password prompts.
    /// The cache duration matches the token's actual expiry (minus a safety margin).
    /// Returns the token as Data to minimize String copies in memory.
    private static func getOAuthTokenData(forceRefresh: Bool = false) -> Data? {
        // Check cached token first (unless forced refresh)
        if !forceRefresh, let cached = readCachedToken(), !isCacheExpired() {
            // .info rather than .debug: debug-level messages are not persisted to the
            // unified log, so they would be missing from a log collected off a user's machine.
            AppLog.auth.info("using cached token (len=\(cached.count, privacy: .public), cache expires \(AppLog.describe(Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: cachedTokenExpiryKey))), privacy: .public))")
            return cached
        }
        // CLAUDEUSAGEBAR_TOKEN_SOURCE=code|desktop restricts which credential store is
        // consulted. Claude Code normally wins, which makes the desktop path impossible
        // to exercise on a machine that has both — set it to isolate one source when
        // diagnosing a report. Unset (or "auto") keeps the normal order.
        let sourcePreference = ProcessInfo.processInfo.environment["CLAUDEUSAGEBAR_TOKEN_SOURCE"]?.lowercased()
        if let sourcePreference = sourcePreference, sourcePreference != "auto" {
            AppLog.auth.notice("token source restricted to '\(sourcePreference, privacy: .public)' by CLAUDEUSAGEBAR_TOKEN_SOURCE")
        }
        AppLog.auth.info("reading token from source (forceRefresh=\(forceRefresh, privacy: .public))")

        // Read from source (may trigger Keychain password prompt)
        var result: TokenResult?
        if sourcePreference != "desktop" {
            result = getClaudeCodeTokenWithExpiry()
        }
        if result == nil, sourcePreference != "code" {
            result = getClaudeDesktopTokenWithExpiry()
        }
        guard let result = result else {
            AppLog.auth.error("no token available from Claude Code or Claude desktop")
            return nil
        }

        // Cache it in our own keychain entry (no future prompts for this one)
        saveCachedToken(result.token, expiresAt: result.expiresAt)
        return result.token
    }

    /// Reads the cached token from our own keychain entry.
    private static func readCachedToken() -> Data? {
        return readKeychainItem(service: cachedTokenService)
    }

    /// Saves the token to our own keychain entry with its expiry.
    private static func saveCachedToken(_ token: Data, expiresAt: Date?) {
        // Delete existing entry first
        deleteCachedToken()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cachedTokenService,
            kSecValueData as String: token
        ]
        SecItemAdd(query as CFDictionary, nil)

        if let expiresAt = expiresAt {
            UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: cachedTokenExpiryKey)
        } else {
            // No expiry available — store a fallback expiry relative to now
            let fallbackExpiry = Date().addingTimeInterval(tokenCacheFallbackMaxAge)
            UserDefaults.standard.set(fallbackExpiry.timeIntervalSince1970, forKey: cachedTokenExpiryKey)
        }
    }

    /// Clears the cached token and refreshes usage from source.
    func clearCachedTokenAndRefresh() {
        Self.deleteCachedToken()
        rateLimitRetryTask?.cancel()
        rateLimitRetryTask = nil
        consecutiveRateLimits = 0
        if isRefreshing {
            isRefreshing = false
        }
        fetchUsage(forceTokenRefresh: true)
    }

    /// Deletes the cached token.
    private static func deleteCachedToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cachedTokenService
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: cachedTokenExpiryKey)
    }

    /// Checks whether the cached token has expired based on the token's actual expiry.
    private static func isCacheExpired() -> Bool {
        let expiryTimestamp = UserDefaults.standard.double(forKey: cachedTokenExpiryKey)
        guard expiryTimestamp > 0 else { return true }
        // Expire early by the safety margin to avoid using a nearly-expired token
        return Date().timeIntervalSince1970 >= expiryTimestamp - tokenExpiryMargin
    }

    /// Reads the OAuth token and expiry from the Claude Code keychain entry.
    ///
    /// Several items can share this service name (a leftover from a previous
    /// account, or a second login keychain), so every match is considered rather
    /// than whichever one the Keychain happens to return first.
    private static func getClaudeCodeTokenWithExpiry() -> TokenResult? {
        let items = readKeychainItems(service: "Claude Code-credentials")
        guard !items.isEmpty else {
            AppLog.auth.notice("claude-code: no 'Claude Code-credentials' keychain item")
            return nil
        }
        if items.count > 1 {
            AppLog.auth.notice("claude-code: \(items.count, privacy: .public) keychain items share this service name; ranking tokens from all of them")
        }

        let results = items.enumerated().compactMap { index, data in
            extractAccessTokenWithExpiry(from: data, source: "claude-code[\(index)]")
        }
        return bestOf(results, source: "claude-code")
    }

    /// Reads and decrypts the OAuth token and expiry from the Claude desktop app.
    ///
    /// Recent desktop builds write `oauth:tokenCacheV2` and leave the older
    /// `oauth:tokenCache` behind un-refreshed, so V2 is tried first and V1 is only
    /// a fallback for older installs.
    private static func getClaudeDesktopTokenWithExpiry() -> TokenResult? {
        // Read the encryption key from keychain
        guard let encryptionKey = readKeychainItems(service: "Claude Safe Storage").first else {
            AppLog.auth.notice("claude-desktop: no 'Claude Safe Storage' keychain item")
            return nil
        }

        // Read the encrypted token cache from config.json
        let configPath = NSHomeDirectory() + "/Library/Application Support/Claude/config.json"
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            AppLog.auth.notice("claude-desktop: config.json not readable")
            return nil
        }
        guard let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            AppLog.auth.error("claude-desktop: config.json is not a JSON object")
            return nil
        }

        // Derive AES key using PBKDF2-SHA1 (Chromium convention)
        guard let keyString = String(data: encryptionKey, encoding: .utf8),
              let aesKey = deriveKey(password: Data(keyString.utf8), salt: Data("saltysalt".utf8), iterations: 1003, keyLength: 16) else {
            AppLog.auth.error("claude-desktop: could not derive the AES key from the Safe Storage secret")
            return nil
        }

        let cacheKeys = ["oauth:tokenCacheV2", "oauth:tokenCache"]
        AppLog.auth.info("claude-desktop: config.json present, caches=\(cacheKeys.filter { config[$0] != nil }.joined(separator: ","), privacy: .public)")

        let results = cacheKeys.compactMap { cacheKey -> TokenResult? in
            guard let tokenCacheB64 = config[cacheKey] as? String,
                  let encryptedData = Data(base64Encoded: tokenCacheB64) else {
                return nil
            }

            // Verify Electron safeStorage v10 format: "v10" prefix
            guard encryptedData.count > 19,
                  encryptedData[0] == 0x76, encryptedData[1] == 0x31, encryptedData[2] == 0x30 else {
                AppLog.auth.error("claude-desktop: \(cacheKey, privacy: .public) is not safeStorage v10 format (\(encryptedData.count, privacy: .public) bytes)")
                return nil
            }

            // Skip the "v10" prefix (3 bytes), rest is ciphertext
            let ciphertext = encryptedData[3...]

            // Decrypt using AES-128-CBC with space-filled IV (Chromium v10 on macOS)
            guard let decrypted = decryptAESCBC(key: aesKey, iv: Data(repeating: 0x20, count: 16), data: Data(ciphertext)) else {
                AppLog.auth.error("claude-desktop: \(cacheKey, privacy: .public) failed to decrypt")
                return nil
            }

            return extractAccessTokenWithExpiry(from: decrypted, source: "claude-desktop/\(cacheKey)")
        }

        return bestOf(results, source: "claude-desktop")
    }

    /// Picks a token across several credential blobs, which are passed in preference
    /// order (the store the vendor actively refreshes first).
    ///
    /// The first blob yielding a live token wins. Expiry is *not* used to choose
    /// between blobs: a superseded store can hold tokens with a far-future expiry
    /// that the server has already revoked, so a distant expiry there is not evidence
    /// of validity. Only when every blob is expired does the furthest one win, as a
    /// best effort before the 401 path takes over.
    private static func bestOf(_ results: [TokenResult], source: String) -> TokenResult? {
        guard !results.isEmpty else {
            AppLog.auth.notice("\(source, privacy: .public): no usable token")
            return nil
        }

        let now = Date()
        if let live = results.first(where: { ($0.expiresAt ?? .distantFuture) > now }) {
            if results.count > 1 {
                AppLog.auth.notice("\(source, privacy: .public): using the first live token of \(results.count, privacy: .public) blob(s), expires=\(AppLog.describe(live.expiresAt), privacy: .public)")
            }
            return live
        }

        let newest = results.max(by: { lhs, rhs in
            (lhs.expiresAt?.timeIntervalSince1970 ?? 0) < (rhs.expiresAt?.timeIntervalSince1970 ?? 0)
        })
        AppLog.auth.error("\(source, privacy: .public): all \(results.count, privacy: .public) blob(s) are expired; using the newest (\(AppLog.describe(newest?.expiresAt), privacy: .public))")
        return newest
    }

    /// Reads every generic password matching a service name from the keychain.
    ///
    /// Returns all matches rather than one, because duplicate items under the same
    /// service name are common and `kSecMatchLimitOne` picks among them arbitrarily.
    private static func readKeychainItems(service: String) -> [Data] {
        // The macOS login keychain rejects kSecMatchLimitAll combined with
        // kSecReturnData (errSecParam, -50) whether or not kSecReturnAttributes is
        // also set. So the matching accounts are listed first, then each item's data
        // is fetched with its own single-item query.
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var listResult: AnyObject?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)

        guard listStatus == errSecSuccess, let entries = listResult as? [[String: Any]] else {
            if listStatus != errSecItemNotFound {
                let message = SecCopyErrorMessageString(listStatus, nil) as String? ?? "unknown"
                AppLog.auth.error("keychain enumeration failed for '\(service, privacy: .public)': OSStatus \(listStatus, privacy: .public) (\(message, privacy: .public))")
                // Fall back to a plain single-item read, which some keychain
                // configurations accept even when enumeration does not.
                if let single = readKeychainData(service: service, account: nil) {
                    return [single]
                }
            }
            return []
        }

        // Distinct accounts only: two items sharing a service *and* account are
        // indistinguishable to a fetch, so one read covers them.
        var accounts: [String?] = []
        for entry in entries {
            let account = entry[kSecAttrAccount as String] as? String
            if !accounts.contains(where: { $0 == account }) {
                accounts.append(account)
            }
        }

        let items = accounts.compactMap { readKeychainData(service: service, account: $0) }
        if items.count != entries.count {
            AppLog.auth.notice("keychain '\(service, privacy: .public)': \(entries.count, privacy: .public) item(s) matched, \(items.count, privacy: .public) readable")
        }
        return items
    }

    /// Fetches the data of a single keychain item, optionally narrowed by account.
    private static func readKeychainData(service: String, account: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account = account {
            query[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                AppLog.auth.error("keychain read failed for '\(service, privacy: .public)': OSStatus \(status, privacy: .public) (\(message, privacy: .public))")
            }
            return nil
        }
        return data
    }

    /// Reads a single generic password from the keychain (used for our own cache entry,
    /// which this app is the only writer of).
    private static func readKeychainItem(service: String) -> Data? {
        return readKeychainItems(service: service).first
    }

    /// Extracts the best usable access token and its expiry from a JSON blob (as Data).
    ///
    /// A blob can hold many tokens keyed by account, client, and scope set. They are
    /// all collected, then ranked by `TokenCandidate.rank` so the choice is stable
    /// across launches and prefers a live `user:profile` token over an expired one.
    private static func extractAccessTokenWithExpiry(from data: Data, source: String) -> TokenResult? {
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !raw.isEmpty,
              let jsonData = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            AppLog.auth.error("\(source, privacy: .public): credential blob is not a JSON object (\(data.count, privacy: .public) bytes)")
            return nil
        }

        let candidates = collectCandidates(from: json)
        guard !candidates.isEmpty else {
            AppLog.auth.error("\(source, privacy: .public): no token field found in credential JSON (keys=\(json.keys.count, privacy: .public))")
            return nil
        }

        // Sort descending by rank, with the source key as a deterministic tie-break
        // so two equally-ranked candidates never alternate between launches.
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            return lhs.sourceKey < rhs.sourceKey
        }

        AppLog.auth.info("\(source, privacy: .public): \(sorted.count, privacy: .public) token candidate(s)")
        for candidate in sorted {
            AppLog.auth.info(
                "  candidate scopes=\(AppLog.scopeSummary(fromKey: candidate.sourceKey), privacy: .public) profile=\(candidate.hasProfileScope, privacy: .public) expired=\(candidate.isExpired, privacy: .public) expires=\(AppLog.describe(candidate.expiresAt), privacy: .public) len=\(candidate.token.count, privacy: .public) key=\(candidate.sourceKey, privacy: .private)"
            )
        }

        let best = sorted[0]
        if !best.hasProfileScope {
            AppLog.auth.error("\(source, privacy: .public): selected token lacks the user:profile scope — the usage API will reject it")
        }
        if best.isExpired {
            AppLog.auth.error("\(source, privacy: .public): every candidate is expired; using the newest (expired \(AppLog.describe(best.expiresAt), privacy: .public)) — sign in again to refresh")
        }
        AppLog.auth.notice("\(source, privacy: .public): selected token scopes=\(AppLog.scopeSummary(fromKey: best.sourceKey), privacy: .public) expires=\(AppLog.describe(best.expiresAt), privacy: .public)")

        return TokenResult(token: Data(best.token.utf8), expiresAt: best.expiresAt)
    }

    /// Gathers every token in a credential JSON object, at the root and one level down.
    private static func collectCandidates(from json: [String: Any]) -> [TokenCandidate] {
        var candidates: [TokenCandidate] = []

        /// Reads a token out of one credential dictionary. `key` is "" at the root.
        func candidate(from dict: [String: Any], key: String) -> TokenCandidate? {
            guard let token = (dict["accessToken"] as? String) ?? (dict["token"] as? String),
                  !token.isEmpty else {
                return nil
            }
            // The scope can live in the key (Claude desktop packs it into the
            // composite cache key) or in a `scopes` array on the value itself
            // (Claude Code's credential format).
            let scopesInValue = (dict["scopes"] as? [String]) ?? []
            let hasProfileScope = key.contains("user:profile") || scopesInValue.contains("user:profile")
            return TokenCandidate(token: token,
                                  expiresAt: parseExpiry(from: dict),
                                  sourceKey: key,
                                  hasProfileScope: hasProfileScope)
        }

        // Direct: {"accessToken": "...", "expiresAt": "..."} or {"token": "..."}
        if let root = candidate(from: json, key: "") {
            candidates.append(root)
        }

        // Nested: {"someKey": {"accessToken": "..."}} or {"someKey": {"token": "..."}}
        for (key, value) in json {
            if let nested = value as? [String: Any], let found = candidate(from: nested, key: key) {
                candidates.append(found)
            }
        }

        return candidates
    }

    /// Parses an expiry date from a credential JSON dictionary.
    /// Supports common OAuth field names: expiresAt, expires_at (ISO 8601 strings
    /// or numeric timestamps in seconds or milliseconds since epoch),
    /// and expiresIn / expires_in (seconds from now).
    private static func parseExpiry(from json: [String: Any]) -> Date? {
        // ISO 8601 date string fields
        for key in ["expiresAt", "expires_at"] {
            if let dateString = json[key] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: dateString) { return date }
                // Retry without fractional seconds
                let basic = ISO8601DateFormatter()
                basic.formatOptions = [.withInternetDateTime]
                if let date = basic.date(from: dateString) { return date }
            }
            // Also handle numeric timestamps (seconds or milliseconds since epoch)
            if let timestamp = json[key] as? TimeInterval, timestamp > 0 {
                return Date(timeIntervalSince1970: normalizeEpoch(timestamp))
            }
            if let timestamp = json[key] as? Int, timestamp > 0 {
                return Date(timeIntervalSince1970: normalizeEpoch(TimeInterval(timestamp)))
            }
        }

        // Relative seconds fields
        for key in ["expiresIn", "expires_in"] {
            if let seconds = json[key] as? TimeInterval, seconds > 0 {
                return Date().addingTimeInterval(normalizeEpoch(seconds))
            }
            if let seconds = json[key] as? Int, seconds > 0 {
                return Date().addingTimeInterval(normalizeEpoch(TimeInterval(seconds)))
            }
        }

        return nil
    }

    /// Converts a numeric timestamp to seconds since epoch.
    /// Values above 10 billion are treated as milliseconds (epoch in ms),
    /// since a seconds-based epoch won't exceed 10 billion until the year 2286.
    private static func normalizeEpoch(_ value: TimeInterval) -> TimeInterval {
        return value > 10_000_000_000 ? value / 1000.0 : value
    }

    /// Derives an AES key using PBKDF2-SHA1 (Chromium convention).
    private static func deriveKey(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data? {
        var derivedKey = Data(count: keyLength)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(iterations),
                        derivedKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        return result == kCCSuccess ? derivedKey : nil
    }

    /// Decrypts AES-128-CBC with PKCS7 padding.
    private static func decryptAESCBC(key: Data, iv: Data, data: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var outLength = 0
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let result = data.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, data.count,
                        buffer, bufferSize,
                        &outLength
                    )
                }
            }
        }

        guard result == kCCSuccess else { return nil }
        return Data(bytes: buffer, count: outLength)
    }
}

// MARK: - API Response Types

struct UsageResponse: Decodable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = formatter.date(from: string) { return date }
            // Fallback without fractional seconds
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            if let date = basic.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
        return decoder
    }
}

struct UsageWindow: Decodable {
    let utilization: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

// MARK: - Session Delegate (redirect protection)

/// Blocks redirects to prevent the Authorization header from being forwarded to a different host.
class APISessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Reject all redirects — the Anthropic API should not redirect
        completionHandler(nil)
    }
}
