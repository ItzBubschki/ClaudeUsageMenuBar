import SwiftUI
import Combine
import Security
import CommonCrypto

/// Holds a token and its optional expiry date extracted from the credential JSON.
private struct TokenResult {
    let token: Data
    let expiresAt: Date?
}

class UsageModel: ObservableObject {
    @Published var usagePercent: Double = 0.0        // 0–100 (5h window)
    @Published var resetTimeMinutes: Int = 0         // minutes until 5h reset
    @Published var weeklyUsagePercent: Double = 0.0  // 0–100 (7d window)
    @Published var weeklyResetTimeMinutes: Int = 0   // minutes until 7d reset
    @Published var lastError: String?
    @Published var isRefreshing: Bool = false

    let updateManager = UpdateManager()
    private var updateCancellable: AnyCancellable?
    private var refreshTimer: AnyCancellable?
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
        Self.formatMinutes(resetTimeMinutes)
    }

    var weeklyResetTimeFormatted: String {
        Self.formatMinutes(weeklyResetTimeMinutes)
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
    }

    func fetchUsage(forceTokenRefresh: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        minimumSpinnerEnd = Date().addingTimeInterval(1)

        guard var tokenData = Self.getOAuthTokenData(forceRefresh: forceTokenRefresh) else {
            DispatchQueue.main.async {
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
                    self?.lastError = error.localizedDescription
                    return
                }

                guard let data = data else {
                    self?.lastError = "No data received"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.lastError = "Invalid response"
                    return
                }

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
                    self?.lastError = "HTTP \(httpResponse.statusCode)"
                    return
                }

                do {
                    let usage = try UsageResponse.decoder.decode(UsageResponse.self, from: data)
                    self?.lastError = nil

                    self?.usagePercent = usage.fiveHour.utilization

                    if let resetDate = usage.fiveHour.resetsAt {
                        self?.resetTimeMinutes = max(0, Int(resetDate.timeIntervalSinceNow / 60))
                    } else {
                        self?.resetTimeMinutes = 300 // 5 hours
                    }

                    self?.weeklyUsagePercent = usage.sevenDay.utilization
                    if let weeklyResetDate = usage.sevenDay.resetsAt {
                        self?.weeklyResetTimeMinutes = max(0, Int(weeklyResetDate.timeIntervalSinceNow / 60))
                    } else {
                        self?.weeklyResetTimeMinutes = 0
                    }
                } catch {
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
            return cached
        }

        // Read from source (may trigger Keychain password prompt)
        guard let result = getClaudeCodeTokenWithExpiry() ?? getClaudeDesktopTokenWithExpiry() else {
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
    private static func getClaudeCodeTokenWithExpiry() -> TokenResult? {
        guard let data = readKeychainItem(service: "Claude Code-credentials") else {
            return nil
        }
        return extractAccessTokenWithExpiry(from: data)
    }

    /// Reads and decrypts the OAuth token and expiry from the Claude desktop app.
    private static func getClaudeDesktopTokenWithExpiry() -> TokenResult? {
        // Read the encryption key from keychain
        guard let encryptionKey = readKeychainItem(service: "Claude Safe Storage") else {
            return nil
        }

        // Read the encrypted token cache from config.json
        let configPath = NSHomeDirectory() + "/Library/Application Support/Claude/config.json"
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let tokenCacheB64 = config["oauth:tokenCache"] as? String,
              let encryptedData = Data(base64Encoded: tokenCacheB64) else {
            return nil
        }

        // Verify Electron safeStorage v10 format: "v10" prefix
        guard encryptedData.count > 19,
              encryptedData[0] == 0x76, encryptedData[1] == 0x31, encryptedData[2] == 0x30 else {
            return nil
        }

        // Skip the "v10" prefix (3 bytes), rest is ciphertext
        let ciphertext = encryptedData[3...]

        // Derive AES key using PBKDF2-SHA1 (Chromium convention)
        guard let keyString = String(data: encryptionKey, encoding: .utf8),
              let aesKey = deriveKey(password: Data(keyString.utf8), salt: Data("saltysalt".utf8), iterations: 1003, keyLength: 16) else {
            return nil
        }

        // Decrypt using AES-128-CBC with space-filled IV (Chromium v10 on macOS)
        guard let decrypted = decryptAESCBC(key: aesKey, iv: Data(repeating: 0x20, count: 16), data: Data(ciphertext)) else {
            return nil
        }

        return extractAccessTokenWithExpiry(from: decrypted)
    }

    /// Reads a generic password from the keychain.
    private static func readKeychainItem(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    /// Extracts the accessToken and optional expiry from a JSON blob (as Data).
    private static func extractAccessTokenWithExpiry(from data: Data) -> TokenResult? {
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !raw.isEmpty,
              let jsonData = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        // Direct: {"accessToken": "...", "expiresAt": "..."} or {"token": "..."}
        if let token = json["accessToken"] as? String {
            let expiry = parseExpiry(from: json)
            return TokenResult(token: Data(token.utf8), expiresAt: expiry)
        }
        if let token = json["token"] as? String {
            let expiry = parseExpiry(from: json)
            return TokenResult(token: Data(token.utf8), expiresAt: expiry)
        }

        // Nested: {"someKey": {"accessToken": "..."}} or {"someKey": {"token": "..."}}
        // Prefer keys containing "user:profile" scope (needed for the usage API)
        var fallbackToken: String?
        var fallbackExpiry: Date?
        for (key, value) in json {
            if let nested = value as? [String: Any] {
                if let token = nested["accessToken"] as? String {
                    if key.contains("user:profile") {
                        return TokenResult(token: Data(token.utf8), expiresAt: parseExpiry(from: nested))
                    }
                    if fallbackToken == nil {
                        fallbackToken = token
                        fallbackExpiry = parseExpiry(from: nested)
                    }
                }
                if let token = nested["token"] as? String {
                    if key.contains("user:profile") {
                        return TokenResult(token: Data(token.utf8), expiresAt: parseExpiry(from: nested))
                    }
                    if fallbackToken == nil {
                        fallbackToken = token
                        fallbackExpiry = parseExpiry(from: nested)
                    }
                }
            }
        }
        if let token = fallbackToken {
            return TokenResult(token: Data(token.utf8), expiresAt: fallbackExpiry)
        }

        return nil
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
