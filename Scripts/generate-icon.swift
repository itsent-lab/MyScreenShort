import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon.png"
let outputURL = URL(fileURLWithPath: outputPath)
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.18, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 220, yRadius: 220).fill()

NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.95, alpha: 1).setStroke()
let framePath = NSBezierPath(roundedRect: NSRect(x: 220, y: 300, width: 584, height: 424), xRadius: 52, yRadius: 52)
framePath.lineWidth = 56
framePath.stroke()

NSColor.white.setFill()
let lensPath = NSBezierPath(ovalIn: NSRect(x: 414, y: 424, width: 196, height: 196))
lensPath.fill()

NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.95, alpha: 1).setFill()
let flashPath = NSBezierPath()
flashPath.move(to: NSPoint(x: 650, y: 698))
flashPath.line(to: NSPoint(x: 752, y: 698))
flashPath.line(to: NSPoint(x: 690, y: 820))
flashPath.close()
flashPath.fill()

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    exit(1)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try pngData.write(to: outputURL)
