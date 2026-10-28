import SessionHopperCore
import SwiftUI

/// Own window, like AboutWindow: `showSettingsWindow:` is ignored on macOS 14+ and `openSettings`
/// needs a SwiftUI view, so neither works from the NSMenu or the MenuBarExtra panel.
@MainActor enum SettingsWindow {
    static var model: AppModel?
    private static var window: NSWindow?
    private static var toolbar: SettingsToolbar?

    static func show() {
        guard let model else { return }
        if window == nil {
            let nav = SettingsNav()
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, nav: nav).frame(width: 600, height: 480)))  // grouped Forms have no ideal height outside a Settings scene
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            let tb = SettingsToolbar(nav: nav, window: w)
            toolbar = tb
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        toolbar?.applyPending()
    }
}

final class SettingsNav: ObservableObject {
    @Published var tab: SettingsView.Tab = .general
}

/// Classic preferences toolbar: icon + label per tab, selected one highlighted, window title follows the tab.
@MainActor final class SettingsToolbar: NSObject, NSToolbarDelegate {
    private static let tabs: [(SettingsView.Tab, String, String)] = [
        (.general, "General", "gearshape"), (.handOff, "Hand-off", "arrow.triangle.swap"),
        (.profiles, "Profiles", "person.2"), (.commandLine, "Command line", "terminal"),
        (.log, "Log", "list.bullet.rectangle"), (.about, "About", "info.circle"),
    ]
    private let nav: SettingsNav
    private let window: NSWindow
    private let toolbar = NSToolbar(identifier: "SettingsToolbar")

    init(nav: SettingsNav, window: NSWindow) {
        self.nav = nav
        self.window = window
        super.init()
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .preference
        window.toolbar = toolbar
        select(.general)
        NotificationCenter.default.addObserver(forName: SettingsView.selectTab, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPending() }
        }
    }

    func applyPending() {
        if let t = SettingsView.pendingTab { select(t); SettingsView.pendingTab = nil }
    }

    private func select(_ t: SettingsView.Tab) {
        nav.tab = t
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(String(describing: t))
        window.title = Self.tabs.first { $0.0 == t }!.1
    }

    @objc private func clicked(_ sender: NSToolbarItem) {
        if let t = Self.tabs.first(where: { NSToolbarItem.Identifier(String(describing: $0.0)) == sender.itemIdentifier })?.0 { select(t) }
    }

    private var ids: [NSToolbarItem.Identifier] { Self.tabs.map { NSToolbarItem.Identifier(String(describing: $0.0)) } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] + ids + [.flexibleSpace] }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let t = Self.tabs.first(where: { NSToolbarItem.Identifier(String(describing: $0.0)) == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = t.1
        item.image = NSImage(systemSymbolName: t.2, accessibilityDescription: t.1)
        item.target = self
        item.action = #selector(clicked)
        return item
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: SettingsNav

    enum Tab: Hashable { case general, handOff, profiles, commandLine, log, about }
    /// Set by the status-item menu; SettingsToolbar applies it (window already open → notification, else on show).
    static var pendingTab: Tab?
    static let selectTab = Notification.Name("SettingsView.selectTab")

    var body: some View {
        switch nav.tab {
        case .general: GeneralSettings(model: model)
        case .handOff: HandOffSettings(model: model)
        case .profiles: ProfilesSettings(model: model)
        case .commandLine: CommandLineSettings(model: model)
        case .log: LogSettings(model: model)
        case .about: AboutSettings()
        }
    }
}

private struct HandOffSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Stepper(value: binding(\.suggestThreshold), in: 50...95, step: 1) {
                    LabeledContent("Suggest a move at", value: "\(Int(model.config.suggestThreshold))%")
                }
                Text("When a session's profile reaches this share of its 5-hour or weekly limit and another profile has room, you are asked whether to continue the conversation there. Nothing moves until you confirm.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Move without asking", isOn: binding(\.autoMove))
                Text("Off by default. When on, a session past the threshold moves to the next profile with room at the end of its current turn, without a prompt. Every move is still written to the log. Use it only with accounts that are all yours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Park before paid usage", isOn: binding(\.parkBeforePaid))
                Stepper(value: binding(\.hardThreshold), in: 80...100, step: 1) {
                    LabeledContent("Park at", value: "\(Int(model.config.hardThreshold))%")
                }
                .disabled(!model.config.parkBeforePaid)
                Text("Past this, a session you have not moved ends at its next turn end, so it does not run into paid extra usage. It is never moved for you; resume it later or on another profile.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Hold every session", isOn: Binding(get: { model.holdAll }, set: { model.setHoldAll($0) }))
            }
            ContinuePromptSection(model: model)
            if let err = model.lastError { Text(err).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ key: WritableKeyPath<HopperConfig, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: key] }, set: { v in model.update { $0[keyPath: key] = v } })
    }
}

