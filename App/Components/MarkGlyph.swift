// ABOUTME: "H Mark" menu bar icon set: an outlined plate with an H whose crossbar bends like a helix step.
// ABOUTME: A corner badge shows the state; all paused swaps the H for a pause sign, a stopped daemon slashes the plate.

import SwiftUI
import HelixKit

struct MarkGlyph: View {
    let health: HealthStatus
    let frame: Int

    var body: some View {
        let ink = MenuBarGlyph.ink
        ZStack {
            switch health {
            case .paused:
                Geo.outline.fill(ink)
                Geo.bigPause.fill(ink)
            case .daemonStopped:
                ZStack {
                    Geo.outline.fill(ink)
                    Geo.letter.fill(ink)
                    Geo.slash.strokedPath(Geo.round(Geo.stroke + 2 * Geo.gap)).fill(.black).blendMode(.destinationOut)
                }
                .compositingGroup()
                .opacity(MenuBarGlyph.dimOpacity)
                Geo.slash.strokedPath(Geo.round(Geo.stroke)).fill(ink)
            default:
                Geo.outline.fill(ink)
                Geo.letter.fill(ink)
                if let badge {
                    Geo.grown(badge.silhouette, by: Geo.gap).fill(.black).blendMode(.destinationOut)
                    badge.ink.fill(ink)
                    badge.symbol.fill(.black).blendMode(.destinationOut)
                }
            }
        }
        .compositingGroup()
        .opacity(health == .idle ? MenuBarGlyph.dimOpacity : 1)
    }

    private var badge: (silhouette: Path, ink: Path, symbol: Path)? {
        switch health {
        case .active: (Geo.disc, Geo.syncArrow(frame), Path())
        case .partiallyPaused: (Geo.pauseBlock, Geo.pauseBars, Path())
        case .warning: (Geo.triangle, Geo.triangle, Geo.exclamation)
        case .error: (Geo.disc, Geo.disc, Geo.cross)
        case .healthy, .paused, .daemonStopped, .idle: nil
        }
    }
}

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
}

private enum Geo {
    static let plate = CGRect(x: 1.5, y: 1, width: 16, height: 16)
    static let stroke: CGFloat = 2
    static let gap: CGFloat = 1.25
    static let badge = CGPoint(x: 16.5, y: 13.5)
    static let badgeRadius: CGFloat = 4.5

    static func round(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    static func segment(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        return p
    }

    static func grown(_ shape: Path, by amount: CGFloat) -> Path {
        shape.union(shape.strokedPath(round(2 * amount)))
    }

    static let outline = Path(roundedRect: plate.insetBy(dx: stroke / 2, dy: stroke / 2), cornerRadius: 3.5, style: .continuous)
        .strokedPath(StrokeStyle(lineWidth: stroke))

    static let letter: Path = {
        let left = plate.midX - 3, right = plate.midX + 3
        var p = segment(CGPoint(x: left, y: 5.5), CGPoint(x: left, y: 12.5))
        p.addPath(segment(CGPoint(x: right, y: 5.5), CGPoint(x: right, y: 12.5)))
        p.move(to: CGPoint(x: left, y: 9.75))
        p.addCurve(
            to: CGPoint(x: right, y: 8.25),
            control1: CGPoint(x: plate.midX, y: 9.75),
            control2: CGPoint(x: plate.midX, y: 8.25)
        )
        return p.strokedPath(round(stroke))
    }()

    static let bigPause: Path = {
        var p = Path()
        for x: CGFloat in [6, 10.5] {
            p.addRoundedRect(in: CGRect(x: x, y: 5.5, width: 2.5, height: 7), cornerSize: CGSize(width: 1, height: 1))
        }
        return p
    }()

    static let slash = segment(CGPoint(x: 3, y: 2.5), CGPoint(x: 16, y: 15.5))

    static let disc = circle(badge, badgeRadius)

    static let cross: Path = {
        let d: CGFloat = 1.75
        return segment(badge + CGPoint(x: -d, y: -d), badge + CGPoint(x: d, y: d)).strokedPath(round(1.5))
            .union(segment(badge + CGPoint(x: d, y: -d), badge + CGPoint(x: -d, y: d)).strokedPath(round(1.5)))
    }()

    static let triangleCenter: CGFloat = 16.25

    static let triangle: Path = {
        let cx = triangleCenter
        var p = Path()
        p.addLines([CGPoint(x: cx, y: 10), CGPoint(x: cx + 4, y: 17.25), CGPoint(x: cx - 4, y: 17.25)])
        p.closeSubpath()
        return grown(p, by: 0.75)
    }()

    static let exclamation: Path = {
        let cx = triangleCenter
        return Path(roundedRect: CGRect(x: cx - 0.75, y: 12, width: 1.5, height: 2.5), cornerRadius: 0.75)
            .union(circle(CGPoint(x: cx, y: 16.25), 0.75))
    }()

    static let pauseBars: Path = {
        var p = Path()
        for x: CGFloat in [13.5, 17.5] {
            p.addRoundedRect(in: CGRect(x: x, y: 11, width: 2, height: 6), cornerSize: CGSize(width: 0.75, height: 0.75))
        }
        return p
    }()

    static let pauseBlock = Path(CGRect(x: 13.5, y: 11, width: 6, height: 6))

    static func syncArrow(_ frame: Int) -> Path {
        let r: CGFloat = 2.6
        let end = Double(frame) * 2 * .pi / Double(MenuBarGlyph.frameCount) - .pi / 2
        let sweep = 1.45 * Double.pi
        var arc = Path()
        arc.addLines((0...48).map { i in
            let a = end - sweep * (1 - Double(i) / 48)
            return badge + CGPoint(x: cos(a), y: sin(a)) * r
        })
        let radial = CGPoint(x: cos(end), y: sin(end))
        let tangent = CGPoint(x: -sin(end), y: cos(end))
        let base = badge + radial * r
        var head = Path()
        head.addLines([base + radial * 1.55, base + tangent * 2.1, base + radial * -1.55])
        head.closeSubpath()
        return arc.strokedPath(round(1.75)).union(grown(head, by: 0.3))
    }
}
