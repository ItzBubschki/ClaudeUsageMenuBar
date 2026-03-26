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
                Button(action: { model.fetchUsage() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .focusable(false)
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
                    Text(model.resetTimeFormatted)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
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
                    Text(model.weeklyResetTimeFormatted)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
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