/// The message a session that was cut off by a move resumes with. Idle sessions resume without one.
private struct ContinuePromptSection: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    var body: some View {
        Section {
            TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(height: 110)
            HStack {
                Text(model.config.continuePrompt == nil ? "Built-in" : "Your own").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to built-in") { model.update { $0.continuePrompt = nil }; text = LaunchPlan.defaultContinuePrompt }
                Button("Save") { model.update { $0.continuePrompt = text == LaunchPlan.defaultContinuePrompt ? nil : text } }
                    .disabled(text == (model.config.continuePrompt ?? LaunchPlan.defaultContinuePrompt))
            }
            Text("Sent when a move cut work off. Placeholders: {reason} why it stopped, {jobs} and {crons} what was running, {from} and {to} profile names. \"[sessionhopper] \" is always put in front.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Continue prompt") }
        .onAppear { text = model.config.continuePrompt ?? LaunchPlan.defaultContinuePrompt }
    }
}

private struct ProfilesSettings: View {
    @ObservedObject var model: AppModel
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                ForEach(Array(model.config.profiles.enumerated()), id: \.element.id) { i, p in
                    HStack {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(p.name)
                            Text(model.tilde(p.dir)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        LoginBadge(model: model, profile: p)
                        Button { model.moveProfile(p.name, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(i == 0).accessibilityLabel("Move \(p.name) up")
                        Button { model.moveProfile(p.name, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(i == model.config.profiles.count - 1).accessibilityLabel("Move \(p.name) down")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Fallback order")
            } footer: {
                Text("New sessions start on the first profile with room. Moving a session needs every profile to share one projects/ folder; profiles added here do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Add Profile…") { adding = true }
                    let found = model.discovered
                    if !found.isEmpty {
                        Button("Import \(found.count) found (\(found.map(\.name).joined(separator: ", ")))") { model.importDiscovered() }
                    }
                    Spacer()
                    Button(model.checkingLogins ? "Checking…" : "Check logins") { model.checkLogins() }
                        .disabled(model.checkingLogins)
                }
            }
            if let err = model.lastError { Text(err).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { AddProfileSheet(model: model, isPresented: $adding) }
    }
}

struct LoginBadge: View {
    @ObservedObject var model: AppModel
    let profile: Profile

    var body: some View {
        switch model.loggedIn[profile.name] {
        case true?:
            Label("Logged in", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
        case false?:
            Menu("Log in…") {
                Button("Open in Terminal") { model.openLoginInTerminal(profile) }
                Button("Copy command") { model.copyLoginCommand(profile) }
            }
            .menuStyle(.borderlessButton).fixedSize()
        case nil:
            EmptyView()
        }
    }
}

/// New profile: a folder next to ~/.claude with history shared; login runs in Claude Code's own flow.
struct AddProfileSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var share = true
    @State private var created: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a profile").font(.headline)
            if let p = created {
                Text("Created \(model.tilde(p.dir)). Now log it in with the Claude account you want here. Login happens in Claude Code's own flow; this app never sees it.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.loginCommand(p)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Open in Terminal") { model.openLoginInTerminal(p) }
                    Button("Copy command") { model.copyLoginCommand(p) }
                    Spacer()
                    Button("Done") { isPresented = false; model.checkLogins() }.keyboardShortcut(.defaultAction)
                }
            } else {
                TextField("Name (e.g. work)", text: $name)
                Text("Folder: ~/.claude-\(name.isEmpty ? "<name>" : name)").font(.caption).foregroundStyle(.secondary)
                Toggle("Share my setup (CLAUDE.md, agents, commands, skills; settings are copied)", isOn: $share)
                Text("Conversation history (projects/) is always shared, so sessions can move between profiles.")
                    .font(.caption).foregroundStyle(.secondary)
                if let err = model.lastError { Text(err).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                    Button("Create") { created = model.addProfile(name: name, shareSetup: share) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!Profiles.isValidName(name))
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(Notifier.enabledKey) private var notifications = true
    @AppStorage(MenuBarLabel.showPercentKey) private var showPercent = true
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LoginItem.set(on) } catch { model.lastError = "\(error.localizedDescription)"; launchAtLogin = LoginItem.isEnabled }
                    }
                Toggle("Notify me when a session should move", isOn: $notifications)
                Toggle("Show usage % next to the menu-bar icon", isOn: $showPercent)
            }
            Section {
                Text("AgentsSessionHopper makes no network requests and never reads your Claude login or tokens. Usage comes only from what Claude Code shows its own status line.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Run setup again") { OnboardingWindow.show(model: model) }
            }
            if let err = model.lastError { Text(err).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }
}

private struct CommandLineSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let cli = model.env.selfPath
        Form {
            Section {
                LabeledContent("CLI", value: model.tilde(cli))
                Text("Installed with Homebrew, `sessionhopper` is already on your PATH. Otherwise link it yourself:")
                    .font(.caption).foregroundStyle(.secondary)
                CopyRow(text: "ln -s \(FileIOQuote(cli)) /usr/local/bin/sessionhopper")
            } header: { Text("Command line") }
            Section {
                Text("Start sessions with `sessionhopper` instead of `claude`. To make every interactive `claude` a supervised session, add to your shell profile:")
                    .font(.caption).foregroundStyle(.secondary)
                CopyRow(text: "alias claude='sessionhopper shim'")
                Text("For cmux or an IDE that asks for a Claude binary path, link the CLI under a name ending in -shim and use that path. Subcommands, -p and --version still go straight to claude.")
                    .font(.caption).foregroundStyle(.secondary)
                CopyRow(text: "ln -s \(FileIOQuote(cli)) ~/.local/bin/sessionhopper-shim")
            } header: { Text("Use it by default (optional)") } footer: {
                Text("The app edits your shell file only when you click Add the line in setup.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

func FileIOQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

struct CopyRow: View {
    let text: String
    var body: some View {
        HStack {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}


private struct LogSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(model.snapshot.events.reversed()) {
                TableColumn("Time") { Text(eventTime($0.ts)).monospacedDigit() }.width(90)
                TableColumn("Event") { Text($0.type) }.width(55)
                TableColumn("From → to") { e in Text([e.from, e.to].compactMap { $0 }.joined(separator: " → ")) }.width(120)
                TableColumn("Why") { e in Text([e.trigger, e.source].compactMap { $0 }.joined(separator: ", ")) }.width(110)
                TableColumn("Folder") { e in Text(e.cwd.map(model.tilde) ?? "").lineLimit(1).truncationMode(.head) }
            }
            .frame(minHeight: 260)
            HStack {
                Text("\(model.snapshot.events.count) entries · \(model.env.paths.events.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Reveal in Finder") { model.revealLog() }
            }
        }
        .padding()
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("AgentsSessionHopper", value: "Version \(HopperInfo.version)")
                HStack {
                    Button("About…") { AboutWindow.show() }
                    Link("Support on Ko-fi ☕", destination: HopperInfo.koFi)
                }
                Text(HopperInfo.disclaimer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
