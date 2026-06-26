//
//  GenerateIcon.swift — offline app-icon generator for SwiftShare.
//
//  Renders a modern gradient "squircle" with a white paper-plane glyph and emits
//  an AppIcon.iconset, then leaves iconutil (run by build.sh) to make the .icns.
//  Run with:  swift icon/GenerateIcon.swift
//
//  No network or external assets — pure AppKit/CoreGraphics.
//

import AppKit

// Brand gradient: violet → teal (vibrant, modern).
let topColor    = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.96, alpha: 1) // #6B5CF6
let bottomColor = NSColor(srgbRed: 0.13, green: 0.80, blue: 0.74, alpha: 1) // #21CCBD

/// A white-tinted copy of an SF Symbol, sized to `pointSize`.
func whitePlane(pointSize: CGFloat) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let base = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let out = NSImage(size: base.size)
    out.lockFocus()
    base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

/// Draw the full icon at `px`×`px` into the current graphics context.
func drawIcon(px: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // Rounded "squircle" background.
    let inset = px * 0.085
    let rect = CGRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
    let radius = rect.width * 0.2237
    let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    clip.addClip()

    NSGradient(colors: [topColor, bottomColor])!.draw(in: rect, angle: -55)

    // Soft top-left sheen for depth.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
        .draw(in: rect, angle: -90)

    // Paper-plane glyph, centered with a subtle drop shadow.
    let plane = whitePlane(pointSize: px * 0.46)
    let s = plane.size
    let origin = CGPoint(x: (px - s.width) / 2, y: (px - s.height) / 2)
    ctx.setShadow(offset: CGSize(width: 0, height: -px * 0.012),
                  blur: px * 0.03,
                  color: NSColor(white: 0, alpha: 0.22).cgColor)
    plane.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)

    ctx.restoreGState()
}

func writePNG(px: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(px: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Emit the iconset.
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon")
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",   32),
    ("icon_32x32",      32), ("icon_32x32@2x",   64),
    ("icon_128x128",   128), ("icon_128x128@2x", 256),
    ("icon_256x256",   256), ("icon_256x256@2x", 512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    writePNG(px: spec.px, to: iconset.appendingPathComponent("\(spec.name).png"))
}
print("✓ Wrote \(specs.count) PNGs to \(iconset.path)")
