#!/usr/bin/env swift

import AppKit

private let canvasSize: CGFloat = 1024

private enum Palette {
    static let backgroundTop = NSColor(calibratedRed: 0.98, green: 1.0, blue: 0.99, alpha: 1)
    static let backgroundBottom = NSColor(calibratedRed: 0.94, green: 0.96, blue: 1.0, alpha: 1)
    static let glowMint = NSColor(calibratedRed: 0.43, green: 0.89, blue: 0.71, alpha: 0.18)
    static let glowBlue = NSColor(calibratedRed: 0.40, green: 0.63, blue: 0.99, alpha: 0.16)
    static let baseline = NSColor(calibratedWhite: 0.18, alpha: 0.14)
    static let shadow = NSColor(calibratedWhite: 0.12, alpha: 0.10)
    static let bars: [NSColor] = [
        NSColor(calibratedRed: 0.30, green: 0.84, blue: 0.47, alpha: 1),
        NSColor(calibratedRed: 0.21, green: 0.79, blue: 0.75, alpha: 1),
        NSColor(calibratedRed: 0.37, green: 0.60, blue: 0.97, alpha: 1),
        NSColor(calibratedRed: 0.49, green: 0.51, blue: 0.95, alpha: 1),
    ]
}

private let iconsetFiles: [(filename: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

private let appIconsetFiles = iconsetFiles + [
    ("icon_64x64.png", 64),
    ("icon_1024x1024.png", 1024),
]

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)

        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }

        return path
    }
}

private func scale(_ value: CGFloat, to size: CGFloat) -> CGFloat {
    value * size / canvasSize
}

private func makeImage(size: Int) -> NSImage {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))

    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Unable to create graphics context for icon generation")
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))

    let backgroundRect = CGRect(x: 0, y: 0, width: dimension, height: dimension)
    let backgroundPath = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: scale(240, to: dimension),
        yRadius: scale(240, to: dimension)
    ).cgPath

    context.saveGState()
    context.addPath(backgroundPath)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            Palette.backgroundTop.cgColor,
            Palette.backgroundBottom.cgColor,
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: dimension),
        end: CGPoint(x: dimension, y: 0),
        options: []
    )

    let mintGlow = CGRect(
        x: scale(96, to: dimension),
        y: scale(420, to: dimension),
        width: scale(360, to: dimension),
        height: scale(360, to: dimension)
    )
    context.setFillColor(Palette.glowMint.cgColor)
    context.fillEllipse(in: mintGlow)

    let blueGlow = CGRect(
        x: scale(470, to: dimension),
        y: scale(250, to: dimension),
        width: scale(400, to: dimension),
        height: scale(400, to: dimension)
    )
    context.setFillColor(Palette.glowBlue.cgColor)
    context.fillEllipse(in: blueGlow)

    context.restoreGState()

    let barWidth = scale(132, to: dimension)
    let barGap = scale(24, to: dimension)
    let baselineY = scale(230, to: dimension)
    let baselineHeight = max(scale(10, to: dimension), 1)
    let leftInset = scale(212, to: dimension)
    let barHeights: [CGFloat] = [220, 350, 486, 640].map { scale($0, to: dimension) }

    let baselineRect = CGRect(
        x: leftInset - scale(10, to: dimension),
        y: baselineY - scale(18, to: dimension),
        width: barWidth * 4 + barGap * 3 + scale(36, to: dimension),
        height: baselineHeight
    )
    let baselinePath = NSBezierPath(
        roundedRect: baselineRect,
        xRadius: baselineHeight / 2,
        yRadius: baselineHeight / 2
    ).cgPath
    context.setFillColor(Palette.baseline.cgColor)
    context.addPath(baselinePath)
    context.fillPath()

    for (index, height) in barHeights.enumerated() {
        let x = leftInset + CGFloat(index) * (barWidth + barGap)
        let barRect = CGRect(x: x, y: baselineY, width: barWidth, height: height)
        let cornerRadius = barWidth / 2

        let shadowRect = barRect.offsetBy(dx: 0, dy: -scale(8, to: dimension))
        let shadowPath = NSBezierPath(
            roundedRect: shadowRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).cgPath
        context.setFillColor(Palette.shadow.cgColor)
        context.addPath(shadowPath)
        context.fillPath()

        let barPath = NSBezierPath(
            roundedRect: barRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).cgPath
        context.setFillColor(Palette.bars[index].cgColor)
        context.addPath(barPath)
        context.fillPath()
    }

    return image
}

private func pngData(for image: NSImage) -> Data {
    guard let tiffData = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiffData),
          let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode icon PNG")
    }
    return pngData
}

private func run(_ command: String, _ arguments: [String]) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: command)
    task.arguments = arguments
    try task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        throw NSError(domain: "IconGenerator", code: Int(task.terminationStatus))
    }
}

private let fileManager = FileManager.default
private let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
private let appIconsetURL = rootURL.appendingPathComponent("MyUsage/Resources/AppIcon.appiconset", isDirectory: true)
private let icnsURL = rootURL.appendingPathComponent("MyUsage/Resources/AppIcon.icns")
private let tempIconsetURL = fileManager.temporaryDirectory.appendingPathComponent("MyUsage.iconset", isDirectory: true)

do {
    if fileManager.fileExists(atPath: tempIconsetURL.path) {
        try fileManager.removeItem(at: tempIconsetURL)
    }
    try fileManager.createDirectory(at: tempIconsetURL, withIntermediateDirectories: true)

    for file in appIconsetFiles {
        let image = makeImage(size: file.size)
        let data = pngData(for: image)
        try data.write(to: appIconsetURL.appendingPathComponent(file.filename), options: .atomic)
    }

    for file in iconsetFiles {
        let image = makeImage(size: file.size)
        let data = pngData(for: image)
        try data.write(to: tempIconsetURL.appendingPathComponent(file.filename), options: .atomic)
    }

    try run("/usr/bin/iconutil", ["-c", "icns", tempIconsetURL.path, "-o", icnsURL.path])
    try fileManager.removeItem(at: tempIconsetURL)
    print("Updated app icon assets at \(appIconsetURL.path) and \(icnsURL.path)")
} catch {
    fputs("Failed to generate app icon: \(error)\n", stderr)
    exit(1)
}
