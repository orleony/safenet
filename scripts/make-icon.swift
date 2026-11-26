// Draws the SafeNet app icon with CoreGraphics (no external assets, no network) and writes a
// complete .iconset (16…1024 px). Usage: make-icon <out.iconset> [preview.png]
// Design, "сетевая снежинка": macOS rounded square in deep blue lit with ice from the upper left,
// and a white six-armed flake whose arms end in network nodes around a hexagonal hub. The same
// geometry is drawn in the app (Sources/SafeNetUI/AppMark.swift, `NetFlake`); keep both in step.
import AppKit
import CoreGraphics

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// NetFlake geometry (fractions of the flake's square), as in AppMark.swift.
let armLength: CGFloat = 0.34, nodeRadius: CGFloat = 0.062, hubRadius: CGFloat = 0.08
let barbAt: CGFloat = 0.5, barbLength: CGFloat = 0.09, lineWidth: CGFloat = 0.046, meshOpacity: CGFloat = 0.42

/// Lines, nodes and hub of the flake inside `r` (y up: the first arm points up).
func flake(in r: CGRect) -> (lines: CGPath, nodes: CGPath, hub: CGPath, mesh: CGPath) {
    let s = min(r.width, r.height), c = CGPoint(x: r.midX, y: r.midY)
    let lines = CGMutablePath(), nodes = CGMutablePath(), hub = CGMutablePath(), mesh = CGMutablePath()
    var tips: [CGPoint] = []
    for i in 0..<6 {
        let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 3
        let d = CGPoint(x: cos(a), y: sin(a))
        let tip = CGPoint(x: c.x + d.x * armLength * s, y: c.y + d.y * armLength * s)
        let nr = nodeRadius * s
        lines.move(to: CGPoint(x: c.x + d.x * hubRadius * s, y: c.y + d.y * hubRadius * s))
        lines.addLine(to: CGPoint(x: tip.x - d.x * nr, y: tip.y - d.y * nr))
        tips.append(tip)
        let mid = CGPoint(x: c.x + d.x * armLength * barbAt * s, y: c.y + d.y * armLength * barbAt * s)
        for side in [-1.0, 1.0] as [CGFloat] {
            let b = a + side * .pi / 4.2
            lines.move(to: mid)
            lines.addLine(to: CGPoint(x: mid.x + cos(b) * barbLength * s, y: mid.y + sin(b) * barbLength * s))
        }
        nodes.addEllipse(in: CGRect(x: tip.x - nr, y: tip.y - nr, width: nr * 2, height: nr * 2))
    }
    // Mesh edges between neighbouring nodes, stopping at the rings.
    let nr = nodeRadius * s
    for i in 0..<6 {
        let p = tips[i], q = tips[(i + 1) % 6]
        let len = hypot(q.x - p.x, q.y - p.y), u = CGPoint(x: (q.x - p.x) / len, y: (q.y - p.y) / len)
        mesh.move(to: CGPoint(x: p.x + u.x * nr, y: p.y + u.y * nr))
        mesh.addLine(to: CGPoint(x: q.x - u.x * nr, y: q.y - u.y * nr))
    }
    let hr = hubRadius * s
    for i in 0..<6 {
        let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 3
        let p = CGPoint(x: c.x + cos(a) * hr, y: c.y + sin(a) * hr)
        if i == 0 { hub.move(to: p) } else { hub.addLine(to: p) }
    }
    hub.closeSubpath()
    return (lines, nodes, hub, mesh)
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
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.38))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x0e1e5b)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    // Deep blue body, lit with ice from the upper left.
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x3da8ff), rgb(0x1d4fc4), rgb(0x0e1e5b)] as CFArray,
                        locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // Frost glow behind the flake.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0x9feaff, 0.55), rgb(0x9feaff, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 346, options: [])
    // Glass sheen on the upper half.
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xffffff, 0.16), rgb(0xffffff, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Hairline highlight on the body edge.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: corner - 3, cornerHeight: corner - 3,
                       transform: nil))
    ctx.setStrokeColor(rgb(0xffffff, 0.2)); ctx.setLineWidth(5); ctx.strokePath()
    ctx.restoreGState()

    // The flake, white, with a soft deep-blue shadow so it lifts off the glow.
    let fr = body.insetBy(dx: 824 * 0.08, dy: 824 * 0.08)
    let f = flake(in: fr)
    let side = min(fr.width, fr.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x0a1a52, 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let w = lineWidth * side
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.addPath(f.mesh); ctx.setStrokeColor(rgb(0xffffff, meshOpacity)); ctx.setLineWidth(w * 0.55); ctx.strokePath()
    ctx.addPath(f.lines); ctx.setStrokeColor(rgb(0xffffff)); ctx.setLineWidth(w); ctx.strokePath()
    ctx.addPath(f.nodes); ctx.setStrokeColor(rgb(0xffffff)); ctx.setLineWidth(w); ctx.strokePath()
    ctx.addPath(f.hub); ctx.setFillColor(rgb(0xffffff)); ctx.fillPath()
    ctx.endTransparencyLayer()
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
