import AppKit
import OSLog
import SessionHopperCore

/// Right-click / control-click menu on the menu-bar icon. SwiftUI's MenuBarExtra has no hook for it,
/// so a local event monitor catches the click on the status-bar window, swallows it and pops an NSMenu.
@MainActor final class StatusMenu: NSObject {
    static let shared = StatusMenu()
    private var monitor: Any?

    static let requestFeature = URL(string: "https://github.com/roypadina/AgentsSessionHopper/issues/new?template=feature_request.yml")!
    static let contribute = URL(string: "https://github.com/roypadina/AgentsSessionHopper/blob/main/CONTRIBUTING.md")!

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let view = event.window?.contentView,
                  String(describing: type(of: event.window!)).contains("NSStatusBarWindow") else { return event }
            NSMenu.popUpContextMenu(self?.menu() ?? NSMenu(), with: event, for: view)
            return nil
        }
    }

    func menu() -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector, key: String = "") {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            m.addItem(i)
        }
        item("Open", #selector(open))
        item("Settings…", #selector(settings), key: ",")
        item("Show Hand-off Log", #selector(switchLog))
        m.addItem(.separator())
        item("Request a feature", #selector(feature))
        item("Contribute", #selector(contribute))
        item("About AgentsSessionHopper", #selector(about))
        item("Support on Ko-fi ☕", #selector(kofi))
        m.addItem(.separator())
        item("Quit AgentsSessionHopper", #selector(quit), key: "q")
        return m
    }

    @objc private func open() { Self.togglePopover() }
    /// Opens or closes the menu-bar window. MenuBarExtra has no API for it. Up to macOS 26 a click on the status
    /// button does it. On macOS 27 that button has no action: the window opens through an "expanded interface
    /// session" (AppKit SPI, called the way MenuBarExtraAccess does; every selector is checked first).
    static func togglePopover() {
        let key = NSSelectorFromString("statusItem")
        let item = NSApp.windows.lazy
            .filter { String(describing: type(of: $0)).contains("NSStatusBarWindow") && $0.responds(to: key) }
            .compactMap { $0.value(forKey: "statusItem") as? NSStatusItem }
            .first { $0.isVisible }
        guard let item else { return log.error("hotkey: no status item found") }
        NSApp.activate()
        let begin = NSSelectorFromString("_beginExpandedInterfaceSession:"), current = NSSelectorFromString("expandedInterfaceSession")
        guard item.responds(to: begin), item.responds(to: current) else { return item.button?.performClick(nil) ?? () }
        if let session = item.perform(current)?.takeUnretainedValue() as? NSObject {
            if session.responds(to: NSSelectorFromString("cancel")) { session.perform(NSSelectorFromString("cancel")) }
        } else {
            // The argument is the triggering event's time; AppKit drops a begin older than the last session's end.
            typealias Begin = @convention(c) (NSStatusItem, Selector, TimeInterval) -> Void
            unsafeBitCast(item.method(for: begin), to: Begin.self)(item, begin, .greatestFiniteMagnitude)
        }
    }

    static let log = Logger(subsystem: "com.padina.agents-session-hopper", category: "hotkey")

    @objc private func settings() { AgentsSessionHopperApp.openSettings() }
    @objc func switchLog() {
        SettingsView.pendingTab = .log
        NotificationCenter.default.post(name: SettingsView.selectTab, object: nil)
        AgentsSessionHopperApp.openSettings()
    }
    @objc private func feature() { NSWorkspace.shared.open(Self.requestFeature) }
    @objc private func contribute() { NSWorkspace.shared.open(Self.contribute) }
    @objc private func about() { AboutWindow.show() }
    @objc private func kofi() { NSWorkspace.shared.open(HopperInfo.koFi) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
