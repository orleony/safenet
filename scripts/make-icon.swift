// Draws the SafeNet app icon with CoreGraphics (no external assets, no network) and writes a
// complete .iconset (16…1024 px). Usage: make-icon <out.iconset> [preview.png]
// Design: macOS-style rounded square, dark navy gradient, a blue shield with a white check mark
// and a small six-armed "frozen" spark cut out of the shield's upper right shoulder.
import AppKit
import CoreGraphics

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Shield outline in the 1024-unit design space (y up).
func shieldPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512, y: 812))
    p.addCurve(to: CGPoint(x: 722, y: 742), control1: CGPoint(x: 590, y: 772), control2: CGPoint(x: 660, y: 750))
    p.addLine(to: CGPoint(x: 722, y: 560))
    p.addCurve(to: CGPoint(x: 512, y: 212), control1: CGPoint(x: 722, y: 392), control2: CGPoint(x: 628, y: 276))
    p.addCurve(to: CGPoint(x: 302, y: 560), control1: CGPoint(x: 396, y: 276), control2: CGPoint(x: 302, y: 392))
    p.addLine(to: CGPoint(x: 302, y: 742))
    p.addCurve(to: CGPoint(x: 512, y: 812), control1: CGPoint(x: 364, y: 750), control2: CGPoint(x: 434, y: 772))
    p.closeSubpath()
    return p
}

func draw(_ ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Rounded square (Big Sur grid: 824 px body, 100 px margin) with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let corner: CGFloat = 186
    let bodyPath = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x1a1c25)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x2a2e40), rgb(0x242736), rgb(0x1a1c25)] as CFArray,
                        locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Faint blue glow behind the shield.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0x4c9aff, 0.22), rgb(0x4c9aff, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 520), endRadius: 420, options: [])
    ctx.restoreGState()

    // Hairline highlight on the body edge.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: corner - 2, cornerHeight: corner - 2,
                       transform: nil))
    ctx.setStrokeColor(rgb(0xffffff, 0.08)); ctx.setLineWidth(4); ctx.strokePath()
    ctx.restoreGState()

    // Shield: blue gradient, with a darker rim.
    let shield = shieldPath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.45))
    ctx.addPath(shield); ctx.setFillColor(rgb(0x4c9aff)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shield); ctx.clip()
    let blue = CGGradient(colorsSpace: space, colors: [rgb(0x7ab4ff), rgb(0x4c9aff), rgb(0x2f74e0)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(blue, start: CGPoint(x: 400, y: 812), end: CGPoint(x: 620, y: 212), options: [])
    // Left half slightly lighter: a simple bevel.
    ctx.clip(to: CGRect(x: 0, y: 0, width: 512, height: 1024))
    ctx.setFillColor(rgb(0xffffff, 0.07)); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 1024))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shield); ctx.setStrokeColor(rgb(0x1f5bc0, 0.9)); ctx.setLineWidth(10); ctx.strokePath()
    ctx.restoreGState()

    // Check mark.
    ctx.saveGState()
    let check = CGMutablePath()
    check.move(to: CGPoint(x: 405, y: 528))
    check.addLine(to: CGPoint(x: 486, y: 446))
    check.addLine(to: CGPoint(x: 632, y: 618))
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: rgb(0x0b2a66, 0.45))
    ctx.addPath(check)
    ctx.setStrokeColor(rgb(0xffffff)); ctx.setLineWidth(62); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // "Frozen" spark: a six-armed snowflake on a navy disc over the shield's upper right corner.
    let c = CGPoint(x: 724, y: 742)
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 112, y: c.y - 112, width: 224, height: 224))
    ctx.setFillColor(rgb(0x1e2130)); ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: c.x - 112, y: c.y - 112, width: 224, height: 224))
    ctx.setStrokeColor(rgb(0x4c9aff, 0.55)); ctx.setLineWidth(6); ctx.strokePath()
    let flake = CGMutablePath()
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3 + .pi / 2
        let dir = CGPoint(x: cos(a), y: sin(a))
        let tip = CGPoint(x: c.x + dir.x * 74, y: c.y + dir.y * 74)
        flake.move(to: c); flake.addLine(to: tip)
        // Two small barbs per arm.
        let mid = CGPoint(x: c.x + dir.x * 44, y: c.y + dir.y * 44)
        for side in [-1.0, 1.0] as [CGFloat] {
            let b = a + side * .pi / 4
            flake.move(to: mid)
            flake.addLine(to: CGPoint(x: mid.x + cos(b) * 26, y: mid.y + sin(b) * 26))
        }
    }
    ctx.addPath(flake)
    ctx.setStrokeColor(rgb(0xcfe3ff)); ctx.setLineWidth(15); ctx.setLineCap(.round); ctx.strokePath()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    let ctx = g.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setShouldAntialias(true); ctx.interpolationQuality = .high
    draw(ctx, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <out.iconset> [preview.png]\n".utf8)); exit(2)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if args.count >= 3 { try png(size: 1024).write(to: URL(fileURLWithPath: args[2])) }
print("iconset written: \(out.path)")
