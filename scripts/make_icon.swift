import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func render(_ size: Int, _ name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 38, y: 38, width: 948, height: 948), xRadius: 210, yRadius: 210)
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); tile.fill()
    NSColor(calibratedWhite: 0.25, alpha: 1).setStroke(); tile.lineWidth = 9; tile.stroke()
    // A clear top-view mouse silhouette, legible down to 16px.
    let mouse = NSBezierPath(roundedRect: NSRect(x: 284, y: 174, width: 456, height: 676), xRadius: 218, yRadius: 218)
    NSColor(calibratedWhite: 0.91, alpha: 1).setFill(); mouse.fill()
    let seam = NSBezierPath(); seam.move(to: NSPoint(x: 512, y: 850)); seam.line(to: NSPoint(x: 512, y: 556)); seam.lineWidth = 19
    NSColor(calibratedWhite: 0.12, alpha: 1).setStroke(); seam.stroke()
    let buttons = NSBezierPath(); buttons.move(to: NSPoint(x: 290, y: 556)); buttons.line(to: NSPoint(x: 734, y: 556)); buttons.lineWidth = 19; buttons.stroke()
    let wheel = NSBezierPath(roundedRect: NSRect(x: 470, y: 633, width: 84, height: 128), xRadius: 40, yRadius: 40)
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); wheel.fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try render(size, "icon_\(size)x\(size).png")
    try render(size * 2, "icon_\(size)x\(size)@2x.png")
}
