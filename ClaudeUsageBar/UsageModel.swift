import SwiftUI
import Combine
import Security
import CommonCrypto

class UsageModel: ObservableObject {
    @Published var usagePercent: Double = 0.0        // 0–100 (5h window)
    @Published var resetTimeMinutes: Int = 0         // minutes until 5h reset
    @Published var weeklyUsagePercent: Double = 0.0  // 0–100 (7d window)
    @Published var weeklyResetTimeMinutes: Int = 0   // minutes until 7d reset
    @Published var lastError: String?

    private var refreshTimer: AnyCancellable?
    private var rateLimitRetryTask: DispatchWorkItem?
    private var consecutiveRateLimits: Int = 0
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
        if minutes >= 60 {
            let h = Double(minutes) / 60.0
            return String(format: "%.1fh", h)
        }
        return "\(minutes)m"
    }

    init() {
        fetchUsage()
        refreshTimer = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.fetchUsage() }
    }

    func fetchUsage() {
        guard var tokenData = Self.getOAuthTokenData() else {
            DispatchQueue.main.async {
                self.lastError = "Could not read token from Keychain"
            }
            return
        }

        // Build the Authorization header value as Data: "Bearer " + token
        var authValue = Data("Bearer ".utf8)
        authValue.append(tokenData)

        // Zero out the raw token data
        tokenData.resetBytes(in: 0..<tokenData.count)

        guard let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            DispatchQueue.main.async { self.lastError = "Invalid API URL" }
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
                    self?.handleRateLimit(retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    return
                }

                // Reset backoff on successful non-429 response
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
            self?.fetchUsage()
        }
        rateLimitRetryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// Reads the OAuth token, trying Claude Code first, then the Claude desktop app as fallback.
    /// Returns the token as Data to minimize String copies in memory.
    private static func getOAuthTokenData() -> Data? {
        // Try Claude Code credentials first
        if let token = getClaudeCodeToken() {
            return token
        }
        // Fall back to Claude desktop app
        return getClaudeDesktopToken()
    }

    /// Reads the OAuth token from the Claude Code keychain entry.
    private static func getClaudeCodeToken() -> Data? {
        guard let data = readKeychainItem(service: "Claude Code-credentials") else {
            return nil
        }
        return extractAccessToken(from: data)
    }

    /// Reads and decrypts the OAuth token from the Claude desktop app.
    private static func getClaudeDesktopToken() -> Data? {
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

        return extractAccessToken(from: decrypted)
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

    /// Extracts the accessToken from a JSON blob (as Data).
    private static func extractAccessToken(from data: Data) -> Data? {
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !raw.isEmpty,
              let jsonData = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        // Direct: {"accessToken": "..."} or {"token": "..."}
        if let token = json["accessToken"] as? String {
            return Data(token.utf8)
        }
        if let token = json["token"] as? String {
            return Data(token.utf8)
        }

        // Nested: {"someKey": {"accessToken": "..."}} or {"someKey": {"token": "..."}}
        // Prefer keys containing "user:profile" scope (needed for the usage API)
        var fallbackToken: String?
        for (key, value) in json {
            if let nested = value as? [String: Any] {
                if let token = nested["accessToken"] as? String {
                    if key.contains("user:profile") { return Data(token.utf8) }
                    fallbackToken = fallbackToken ?? token
                }
                if let token = nested["token"] as? String {
                    if key.contains("user:profile") { return Data(token.utf8) }
                    fallbackToken = fallbackToken ?? token
                }
            }
        }
        if let token = fallbackToken { return Data(token.utf8) }

        return nil
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
