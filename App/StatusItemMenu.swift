// ABOUTME: Menu shown on right-clicking the menu bar icon: open Helix, pause or resume all syncs, quit.
// ABOUTME: Watches right clicks and double clicks on the status bar button, since MenuBarExtra offers no hook for them.

import AppKit
import SwiftUI
import HelixKit

/// Brings the main window forward. The popover and the status item menu both open it this way.
@MainActor
func showMainWindow(using openWindow: OpenWindowAction) {
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
}

/// Attaches the right-click menu to the status item that shows this view.
struct StatusItemMenu: ViewModifier {
    let store: SessionStore
    @Environment(\.openWindow) private var openWindow
    @State private var controller: StatusItemMenuController?

    func body(content: Content) -> some View {
        content.onAppear {
            if controller == nil {
                controller = StatusItemMenuController(store: store, openWindow: openWindow)
            }
        }
    }
}

@MainActor
final class StatusItemMenuController: NSObject {
    private let store: SessionStore
    private let openWindow: OpenWindowAction
    private var monitor: Any?

    init(store: SessionStore, openWindow: OpenWindowAction) {
        self.store = store
        self.openWindow = openWindow
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated {
                guard let self, let button = Self.statusBarButton(in: event.window?.contentView) else {
                    return event
                }
                if event.type == .rightMouseDown {
                    self.showMenu(below: button)
                    return nil
                }
                // The first click of a double click opened the popover; the second is passed on
                // so the status item closes it again, and the main window opens in its place.
                if event.clickCount == 2 {
                    self.openHelix()
                }
                return event
            }
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func showMenu(below button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(item("Open Helix", action: #selector(openHelix)))
        menu.addItem(.separator())
        if let bulkPause = store.bulkPause {
            menu.addItem(item(Self.resumeTitle(for: bulkPause), action: #selector(resumeAll)))
        } else {
            menu.addItem(item("Pause All", action: #selector(pauseAll)))
        }
        menu.addItem(item("Pause For...", action: #selector(pauseFor)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Helix", action: #selector(quit)))

        guard let window = button.window else { return }
        // The status bar window can be shorter than the menu bar (a notched display), and a menu
        // whose top overlaps the menu bar scrolls its first item out of view.
        let menuBarBottom = window.screen?.visibleFrame.maxY ?? window.frame.minY
        let belowMenuBar = NSPoint(x: window.frame.minX, y: min(window.frame.minY, menuBarBottom) - 4)
        menu.popUp(positioning: nil, at: belowMenuBar, in: nil)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openHelix() {
        showMainWindow(using: openWindow)
    }

    @objc private func pauseAll() {
        Task { await store.pauseAllSync() }
    }

    @objc private func resumeAll() {
        Task { await store.resumeBulkPause() }
    }

    @objc private func pauseFor() {
        guard let minutes = askForMinutes() else { return }
        let resumeAt = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        Task { await store.pauseAllSync(until: resumeAt) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Asks how long to pause. Returns nil when cancelled; the Pause button stays
    /// disabled until the field holds a positive whole number.
    private func askForMinutes() -> Int? {
        // A menu bar app must come forward, or its alert's field never takes keystrokes.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Pause all sync sessions"
        alert.informativeText = "Minutes until they resume. If Helix is quit before then, they resume the next time it is opened."
        let pauseButton = alert.addButton(withTitle: "Pause")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: "30")
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let observer = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification,
            object: field,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                pauseButton.isEnabled = Self.minutes(in: field.stringValue) != nil
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Self.minutes(in: field.stringValue)
    }

    private static func minutes(in text: String) -> Int? {
        guard let minutes = Int(text.trimmingCharacters(in: .whitespaces)), minutes > 0 else { return nil }
        return minutes
    }

    private static func resumeTitle(for bulkPause: BulkPause) -> String {
        guard let resumeAt = bulkPause.resumeAt else { return "Resume" }
        let date: Date.FormatStyle.DateStyle = Calendar.current.isDateInToday(resumeAt) ? .omitted : .abbreviated
        return "Resume (paused until \(resumeAt.formatted(date: date, time: .shortened)))"
    }

    private static func statusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusBarButton(in: subview) { return button }
        }
        return nil
    }
}
