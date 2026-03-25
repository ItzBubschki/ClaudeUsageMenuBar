import SwiftUI
import Combine

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model)
        } label: {
            MenuBarImageView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Renders the composited icon + bar chart as a single Image for the menu bar label.
struct MenuBarImageView: View {
    @ObservedObject var model: UsageModel
    @State private var image = NSImage()

    var body: some View {
        Image(nsImage: image)
            .onAppear { refresh() }
            .onReceive(model.objectWillChange) { _ in
                DispatchQueue.main.async { refresh() }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                refresh()
            }
    }

    private func refresh() {
        image = renderMenuBarImage(model: model)
    }
}
