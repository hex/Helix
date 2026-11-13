// ABOUTME: Menu bar icon that reflects overall session health in the icon set chosen in Settings.
// ABOUTME: Legacy draws colored SF Symbols; Arrows, Helix and H Mark are monochrome template images.

import AppKit
import SwiftUI
import HelixKit

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case legacy
    case arrows
    case helix
    case mark

    static let storageKey = "menuBarIconStyle"
    static let defaultStyle = MenuBarIconStyle.helix

    var id: Self { self }

    var title: String {
        switch self {
        case .legacy: "Legacy"
        case .arrows: "Arrows"
        case .helix: "Helix"
        case .mark: "H Mark"
        }
    }
}

struct MenuBarIcon: View {
    static let showsPauseKey = "menuBarShowsPause"

    let health: HealthStatus
    @AppStorage(MenuBarIconStyle.storageKey) private var style = MenuBarIconStyle.defaultStyle
    @AppStorage(showsPauseKey) private var showsPause = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = 0

    var body: some View {
        MenuBarIconImage(style: style, health: shownHealth, frame: frame)
            .task(id: animates) {
                frame = 0
                guard animates else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: MenuBarGlyph.frameDuration)
                    if Task.isCancelled { return }
                    frame = (frame + 1) % MenuBarGlyph.frameCount
                }
            }
    }

    private var shownHealth: HealthStatus {
        showsPause ? health : health.ignoringPause
    }

    private var animates: Bool {
        style != .legacy && shownHealth == .active && !reduceMotion
    }
}

/// One frame of the menu bar icon in a given style.
struct MenuBarIconImage: View {
    let style: MenuBarIconStyle
    let health: HealthStatus
    var frame = 0

    var body: some View {
        if let image = MenuBarGlyph.image(style, health: health, frame: frame) {
            Image(nsImage: image)
                .renderingMode(.template)
                .accessibilityLabel("Helix")
        } else {
            Image(systemName: legacySymbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(legacyColor)
        }
    }

    private var legacySymbol: String {
        switch health {
        case .healthy, .active, .partiallyPaused, .paused, .idle: "arrow.triangle.2.circlepath"
        case .warning: "exclamationmark.arrow.triangle.2.circlepath"
        case .error, .daemonStopped: "xmark.circle"
        }
    }

    private var legacyColor: Color {
        switch health {
        case .healthy, .partiallyPaused: .green
        case .active: .blue
        case .warning: .orange
        case .error, .daemonStopped: .red
        case .paused, .idle: .secondary
        }
    }
}

/// Renders the monochrome icon sets into cached template images.
enum MenuBarGlyph {
    static let size = CGSize(width: 21, height: 18)
    static let frameCount = 8
    static let frameDuration = Duration.milliseconds(125)
    static let ink = Color.black
    static let dimOpacity = 0.45

    private struct Key: Hashable {
        let style: MenuBarIconStyle
        let health: HealthStatus
        let frame: Int
    }

    @MainActor private static var cache: [Key: NSImage] = [:]

    /// The template image for `style`, or nil for the legacy style, which has no glyphs.
    @MainActor
    static func image(_ style: MenuBarIconStyle, health: HealthStatus, frame: Int) -> NSImage? {
        let key = Key(style: style, health: health, frame: health == .active ? frame % frameCount : 0)
        if let cached = cache[key] { return cached }
        guard let glyph = glyph(key) else { return nil }

        let image = NSImage(size: size)
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: glyph.frame(width: size.width, height: size.height))
            renderer.scale = scale
            guard let cgImage = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private static func glyph(_ key: Key) -> AnyView? {
        switch key.style {
        case .legacy: nil
        case .arrows: AnyView(ArrowsGlyph(health: key.health, frame: key.frame))
        case .helix: AnyView(HelixGlyph(health: key.health, frame: key.frame))
        case .mark: AnyView(MarkGlyph(health: key.health, frame: key.frame))
        }
    }
}
