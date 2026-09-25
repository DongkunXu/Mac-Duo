// Draws the Mac Duo app icon (two flat glass panes opened halfway, floating above a soft shadow)
// into every PNG of Sources/MacDuo/Assets.xcassets/AppIcon.appiconset.
//
// Usage (from the repository root): swift Scripts/make-icon.swift

import AppKit

/// Design in 100 × 100 tile units (y down); the tile fills 824 of 1024 pixels, Apple's macOS icon grid.
enum Design {
    static let tileRadius: CGFloat = 22.5
    static let tile = color(0xF4F4F6)
    static let line = color(0x1D1D1F)
    static let glass = color(0x0A84FF)
    static let strokeWidth: CGFloat = 1.6

    // The shared edge (hinge) runs from A (front) to D (back); B–C and E–F are the free edges.
    static let a = CGPoint(x: 40, y: 70), d = CGPoint(x: 62, y: 58)
    static let b = CGPoint(x: 25, y: 47), c = CGPoint(x: 47, y: 35)
    static let e = CGPoint(x: 61, y: 54), f = CGPoint(x: 83, y: 42)
    static let leftPane = [a, b, c, d], rightPane = [a, e, f, d]
    static let leftOpacity: CGFloat = 0.14, rightOpacity: CGFloat = 0.26

    static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

func render(pixels: Int) -> Data {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a \(pixels) px bitmap context")
    }
    let pixelScale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: pixelScale, y: -pixelScale)
    context.translateBy(x: 100, y: 100)
    context.scaleBy(x: 8.24, y: 8.24)
    let unitsPerPixel = 1 / (pixelScale * 8.24)

    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                           cornerWidth: Design.tileRadius, cornerHeight: Design.tileRadius, transform: nil))
    context.setFillColor(Design.tile)
    context.fillPath()

    // Fit the panes into the tile, centred slightly above the middle.
    let points = Design.leftPane + Design.rightPane
    let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
    let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
    let fit = 62 / max(maxX - minX, maxY - minY)
    let centre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    let bottom = 46 + (maxY - centre.y) * fit

    context.addEllipse(in: CGRect(x: 50 - 21, y: bottom + 9 - 2.4, width: 42, height: 4.8))
    context.setFillColor(Design.color(0x000000, alpha: 0.10))
    context.fillPath()

    context.saveGState()
    context.translateBy(x: 50, y: 46)
    context.scaleBy(x: fit, y: fit)
    context.translateBy(x: -centre.x, y: -centre.y)
    // Keep lines at least one pixel wide in the small sizes.
    let width = max(Design.strokeWidth, unitsPerPixel) / fit
    for (pane, opacity) in [(Design.leftPane, Design.leftOpacity), (Design.rightPane, Design.rightOpacity)] {
        let path = CGMutablePath()
        path.addLines(between: pane)
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(Design.glass.copy(alpha: opacity)!)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(Design.line)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.strokePath()
    }
    context.restoreGState()

    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("could not encode the \(pixels) px icon")
    }
    return png
}

let output = URL(fileURLWithPath: "Sources/MacDuo/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
guard FileManager.default.fileExists(atPath: output.path) else {
    fatalError("run from the repository root: \(output.path) not found")
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points).png" : "icon_\(points)@2x.png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
    }
}
print("wrote \(output.path)")
