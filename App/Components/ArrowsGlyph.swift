// ABOUTME: "Arrows" menu bar icon set: two circular sync arrows with a status badge in the lower right.
// ABOUTME: Syncing spins the arrows with a dashed trail; all paused closes them into a ring around a pause sign.

import SwiftUI
import HelixKit

struct ArrowsGlyph: View {
    let health: HealthStatus
    let frame: Int

    var body: some View {
        let dimmed = health == .idle || health == .daemonStopped
        ZStack {
            Ring.body(health, frame: frame).fill(MenuBarGlyph.ink).opacity(dimmed ? MenuBarGlyph.dimOpacity : 1)
            if health == .active {
                Ring.trail(frame: frame).fill(MenuBarGlyph.ink)
            }
            if let badge = Badge.shape(health) {
                badge.fill(.black).blendMode(.destinationOut)
                badge.stroke(.black, style: StrokeStyle(lineWidth: Badge.gap * 2, lineJoin: .round)).blendMode(.destinationOut)
                badge.fill(MenuBarGlyph.ink)
                if let symbol = Badge.symbol(health) {
                    symbol.fill(.black).blendMode(.destinationOut)
                }
            }
        }
        .compositingGroup()
    }
}

private enum Pause {
    static let bar = CGSize(width: 2, height: 7)
    static let gap: CGFloat = 2

    static func bars(x: CGFloat, y: CGFloat) -> Path {
        var p = Path()
        p.addRect(CGRect(origin: CGPoint(x: x, y: y), size: bar))
        p.addRect(CGRect(origin: CGPoint(x: x + bar.width + gap, y: y), size: bar))
        return p
    }
}

private enum Ring {
    static let center = CGPoint(x: 10, y: 9)
    static let radius: CGFloat = 7
    static let stroke: CGFloat = 2
    static let headHalf: CGFloat = 3
    static let headLength: CGFloat = 3.75
    static let tipAngle: Double = -12
    static let gap: CGFloat = 1.75
    static let trailDashes: [(from: CGFloat, to: CGFloat)] = [(0, 1.5), (3, 5), (6.5, 9)]
    static let trailBodyStart: CGFloat = 10.5

    static func degrees(_ length: CGFloat) -> Double { Double(length / radius) * 180 / .pi }

    static func point(_ r: CGFloat, _ deg: Double) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }

    static func band(_ from: Double, _ to: Double) -> Path {
        var p = Path()
        p.addArc(center: center, radius: radius + stroke / 2, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        p.addArc(center: center, radius: radius - stroke / 2, startAngle: .degrees(to), endAngle: .degrees(from), clockwise: true)
        p.closeSubpath()
        return p
    }

    static func arrow(tail: Double, tip: Double) -> Path {
        let base = tip - degrees(headLength)
        var p = Path()
        p.addArc(center: center, radius: radius + stroke / 2, startAngle: .degrees(tail), endAngle: .degrees(base), clockwise: false)
        p.addLine(to: point(radius + headHalf, base))
        p.addLine(to: point(radius, tip))
        p.addLine(to: point(radius - headHalf, base))
        p.addArc(center: center, radius: radius - stroke / 2, startAngle: .degrees(base), endAngle: .degrees(tail), clockwise: true)
        p.closeSubpath()
        return p
    }

    static func arrows(rotation: Double) -> [(tail: Double, tip: Double)] {
        [0.0, 180.0].map { offset in
            let tip = tipAngle + offset + rotation
            return (tip - 180 + degrees(gap), tip)
        }
    }

    /// The two arrows are identical after half a turn, so the animation cycle spans 180 degrees.
    static func rotation(_ health: HealthStatus, frame: Int) -> Double {
        health == .active ? Double(frame) * 180 / Double(MenuBarGlyph.frameCount) : 0
    }

    static func body(_ health: HealthStatus, frame: Int) -> Path {
        if health == .paused {
            var p = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                .strokedPath(StrokeStyle(lineWidth: stroke))
            p.addPath(Pause.bars(x: center.x - Pause.bar.width - Pause.gap / 2, y: center.y - Pause.bar.height / 2))
            return p
        }
        var p = Path()
        for a in arrows(rotation: rotation(health, frame: frame)) {
            let tail = health == .active ? a.tail + degrees(trailBodyStart) : a.tail
            p.addPath(arrow(tail: tail, tip: a.tip))
        }
        return p
    }

    static func trail(frame: Int) -> Path {
        var p = Path()
        for a in arrows(rotation: rotation(.active, frame: frame)) {
            for d in trailDashes {
                p.addPath(band(a.tail + degrees(d.from), a.tail + degrees(d.to)))
            }
        }
        return p
    }
}

private enum Badge {
    static let gap: CGFloat = 1.25
    static let center = CGPoint(x: 16.5, y: 13.5)
    static let discRadius: CGFloat = 4.5

    static func shape(_ health: HealthStatus) -> Path? {
        switch health {
        case .partiallyPaused:
            return Pause.bars(x: 15, y: 10)
        case .warning:
            return triangle
        case .error:
            return Path(ellipseIn: CGRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2))
        case .daemonStopped:
            var p = Path()
            p.move(to: CGPoint(x: 2.5, y: 1.5))
            p.addLine(to: CGPoint(x: 17.5, y: 16.5))
            return p.strokedPath(StrokeStyle(lineWidth: 2))
        case .healthy, .active, .paused, .idle:
            return nil
        }
    }

    static func symbol(_ health: HealthStatus) -> Path? {
        switch health {
        case .warning:
            var p = Path()
            p.addRect(CGRect(x: 15.5, y: 12, width: 1.5, height: 2.5))
            p.addRect(CGRect(x: 15.5, y: 15.5, width: 1.5, height: 1.5))
            return p
        case .error:
            let arm: CGFloat = 1.875
            var p = Path()
            p.move(to: CGPoint(x: center.x - arm, y: center.y - arm))
            p.addLine(to: CGPoint(x: center.x + arm, y: center.y + arm))
            p.move(to: CGPoint(x: center.x + arm, y: center.y - arm))
            p.addLine(to: CGPoint(x: center.x - arm, y: center.y + arm))
            return p.strokedPath(StrokeStyle(lineWidth: 1.75))
        default:
            return nil
        }
    }

    static var triangle: Path {
        let apex = CGPoint(x: 16.25, y: 8)
        let left = CGPoint(x: 11.25, y: 18)
        let right = CGPoint(x: 21.25, y: 18)
        var p = Path()
        p.move(to: CGPoint(x: apex.x, y: left.y))
        p.addArc(tangent1End: right, tangent2End: apex, radius: 0.75)
        p.addArc(tangent1End: apex, tangent2End: left, radius: 0.75)
        p.addArc(tangent1End: left, tangent2End: right, radius: 0.75)
        p.closeSubpath()
        return p
    }
}
