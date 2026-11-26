import SwiftUI
import SafeNetCore

/// SafeNet's mark, "сетевая снежинка": six arms from a hub, each ending in a node. Read one way it
/// is a network graph, the other way a snowflake (what SafeNet does to apps on a wrong route).
/// The same geometry draws the app icon (scripts/make-icon.swift); keep both in step.
enum NetFlake {
    /// In a unit square, y down. Arms point up and every 60°.
    static let armLength: CGFloat = 0.34
    static let nodeRadius: CGFloat = 0.062
    static let hubRadius: CGFloat = 0.08
    static let barbAt: CGFloat = 0.5
    static let barbLength: CGFloat = 0.09
    static let lineWidth: CGFloat = 0.046
    /// Opacity of the mesh joining the nodes.
    static let meshOpacity: Double = 0.42

    /// `lines`: arms and barbs; `nodes`: rings at the arm tips (stroked); `mesh`: the hexagon
    /// joining the nodes (stroked thinner, translucent); `hub`: solid hexagon.
    static func arms(in r: CGRect) -> (lines: Path, nodes: Path, hub: Path, mesh: Path) {
        let s = min(r.width, r.height)
        let c = CGPoint(x: r.midX, y: r.midY)
        var lines = Path(), nodes = Path(), hub = Path(), mesh = Path()
        var tips: [CGPoint] = []
        for i in 0..<6 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 3
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
        // Hexagonal hub, flat sides left and right.
        let hr = hubRadius * s
        for i in 0..<6 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 3
            let p = CGPoint(x: c.x + cos(a) * hr, y: c.y + sin(a) * hr)
            if i == 0 { hub.move(to: p) } else { hub.addLine(to: p) }
        }
        hub.closeSubpath()
        return (lines, nodes, hub, mesh)
    }
}

/// The flake alone, for tinting (menu header glyph, panel title).
struct NetFlakeGlyph: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            let g = NetFlake.arms(in: r)
            let s = min(size.width, size.height)
            let w = NetFlake.lineWidth * s
            ctx.stroke(g.mesh, with: .color(color.opacity(NetFlake.meshOpacity)),
                       style: StrokeStyle(lineWidth: w * 0.55, lineCap: .round, lineJoin: .round))
            ctx.stroke(g.lines, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            ctx.stroke(g.nodes, with: .color(color), style: StrokeStyle(lineWidth: w))
            ctx.fill(g.hub, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// App tile: the icon in miniature (deep blue to ice, white flake) with an optional state badge
/// in the lower right corner, ringed in the window colour so it reads on any background.
struct AppMark: View {
    var size: CGFloat = 26
    var state: RGB?
    var ring: Color = .clear

    var body: some View {
        let radius = size * 0.27
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x3DA8FF), Color(hex: 0x1D4FC4), Color(hex: 0x0E1E5B)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(RadialGradient(colors: [Color(hex: 0x9FEAFF).opacity(0.55), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.42))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: max(0.5, size / 60))
            NetFlakeGlyph(color: .white)
                .padding(size * 0.08)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let s = state {
                Circle().fill(s.swiftUIColor)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .overlay(Circle().strokeBorder(ring, lineWidth: max(1.5, size * 0.07)))
                    .offset(x: size * 0.1, y: size * 0.1)
            }
        }
        .accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}
