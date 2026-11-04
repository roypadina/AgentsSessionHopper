import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The global shortcut that opens the menu-bar window. None until the user records one (KBD-7).
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value: ⌘ ⌥ ⌃ ⇧ only.
    var modifiers: UInt
    /// The key without modifiers, for display ("A", "Space", "F5").
    var key: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        let f = flags
        return (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "")
            + (f.contains(.command) ? "⌘" : "") + key
    }

    static let defaultsKey = "openHotkey"

    static var saved: Hotkey? {
        get { UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: defaultsKey) }
    }

    /// Keys whose character is blank or a private-use glyph.
    static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Carbon `RegisterEventHotKey`: global, and needs no Accessibility or Input Monitoring permission.
@MainActor enum HotkeyCenter {
    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    /// macOS refused the last shortcut, usually because another app owns that combination.
    private(set) static var refused = false

    /// Puts `hotkey` (nil = none) in place of the current one. false when macOS refuses it.
    @discardableResult
    static func register(_ hotkey: Hotkey?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        refused = false
        guard let hotkey else { return true }
        installHandlerOnce()
        let f = hotkey.flags
        var carbon: UInt32 = 0
        if f.contains(.command) { carbon |= UInt32(cmdKey) }
        if f.contains(.option) { carbon |= UInt32(optionKey) }
        if f.contains(.control) { carbon |= UInt32(controlKey) }
        if f.contains(.shift) { carbon |= UInt32(shiftKey) }
        let status = RegisterEventHotKey(UInt32(hotkey.keyCode), carbon, EventHotKeyID(signature: 0x4153_4850, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        refused = status != noErr
        StatusMenu.log.notice("hotkey: register \(hotkey.display, privacy: .public) status \(status)")
        return !refused
    }

    private static func installHandlerOnce() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // One shortcut only, so any press of ours means "open".
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { StatusMenu.togglePopover() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// Click, then press the keys. Esc cancels, Delete removes. Meanwhile a local monitor swallows the keys (so ⌘Q or ⌘W
/// cannot fire menu items) and the current shortcut is off (so pressing it again records it instead of opening).
struct HotkeyRecorder: View {
    @State private var hotkey = Hotkey.saved
    @State private var monitor: Any?
    @State private var problem: String? = HotkeyCenter.refused ? HotkeyRecorder.taken : nil

    static let taken = "Another app or macOS already uses this shortcut. Record a different one."

    var body: some View {
        LabeledContent("Open the menu-bar window") {
            HStack(spacing: 4) {
                Button(monitor != nil ? "Type shortcut…" : hotkey?.display ?? "Record Shortcut") {
                    monitor != nil ? finish(hotkey) : start()
                }
                .accessibilityLabel("Shortcut to open the menu-bar window")
                .accessibilityValue(hotkey?.display ?? "none")
                if hotkey != nil, monitor == nil {
                    Button("Remove Shortcut", systemImage: "xmark.circle.fill") { finish(nil) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove shortcut")
                }
            }
        }
        if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        Text("Esc cancels, Delete removes. Works from any app.").font(.caption).foregroundStyle(.secondary)
            .onDisappear { if monitor != nil { finish(hotkey) } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                if monitor != nil { finish(hotkey) }
            }
    }

    private func start() {
        problem = nil
        HotkeyCenter.register(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if e.keyCode == kVK_Escape { return finish(hotkey) }
        if mods.isEmpty, [kVK_Delete, kVK_ForwardDelete].contains(Int(e.keyCode)) { return finish(nil) }
        let key = Hotkey.names[Int(e.keyCode)] ?? e.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard !mods.isDisjoint(with: [.command, .option, .control]), !key.isEmpty else {
            NSSound.beep()
            problem = "Use ⌘, ⌃ or ⌥ with the key."
            return
        }
        finish(Hotkey(keyCode: e.keyCode, modifiers: mods.rawValue, key: key))
    }

    /// Ends recording with `new` as the shortcut (the old one when cancelled) and registers it.
    private func finish(_ new: Hotkey?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if new != Hotkey.saved { Hotkey.saved = new }
        hotkey = new
        problem = HotkeyCenter.register(new) ? nil : Self.taken
    }
}
