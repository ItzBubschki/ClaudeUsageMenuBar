import Foundation
import Combine
import AppKit

class UpdateManager: NSObject, ObservableObject {
    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String?
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadComplete: Bool = false
    @Published var updateError: String?

    private var checkTimer: AnyCancellable?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadURL: URL?
    private var onDownloadComplete: ((URL) -> Void)?

    private static let repoOwner = "ItzBubschki"
    private static let repoName = "ClaudeUsageMenuBar"
    private static let releasesURL = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"

    override init() {
        super.init()
        checkForUpdate()
        checkTimer = Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkForUpdate() }
    }

    // MARK: - Version Check

    func checkForUpdate() {
        guard let url = URL(string: Self.releasesURL) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.updateError = "Update check failed: \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else { return }

                // 404 means no releases yet — not an error
                if httpResponse.statusCode == 404 {
                    self.updateAvailable = false
                    return
                }

                // Rate limited — silently ignore
                if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
                    return
                }

                guard (200...299).contains(httpResponse.statusCode),
                      let data = data else { return }

                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    let remoteVersion = release.tagName.hasPrefix("v")
                        ? String(release.tagName.dropFirst())
                        : release.tagName

                    let localVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"

                    if Self.isNewerVersion(remoteVersion, than: localVersion) {
                        self.latestVersion = remoteVersion
                        self.updateAvailable = true
                        // Find the .zip asset
                        self.downloadURL = release.assets
                            .first(where: { $0.name.hasSuffix(".zip") })
                            .flatMap { URL(string: $0.browserDownloadUrl) }
                    } else {
                        self.updateAvailable = false
                        self.latestVersion = nil
                    }
                } catch {
                    // Silently fail — don't bother user with update check errors
                }
            }
        }.resume()
    }

    // MARK: - Semantic Version Comparison

    static func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(remoteParts.count, localParts.count)

        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    // MARK: - Download

    func downloadUpdate() {
        guard let downloadURL = downloadURL else {
            updateError = "No download URL available"
            return
        }
        guard !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0.0
        updateError = nil

        let config = URLSessionConfiguration.default
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadTask = downloadSession?.downloadTask(with: downloadURL)
        downloadTask?.resume()
    }

    // MARK: - Install

    private func installFromZip(at zipURL: URL) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ClaudeUsageBarUpdate-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Unzip using ditto (handles macOS app bundles correctly)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", zipURL.path, tempDir.path]
            try unzip.run()
            unzip.waitUntilExit()

            guard unzip.terminationStatus == 0 else {
                throw UpdateError.unzipFailed
            }

            // Find the .app bundle in the unzipped contents
            let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.noAppInZip
            }

            // Remove quarantine attribute
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", newApp.path]
            try xattr.run()
            xattr.waitUntilExit()

            // Replace the current app
            let currentAppPath = Bundle.main.bundlePath
            let currentAppURL = URL(fileURLWithPath: currentAppPath)
            let backupURL = URL(fileURLWithPath: currentAppPath + ".bak")

            // Remove old backup if it exists
            try? fm.removeItem(at: backupURL)

            // Backup current app
            try fm.moveItem(at: currentAppURL, to: backupURL)

            do {
                // Copy new app to original location
                try fm.copyItem(at: newApp, to: currentAppURL)

                // Success — clean up backup and temp
                try? fm.removeItem(at: backupURL)
                try? fm.removeItem(at: tempDir)
                try? fm.removeItem(at: zipURL)

                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.downloadComplete = true
                }
            } catch {
                // Restore from backup on failure
                try? fm.moveItem(at: backupURL, to: currentAppURL)
                try? fm.removeItem(at: tempDir)
                throw error
            }
        } catch {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.updateError = "Install failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Relaunch

    func relaunchApp() {
        let appPath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open \"\(appPath)\""]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move from temp location before it gets cleaned up
        let fm = FileManager.default
        let savedZip = fm.temporaryDirectory.appendingPathComponent("ClaudeUsageBar-update.zip")
        try? fm.removeItem(at: savedZip)
        try? fm.moveItem(at: location, to: savedZip)

        installFromZip(at: savedZip)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.downloadProgress = progress
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error = error {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.updateError = "Download failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Types

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

private enum UpdateError: LocalizedError {
    case unzipFailed
    case noAppInZip

    var errorDescription: String? {
        switch self {
        case .unzipFailed: return "Failed to unzip update"
        case .noAppInZip: return "No app found in update archive"
        }
    }
}
