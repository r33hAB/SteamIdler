// Draws the app icon into an .iconset folder for iconutil. It is the same mark
// the Windows build draws for its tray icon, so the repo needs no binary asset.
//
// Usage: make-icon <output.iconset>
import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: a rounded tile with a margin around it.
    let size = CGFloat(pixels)
    let tile = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    NSColor(srgbRed: 23 / 255, green: 26 / 255, blue: 33 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).fill()

    // The Windows mark on its 32-unit grid (y down): an arc in (5,5,21,21) from
    // 40 degrees sweeping 290 clockwise, and a dot in (14,2,7,7).
    let unit = tile.width / 32
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: tile.minX + x * unit, y: tile.maxY - y * unit)
    }
    NSColor(srgbRed: 102 / 255, green: 192 / 255, blue: 244 / 255, alpha: 1).set()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: point(15.5, 15.5), radius: 10.5 * unit, startAngle: -40, endAngle: -330, clockwise: true)
    arc.lineWidth = 3.2 * unit
    arc.stroke()

    let dotOrigin = point(14, 9)
    NSBezierPath(ovalIn: NSRect(x: dotOrigin.x, y: dotOrigin.y, width: 7 * unit, height: 7 * unit)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try render(points * scale).write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
