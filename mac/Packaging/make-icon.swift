// Draws the app icon — a 4×4 keypad with a lit path through it — at every
// size an .iconset needs. Run by build-app.sh:
//
//   swift make-icon.swift <output.iconset>

import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func colour(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Which keys are lit, row by row from the top: a path descending the keypad,
// with the next row's options glowing dimly — the app in one picture.
let lit: [[Int?]] = [
    [0x0060FF, nil, nil, nil],
    [nil, 0x0060FF, nil, nil],
    [0x3080FF, 0x3080FF, 0x0060FF, 0x3080FF],
    [nil, nil, nil, nil],
]
let dimmed: [[Bool]] = [
    [false, false, false, false],
    [false, false, false, false],
    [true, true, false, true],
    [false, false, false, false],
]

func draw(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // The macOS icon grid: a rounded square inset from the canvas edge.
    let inset = size * 0.1
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.225

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.set()
    let base = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(starting: colour(0x2C2C30), ending: colour(0x121214))!.draw(in: base, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Sixteen keys.
    let padding = body.width * 0.13
    let gap = body.width * 0.045
    let key = (body.width - padding * 2 - gap * 3) / 4
    for row in 0..<4 {
        for column in 0..<4 {
            let rect = NSRect(x: body.minX + padding + CGFloat(column) * (key + gap),
                              y: body.maxY - padding - key - CGFloat(row) * (key + gap),
                              width: key, height: key)
            let cap = NSBezierPath(roundedRect: rect, xRadius: key * 0.2, yRadius: key * 0.2)
            if let hex = lit[row][column] {
                let strength: CGFloat = dimmed[row][column] ? 0.45 : 1
                if !dimmed[row][column] {
                    NSGraphicsContext.current?.saveGraphicsState()
                    let glow = NSShadow()
                    glow.shadowColor = colour(hex, alpha: 0.9)
                    glow.shadowBlurRadius = key * 0.35
                    glow.set()
                    colour(hex).setFill()
                    cap.fill()
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
                colour(hex, alpha: strength).setFill()
                cap.fill()
            } else {
                colour(0x3A3A3E).setFill()
                cap.fill()
            }
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent(name))
    }
}
print("wrote \(output.path)")
