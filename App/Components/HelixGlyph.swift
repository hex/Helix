// ABOUTME: "Helix" menu bar icon set: the app icon's two arrows twisted into a double helix.
// ABOUTME: A knocked-out badge in the lower right shows syncing, pause, warning or error; a stopped daemon slashes the helix.

import SwiftUI
import HelixKit

struct HelixGlyph: View {
    let health: HealthStatus
    let frame: Int

    var body: some View {
        let dimmed = health == .idle || health == .paused || health == .daemonStopped
        ZStack {
            HelixShape(fill: MenuBarGlyph.ink.opacity(dimmed ? MenuBarGlyph.dimOpacity : 1), heads: health != .paused)
            if let mark = StatusMark(health: health, frame: frame) {
                mark.knockout.fill(.black).blendMode(.destinationOut)
                ZStack {
                    mark.shape.fill(MenuBarGlyph.ink)
                    mark.inner?.fill(.black).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
        }
        .compositingGroup()
    }
}

private struct StatusMark {
    let shape: Path
    let knockout: Path
    var inner: Path?

    private static let margin: CGFloat = 1.25
    private static let center = CGPoint(x: 17, y: 14)
    private static let radius: CGFloat = 4
    private static let symbolWidth: CGFloat = 1.75

    init?(health: HealthStatus, frame: Int) {
        let c = Self.center
        switch health {
        case .idle, .healthy:
            return nil
        case .active:
            shape = Self.clockwiseArrow(c, end: .degrees(Double(frame) * 360 / Double(MenuBarGlyph.frameCount) - 90))
            knockout = Self.disc(c, Self.radius + Self.margin)
        case .partiallyPaused, .paused:
            let bar = CGRect(x: 15, y: 11, width: 2, height: 7)
            var bars = Path()
            bars.addRoundedRect(in: bar, cornerSize: CGSize(width: 0.5, height: 0.5))
            bars.addRoundedRect(in: bar.offsetBy(dx: 4, dy: 0), cornerSize: CGSize(width: 0.5, height: 0.5))
            shape = bars
            let pair = bar.union(bar.offsetBy(dx: 4, dy: 0))
            knockout = Path(roundedRect: pair.insetBy(dx: -Self.margin, dy: -Self.margin), cornerRadius: 1.5)
        case .warning:
            let x: CGFloat = 16.25
            var triangle = Path()
            triangle.move(to: CGPoint(x: x, y: 9.5))
            triangle.addLine(to: CGPoint(x: x + 4.25, y: 17.5))
            triangle.addLine(to: CGPoint(x: x - 4.25, y: 17.5))
            triangle.closeSubpath()
            let rounded = triangle.union(triangle.strokedPath(StrokeStyle(lineWidth: 1, lineJoin: .round)))
            shape = rounded
            knockout = Self.expanded(rounded)
            var bang = Path()
            bang.addRoundedRect(in: CGRect(x: x - 0.75, y: 12, width: 1.5, height: 2.5), cornerSize: CGSize(width: 0.75, height: 0.75))
            bang.addEllipse(in: CGRect(x: x - 0.75, y: 15.5, width: 1.5, height: 1.5))
            inner = bang
        case .error:
            let disc = Self.disc(c, Self.radius)
            shape = disc
            knockout = Self.expanded(disc)
            let d: CGFloat = 1.4
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - d, y: c.y - d))
            cross.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
            cross.move(to: CGPoint(x: c.x + d, y: c.y - d))
            cross.addLine(to: CGPoint(x: c.x - d, y: c.y + d))
            inner = cross.strokedPath(StrokeStyle(lineWidth: Self.symbolWidth, lineCap: .round))
        case .daemonStopped:
            var slash = Path()
            slash.move(to: CGPoint(x: HelixStrands.center.x - 5.5, y: 1.5))
            slash.addLine(to: CGPoint(x: HelixStrands.center.x + 5.5, y: 16.5))
            shape = slash.strokedPath(StrokeStyle(lineWidth: HelixStrands.lineWidth, lineCap: .round))
            knockout = slash.strokedPath(StrokeStyle(lineWidth: HelixStrands.lineWidth + 2, lineCap: .round))
        }
    }

