import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image("ClaudeIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: { model.fetchUsage() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("5-hour usage")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(model.usagePercent))%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }

                ProgressView(value: model.usagePercent, total: 100)

                HStack {
                    Text("Resets in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(model.resetTimeFormatted)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("7-day usage")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(model.weeklyUsagePercent))%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }

                ProgressView(value: model.weeklyUsagePercent, total: 100)

                HStack {
                    Text("Resets in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(model.weeklyResetTimeFormatted)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            if model.updateManager.updateAvailable {
                if model.updateManager.downloadComplete {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Ready to install v\(model.updateManager.latestVersion ?? "")")
                            .font(.caption)
                    }
                } else if model.updateManager.isDownloading {
                    VStack(spacing: 4) {
                        HStack {
                            Text("Downloading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(model.updateManager.downloadProgress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                        }
                        ProgressView(value: model.updateManager.downloadProgress)
                    }
                } else {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.orange)
                        Text("v\(model.updateManager.latestVersion ?? "")")
                            .font(.caption)
                    }
                }

                if let error = model.updateManager.updateError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                if model.updateManager.updateAvailable {
                    if model.updateManager.downloadComplete {
                        Button("Relaunch") {
                            model.updateManager.relaunchApp()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                        .controlSize(.small)
                    } else if !model.updateManager.isDownloading {
                        Button("Install Update") {
                            model.updateManager.downloadUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                        .controlSize(.small)
                    }
                } else {
                    Button("Clear Cache") {
                        model.clearCachedTokenAndRefresh()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 240)
    }
}
