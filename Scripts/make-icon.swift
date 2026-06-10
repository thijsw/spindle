#!/usr/bin/env swift
// Renders the Spindle app icon (a CD on a squircle) into Spindle.iconset/
// and compiles it to Spindle.icns with iconutil.
// Usage: swift Scripts/make-icon.swift <output-directory>

import AppKit

let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Resources")
let iconsetURL = outputDir.appendingPathComponent("Spindle.iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    let s = size
    // macOS icon grid: the squircle occupies ~82% of the canvas.
    let plateRect = CGRect(x: s * 0.09, y: s * 0.09, width: s * 0.82, height: s * 0.82)
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: s * 0.185, yRadius: s * 0.185)

    // Background: deep navy → indigo gradient.
    NSGraphicsContext.current?.saveGraphicsState()
    plate.addClip()
    let background = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.25, alpha: 1),
            NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.38, alpha: 1),
            NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.36, alpha: 1),
        ]
    )
    background?.draw(in: plateRect, angle: -60)

    // The disc.
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let discRadius = s * 0.30
    let disc = NSBezierPath(
        ovalIn: CGRect(
            x: center.x - discRadius, y: center.y - discRadius,
            width: discRadius * 2, height: discRadius * 2
        )
    )
    let discFill = NSGradient(
        colors: [
            NSColor(calibratedWhite: 0.88, alpha: 1),
            NSColor(calibratedWhite: 0.72, alpha: 1),
            NSColor(calibratedWhite: 0.93, alpha: 1),
        ]
    )
    discFill?.draw(in: disc, angle: 130)

    // Iridescent sheen wedges.
    let sheenColors: [(NSColor, CGFloat, CGFloat)] = [
        (NSColor(calibratedRed: 0.65, green: 0.85, blue: 1.0, alpha: 0.55), 95, 40),
        (NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.85, alpha: 0.40), 200, 30),
        (NSColor(calibratedRed: 0.75, green: 1.0, blue: 0.85, alpha: 0.40), 320, 25),
    ]
    for (color, start, sweep) in sheenColors {
        let wedge = NSBezierPath()
        wedge.move(to: center)
        wedge.appendArc(
            withCenter: center, radius: discRadius,
            startAngle: start, endAngle: start + sweep
        )
        wedge.close()
        color.setFill()
        wedge.fill()
    }

    // Fine grooves.
    ctx.setLineWidth(max(s * 0.0012, 0.5))
    NSColor(calibratedWhite: 0.55, alpha: 0.25).setStroke()
    var groove = discRadius * 0.45
    while groove < discRadius * 0.96 {
        NSBezierPath(
            ovalIn: CGRect(
                x: center.x - groove, y: center.y - groove,
                width: groove * 2, height: groove * 2
            )
        ).stroke()
        groove += discRadius * 0.07
    }

    // Hub and spindle hole.
    let hubRadius = discRadius * 0.34
    NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: center.x - hubRadius, y: center.y - hubRadius,
        width: hubRadius * 2, height: hubRadius * 2
    )).fill()
    let holeRadius = discRadius * 0.16
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: center.x - holeRadius, y: center.y - holeRadius,
        width: holeRadius * 2, height: holeRadius * 2
    )).fill()

    // Disc rim.
    ctx.setLineWidth(max(s * 0.004, 1))
    NSColor(calibratedWhite: 1.0, alpha: 0.5).setStroke()
    disc.stroke()

    NSGraphicsContext.current?.restoreGraphicsState()
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

for (name, pixels) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    let image = draw(size: CGFloat(pixels))
    writePNG(image, to: iconsetURL.appendingPathComponent("\(name).png"), pixels: pixels)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path, "-o", outputDir.appendingPathComponent("Spindle.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(outputDir.path)/Spindle.icns" : "iconutil failed")