    /// A 270-degree arc running clockwise up to `end`, where an arrowhead points along it.
    private static func clockwiseArrow(_ c: CGPoint, end: Angle) -> Path {
        let r: CGFloat = 2.375
        var arc = Path()
        arc.addArc(center: c, radius: r, startAngle: end - .degrees(270), endAngle: end, clockwise: false)
        let stroke = arc.strokedPath(StrokeStyle(lineWidth: symbolWidth, lineCap: .round))
        let a = CGFloat(end.radians)
        let normal = CGPoint(x: cos(a), y: sin(a))
        let tangent = CGPoint(x: -sin(a), y: cos(a))
        let base = CGPoint(x: c.x + r * normal.x, y: c.y + r * normal.y)
        let halfWidth: CGFloat = 1.5
        let length: CGFloat = 3
        var head = Path()
        head.move(to: CGPoint(x: base.x + length * tangent.x, y: base.y + length * tangent.y))
        head.addLine(to: CGPoint(x: base.x + halfWidth * normal.x, y: base.y + halfWidth * normal.y))
        head.addLine(to: CGPoint(x: base.x - halfWidth * normal.x, y: base.y - halfWidth * normal.y))
        head.closeSubpath()
        let roundedHead = head.union(head.strokedPath(StrokeStyle(lineWidth: 0.25, lineJoin: .round)))
        return stroke.union(roundedHead)
    }

    private static func disc(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    private static func expanded(_ path: Path) -> Path {
        path.union(path.strokedPath(StrokeStyle(lineWidth: 2 * margin, lineCap: .round, lineJoin: .round)))
    }
}

/// Two arrows twisted around a vertical axis. Strand B is strand A turned 180 degrees about `center`.
private enum HelixStrands {
    static let center = CGPoint(x: 9.75, y: 9)
    static let lineWidth: CGFloat = 2

    private static let amplitude: CGFloat = 3.25
    private static let period: CGFloat = 11.5
    private static let shaftLength: CGFloat = 0.75
    private static let crossingGap: CGFloat = 1.5
    private static let headLength: CGFloat = 4.25
    private static let headWidth: CGFloat = 6
    private static let stubLength: CGFloat = 2.75
    private static let tuckedPhase: CGFloat = .pi / 2 + 0.3
    private static let headPhase = -.pi + asin(period / (2 * .pi * amplitude))
    private static let headDirection = CGPoint(x: sqrt(0.5), y: -sqrt(0.5))
    private static let turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 2 * center.x, ty: 2 * center.y)

    /// Strand A at phase `t`: its left extreme at t = 0, crossings at t = ±π/2, the head end above.
    private static func pointA(_ t: CGFloat) -> CGPoint {
        CGPoint(x: center.x - amplitude * cos(t), y: center.y + t / (2 * .pi) * period)
    }

    private static func curveA(from t0: CGFloat, to t1: CGFloat) -> Path {
        var path = Path()
        let steps = 64
        for i in 0...steps {
            let p = pointA(t0 + (t1 - t0) * CGFloat(i) / CGFloat(steps))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private static func offset(_ p: CGPoint, by d: CGFloat, along v: CGPoint) -> CGPoint {
        CGPoint(x: p.x + v.x * d, y: p.y + v.y * d)
    }

    private static var shaftEnd: CGPoint { offset(pointA(headPhase), by: shaftLength, along: headDirection) }

    private static var arrowheadA: Path {
        let base = shaftEnd
        let side = CGPoint(x: -headDirection.y, y: headDirection.x)
        var head = Path()
        head.move(to: offset(base, by: headLength, along: headDirection))
        head.addLine(to: offset(base, by: headWidth / 2, along: side))
        head.addLine(to: offset(base, by: -headWidth / 2, along: side))
        head.closeSubpath()
        return head.union(head.strokedPath(StrokeStyle(lineWidth: 0.5, lineJoin: .round)))
    }

    /// Strand A from under strand B at the lower crossing up to its arrowhead, or to a round end without `head`.
    static func strandA(head: Bool) -> Path {
        var line = curveA(from: tuckedPhase, to: headPhase)
        line.addLine(to: offset(shaftEnd, by: head ? 0.8 : stubLength, along: headDirection))
        let stroke = line.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        return head ? stroke.union(arrowheadA) : stroke
    }

    static func strandB(head: Bool) -> Path { strandA(head: head).applying(turn) }

    /// Strand A around the upper crossing, widened by the gap it leaves in strand B.
    static var overpassOnB: Path {
        curveA(from: -.pi / 2 - 1, to: -.pi / 2 + 1)
            .strokedPath(StrokeStyle(lineWidth: lineWidth + 2 * crossingGap, lineCap: .butt))
    }

    static var overpassOnA: Path { overpassOnB.applying(turn) }
}

private struct HelixShape: View {
    let fill: Color
    var heads = true

    var body: some View {
        ZStack {
            strand(HelixStrands.strandA(head: heads), cut: HelixStrands.overpassOnA)
            strand(HelixStrands.strandB(head: heads), cut: HelixStrands.overpassOnB)
        }
    }

    private func strand(_ path: Path, cut: Path) -> some View {
        ZStack {
            path.fill(fill)
            cut.fill(.black).blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}
