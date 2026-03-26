#!/usr/bin/env swift

import AppKit
import CoreGraphics

// Claude brand colors
let claudeOrange = NSColor(red: 0xD7/255.0, green: 0x76/255.0, blue: 0x55/255.0, alpha: 1.0)
let claudeCream = NSColor(red: 0xFC/255.0, green: 0xF2/255.0, blue: 0xEE/255.0, alpha: 1.0)
let progressStart = NSColor(red: 0xE8/255.0, green: 0x9B/255.0, blue: 0x7B/255.0, alpha: 1.0)
let progressEnd = NSColor(red: 0xD7/255.0, green: 0x76/255.0, blue: 0x55/255.0, alpha: 1.0)
let trackColor = NSColor(white: 0.88, alpha: 1.0)

func generateIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let padding = s * 0.04
    let iconRect = NSRect(x: padding, y: padding, width: s - padding * 2, height: s - padding * 2)

    // Background: rounded rect (macOS icon shape)
    let cornerRadius = s * 0.22
    let bgPath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Gradient background (subtle)
    let gradient = NSGradient(starting: NSColor(red: 0.98, green: 0.95, blue: 0.92, alpha: 1.0),
                               ending: NSColor(red: 0.95, green: 0.90, blue: 0.87, alpha: 1.0))!
    gradient.draw(in: bgPath, angle: -90)

    // Progress ring
    let center = NSPoint(x: s / 2, y: s / 2)
    let ringRadius = s * 0.34
    let ringWidth = s * 0.055

    // Track (background ring)
    ctx.setStrokeColor(trackColor.cgColor)
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Progress arc (~70% filled, starting from top, going clockwise)
    let startAngle = CGFloat.pi / 2  // top
    let progress: CGFloat = 0.70

    // Draw progress with gradient effect (multiple segments)
    let segments = 60
    let totalArc = progress * .pi * 2
    for i in 0..<segments {
        let t = CGFloat(i) / CGFloat(segments)
        let t2 = CGFloat(i + 1) / CGFloat(segments)
        // Go clockwise (adding to angle in CG coords = counter-clockwise visually = clockwise on screen)
        let a1 = startAngle + t * totalArc
        let a2 = startAngle + t2 * totalArc

        let r = progressStart.redComponent + t * (progressEnd.redComponent - progressStart.redComponent)
        let g = progressStart.greenComponent + t * (progressEnd.greenComponent - progressStart.greenComponent)
        let b = progressStart.blueComponent + t * (progressEnd.blueComponent - progressStart.blueComponent)

        ctx.setStrokeColor(NSColor(red: r, green: g, blue: b, alpha: 1.0).cgColor)
        ctx.setLineWidth(ringWidth)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: ringRadius, startAngle: a1, endAngle: a2, clockwise: false)
        ctx.strokePath()
    }

    // Claude sparkle/asterisk in center
    let symbolSize = s * 0.30
    let symbolCenter = center

    ctx.saveGState()

    // Draw 6-pointed asterisk (Claude's sparkle)
    let armLength = symbolSize * 0.48
    let armWidth = symbolSize * 0.14
    let numArms = 6

    ctx.setFillColor(claudeOrange.cgColor)

    for i in 0..<numArms {
        let angle = CGFloat(i) * (.pi / CGFloat(numArms / 2)) + .pi / 6

        ctx.saveGState()
        ctx.translateBy(x: symbolCenter.x, y: symbolCenter.y)
        ctx.rotate(by: angle)

        // Tapered arm shape
        let armPath = CGMutablePath()
        armPath.move(to: CGPoint(x: -armWidth * 0.7, y: 0))
        armPath.addLine(to: CGPoint(x: -armWidth * 0.25, y: armLength))
        armPath.addQuadCurve(to: CGPoint(x: armWidth * 0.25, y: armLength),
                             control: CGPoint(x: 0, y: armLength + armWidth * 0.4))
        armPath.addLine(to: CGPoint(x: armWidth * 0.7, y: 0))
        armPath.closeSubpath()

        ctx.addPath(armPath)
        ctx.fillPath()

        ctx.restoreGState()
    }

    // Center circle
    let centerDotRadius = armWidth * 1.0
    ctx.fillEllipse(in: CGRect(x: symbolCenter.x - centerDotRadius,
                                y: symbolCenter.y - centerDotRadius,
                                width: centerDotRadius * 2,
                                height: centerDotRadius * 2))

    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, path: String, pixelSize: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                pixelsWide: pixelSize,
                                pixelsHigh: pixelSize,
                                bitsPerSample: 8,
                                samplesPerPixel: 4,
                                hasAlpha: true,
                                isPlanar: false,
                                colorSpaceName: .deviceRGB,
                                bytesPerRow: 0,
                                bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path) (\(pixelSize)x\(pixelSize))")
}

// Generate all required sizes
let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] :
    "ClaudeUsageBar/Assets.xcassets/AppIcon.appiconset"

let sizes: [(name: String, pointSize: Int, scale: Int)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2),
]

let icon = generateIcon(size: 1024)

for entry in sizes {
    let pixelSize = entry.pointSize * entry.scale
    savePNG(icon, path: "\(outputDir)/\(entry.name)", pixelSize: pixelSize)
}

print("Done!")
