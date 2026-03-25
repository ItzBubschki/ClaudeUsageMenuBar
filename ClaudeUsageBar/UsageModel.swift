import SwiftUI
import Combine
import Security

class UsageModel: ObservableObject {
    @Published var usagePercent: Double = 0.0        // 0–100 (5h window)
    @Published var resetTimeMinutes: Int = 0         // minutes until 5h reset
    @Published var weeklyUsagePercent: Double = 0.0  // 0–100 (7d window)
    @Published var weeklyResetTimeMinutes: Int = 0   // minutes until 7d reset
    @Published var lastError: String?

    private var refreshTimer: AnyCancellable?

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
        refreshTimer = Timer.publish(every: 120, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.fetchUsage() }
    }

    func fetchUsage() {
        guard let token = Self.getOAuthToken() else {
            DispatchQueue.main.async {
                self.lastError = "Could not read token from Keychain"
            }
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.lastError = error.localizedDescription
                    return
                }

                guard let data = data else {
                    self?.lastError = "No data received"
                    return
                }

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
                    self?.lastError = "Rate limited, will retry"
                    return
                }

                do {
                    let usage = try UsageResponse.decoder.decode(UsageResponse.self, from: data)
                    self?.lastError = nil

                    self?.usagePercent = usage.fiveHour.utilization

                    let resetDate = usage.fiveHour.resetsAt
                    self?.resetTimeMinutes = max(0, Int(resetDate.timeIntervalSinceNow / 60))

                    self?.weeklyUsagePercent = usage.sevenDay.utilization
                    let weeklyResetDate = usage.sevenDay.resetsAt
                    self?.weeklyResetTimeMinutes = max(0, Int(weeklyResetDate.timeIntervalSinceNow / 60))
                } catch {
                    self?.lastError = "Failed to parse usage data"
                }
            }
        }.resume()
    }

    /// Reads the OAuth token from the macOS Keychain using Security.framework.
    private static func getOAuthToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !raw.isEmpty,
              let jsonData = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        // Direct: {"accessToken": "..."}
        if let token = json["accessToken"] as? String { return token }

        // Nested: {"someKey": {"accessToken": "..."}}
        for (_, value) in json {
            if let nested = value as? [String: Any],
               let token = nested["accessToken"] as? String {
                return token
            }
        }

        return nil
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
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct UsageWindow: Decodable {
    let utilization: Double
    let resetsAt: Date

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
