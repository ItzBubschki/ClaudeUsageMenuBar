import SwiftUI

struct BarChartView: View {
    let usagePercent: Double
    let resetTime: String

    var body: some View {
        HStack(spacing: 5) {
            Text("\(Int(usagePercent))%")
                .font(.system(size: 13, weight: .bold))

            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    .frame(width: 60, height: 11)

                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.white)
                        .frame(width: max(0, 58 * usagePercent / 100.0), height: 9)
                    Spacer(minLength: 0)
                }
                .frame(width: 58, height: 9)
                .clipShape(RoundedRectangle(cornerRadius: 2.5))
            }
            .frame(width: 60, height: 11)

            Text(resetTime)
                .font(.system(size: 13, weight: .bold))
        }
    }
}

/// Composites the Claude tray icon + bar chart + time into a single NSImage.
/// When `showUpdateDot` is true, an orange dot is drawn at the top-right of the icon
/// and the image is non-template so the dot renders in color.
@MainActor
func renderMenuBarImage(model: UsageModel) -> NSImage {
    let scale: CGFloat = 2.0
    let iconLogicalSize: CGFloat = 16
    let spacing: CGFloat = 5
    let showUpdateDot = model.updateManager.updateAvailable

    // Render bar chart
    let chartView = BarChartView(
        usagePercent: model.usagePercent,
        resetTime: model.resetTimeFormatted
    )
    let renderer = ImageRenderer(content: chartView)
    renderer.scale = scale

    guard let chartCG = renderer.cgImage else {
        return NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error") ?? NSImage()
    }

    let chartLogicalW = CGFloat(chartCG.width) / scale
    let chartLogicalH = CGFloat(chartCG.height) / scale

    // Load tray icon from asset catalog
    guard let trayIcon = NSImage(named: "ClaudeTray") else {
        let fallback = NSImage(cgImage: chartCG, size: NSSize(width: chartLogicalW, height: chartLogicalH))
        fallback.isTemplate = true
        return fallback
    }

    let totalWidth = iconLogicalSize + spacing + chartLogicalW
    let totalHeight = max(iconLogicalSize, chartLogicalH)

    if showUpdateDot {
        // Non-template image: draw content in appearance-appropriate color + orange dot
        let composited = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        composited.lockFocus()

        // Detect if menu bar is dark (dark mode or dark menu bar)
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let contentColor: NSColor = isDark ? .white : .black

        // Draw icon tinted to match menu bar
        let iconY = (totalHeight - iconLogicalSize) / 2
        let iconRect = NSRect(x: 0, y: iconY, width: iconLogicalSize, height: iconLogicalSize)
        trayIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        contentColor.setFill()
        iconRect.fill(using: .sourceAtop)

        // Draw chart tinted to match menu bar
        let chartX = iconLogicalSize + spacing
        let chartY = (totalHeight - chartLogicalH) / 2
        let chartRect = NSRect(x: chartX, y: chartY, width: chartLogicalW, height: chartLogicalH)
        let chartNS = NSImage(cgImage: chartCG, size: NSSize(width: chartLogicalW, height: chartLogicalH))
        chartNS.draw(in: chartRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        contentColor.setFill()
        chartRect.fill(using: .sourceAtop)

        // Draw orange dot at top-right of the icon
        let dotSize: CGFloat = 6
        let dotX = iconLogicalSize - dotSize / 2
        let dotY = totalHeight - dotSize
        NSColor.orange.setFill()
        let dotRect = NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
        NSBezierPath(ovalIn: dotRect).fill()

        composited.unlockFocus()
        composited.isTemplate = false
        return composited
    } else {
        // Standard template image (adapts to light/dark automatically)
        let composited = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        composited.lockFocus()

        let iconY = (totalHeight - iconLogicalSize) / 2
        trayIcon.draw(
            in: NSRect(x: 0, y: iconY, width: iconLogicalSize, height: iconLogicalSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )

        let chartX = iconLogicalSize + spacing
        let chartY = (totalHeight - chartLogicalH) / 2
        let chartNS = NSImage(cgImage: chartCG, size: NSSize(width: chartLogicalW, height: chartLogicalH))
        chartNS.draw(
            in: NSRect(x: chartX, y: chartY, width: chartLogicalW, height: chartLogicalH),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )

        composited.unlockFocus()
        composited.isTemplate = true
        return composited
    }
}
