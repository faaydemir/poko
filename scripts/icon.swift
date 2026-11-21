import AppKit

let output = CommandLine.arguments[1]
let size: CGFloat = 1024
// Render at exactly 1024x1024 pixels (lockFocus would double it on Retina hosts).
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
// Apple's macOS icon grid: the squircle fills 824 of 1024 px, leaving room for the system shadow.
let grid = NSAffineTransform()
grid.translateX(by: size / 2, yBy: size / 2); grid.scaleX(by: 824.0 / 960.0, yBy: 824.0 / 960.0); grid.translateX(by: -size / 2, yBy: -size / 2)
grid.concat()

// Flat white-like background squircle
let bgRect = NSRect(x: 32, y: 32, width: 960, height: 960)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 220, yRadius: 220)
NSColor(calibratedRed: 0.985, green: 0.988, blue: 0.992, alpha: 1.0).setFill()
bgPath.fill()
NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.91, alpha: 1.0).setStroke()
bgPath.lineWidth = 14
bgPath.stroke()

let xL: CGFloat = 260
let xR: CGFloat = 764
let y1: CGFloat = 744 // Top row (AppKit origin at bottom-left)
let y2: CGFloat = 512 // Middle row
let y3: CGFloat = 280 // Bottom row

let orange = NSColor(calibratedRed: 0.94, green: 0.38, blue: 0.07, alpha: 1.0)
let darkGreen = NSColor(calibratedRed: 0.08, green: 0.44, blue: 0.22, alpha: 1.0)
let darkBlue = NSColor(calibratedRed: 0.11, green: 0.32, blue: 0.78, alpha: 1.0)
let gray = NSColor(calibratedRed: 0.58, green: 0.64, blue: 0.72, alpha: 1.0)

let dotR: CGFloat = 92
let lineDotR: CGFloat = 24

func drawDottedConnection(from: NSPoint, to: NSPoint, color: NSColor, count: Int) {
    let dx = to.x - from.x
    let dy = to.y - from.y
    let dist = sqrt(dx * dx + dy * dy)
    let ux = dx / dist
    let uy = dy / dist

    let startDist = dotR + 36
    let endDist = dist - dotR - 36
    let span = endDist - startDist

    color.setFill()
    for i in 0..<count {
        let t = startDist + (span * CGFloat(i) / CGFloat(count - 1))
        let cx = from.x + ux * t
        let cy = from.y + uy * t
        let rect = NSRect(x: cx - lineDotR, y: cy - lineDotR, width: lineDotR * 2, height: lineDotR * 2)
        NSBezierPath(ovalIn: rect).fill()
    }
}

// Line 1: Straight (L1 -> R1, orange)
drawDottedConnection(from: NSPoint(x: xL, y: y1), to: NSPoint(x: xR, y: y1), color: orange, count: 5)
// Line 2: Cross (L2 -> R3, dark green)
drawDottedConnection(from: NSPoint(x: xL, y: y2), to: NSPoint(x: xR, y: y3), color: darkGreen, count: 5)
// Line 3: Cross (L3 -> R2, dark blue)
drawDottedConnection(from: NSPoint(x: xL, y: y3), to: NSPoint(x: xR, y: y2), color: darkBlue, count: 5)

func drawDot(at center: NSPoint, color: NSColor) {
    let rect = NSRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

// Left column dots (colored)
drawDot(at: NSPoint(x: xL, y: y1), color: orange)
drawDot(at: NSPoint(x: xL, y: y2), color: darkGreen)
drawDot(at: NSPoint(x: xL, y: y3), color: darkBlue)

// Right column dots (gray)
drawDot(at: NSPoint(x: xR, y: y1), color: gray)
drawDot(at: NSPoint(x: xR, y: y2), color: gray)
drawDot(at: NSPoint(x: xR, y: y3), color: gray)

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
