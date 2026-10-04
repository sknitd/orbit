#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'AppKit and iconutil on macOS are required to draw the CornerOrbit icon.' >&2; exit 1; }
mkdir -p build/AppIcon.iconset build/icon-module-cache
cat > build/DrawCornerIcon.swift <<'SWIFT'
import AppKit
import Foundation

@MainActor
func drawIcon(side: Int, destination: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
    let scale = CGFloat(side) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let backdrop = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 200, yRadius: 200)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.17, blue: 0.23, alpha: 1),
                              ending: NSColor(srgbRed: 0.04, green: 0.06, blue: 0.10, alpha: 1))!
    gradient.draw(in: backdrop, angle: -90)
    let marks = NSBezierPath()
    for (x, y, dx, dy) in [(CGFloat(242), CGFloat(782), CGFloat(1), CGFloat(-1)),
                            (782, 782, -1, -1), (242, 242, 1, 1), (782, 242, -1, 1)] {
        marks.move(to: NSPoint(x: x + dx * 132, y: y))
        marks.line(to: NSPoint(x: x, y: y))
        marks.line(to: NSPoint(x: x, y: y + dy * 132))
    }
    marks.lineWidth = 58; marks.lineCapStyle = .round; marks.lineJoinStyle = .round
    NSColor(srgbRed: 0.27, green: 0.81, blue: 0.98, alpha: 1).setStroke()
    marks.stroke()
    NSColor(srgbRed: 0.28, green: 0.51, blue: 1, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 431, y: 431, width: 162, height: 162)).fill()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: destination, options: .atomic)
}

@main
struct CornerIconRenderer {
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for points in [16, 32, 128, 256, 512] {
            try drawIcon(side: points, destination: output.appendingPathComponent("icon_\(points)x\(points).png"))
            try drawIcon(side: points * 2, destination: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
    }
}
SWIFT
icon_arch="$(uname -m)"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -target "$icon_arch-apple-macos14.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$task_root/build/icon-module-cache" build/DrawCornerIcon.swift -o build/DrawCornerIcon
build/DrawCornerIcon "$task_root/build/AppIcon.iconset"
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
[[ -s build/AppIcon.icns ]]
