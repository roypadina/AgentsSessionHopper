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
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, nav: nav)))
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            let tb = SettingsToolbar(nav: nav, window: w)
            toolbar = tb
            w.center()
            window = w
        }
        if let window { AccessoryWindows.shared.show(window) }
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
        Group {
            switch nav.tab {
            case .general: GeneralSettings(model: model)
            case .handOff: HandOffSettings(model: model)
            case .profiles: ProfilesSettings(model: model)
            case .commandLine: CommandLineSettings(model: model)
            case .log: LogSettings(model: model)
            case .about: AboutSettings(model: model)
            }
        }
        .frame(width: 600, height: min(nav.tab.height, (NSScreen.main?.visibleFrame.height ?? 800) - 90))  // one width, height per pane (SET-8): grouped Forms have no ideal height; capped so a small screen scrolls
    }
}

extension SettingsView.Tab {
    /// Chosen from each pane's rows; re-pick when rows change.
    var height: CGFloat {
        switch self {
        case .general: 460
        case .handOff: 800
        case .profiles: 460
        case .commandLine: 470
        case .log: 480
        case .about: 330
        }
    }
}

extension View {
    /// System Settings look for a Section footer (mac-design SET-6).
    func formFooter() -> some View {
        font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }
}

private struct HandOffSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                PercentStepper(title: "Suggest a move at", value: binding(\.suggestThreshold), range: 50...95)
            } header: { Text("Suggestions") } footer: {
                Text("When a session's profile reaches this share of its 5-hour or weekly limit and another profile has room, you are asked whether to continue the conversation there. Nothing moves until you confirm.").formFooter()
            }
            Section {
                Toggle("Move without asking", isOn: binding(\.autoMove))
            } footer: {
                Text("Off by default. When on, a session past the threshold moves to the next profile with room at the end of its current turn, without a prompt. Every move is still written to the log. Use it only with accounts that are all yours.").formFooter()
            }
            Section {
                Toggle("Park before paid usage", isOn: binding(\.parkBeforePaid))
                PercentStepper(title: "Park at", value: binding(\.hardThreshold), range: 80...100)
                    .disabled(!model.config.parkBeforePaid)
            } header: { Text("Paid Usage") } footer: {
                Text("Past this, a session you have not moved ends at its next turn end, so it does not run into paid extra usage. It is never moved for you; resume it later or on another profile.").formFooter()
            }
            Section {
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

/// Label on the left, value next to its stepper on the trailing edge.
private struct PercentStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text("\(Int(value))%").monospacedDigit()
                Stepper(title, value: $value, in: range, step: 1).labelsHidden()
                    .accessibilityValue("\(Int(value)) percent")
            }
        }
    }
}

/// The message a session that was cut off by a move resumes with. Idle sessions resume without one.
private struct ContinuePromptSection: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    var body: some View {
        Section {
            TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(height: 110)
                .accessibilityLabel("Continue prompt")
            HStack {
                Text(model.config.continuePrompt == nil ? "Built-in" : "Your own").foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Built-in") { model.update { $0.continuePrompt = nil }; text = LaunchPlan.defaultContinuePrompt }
                Button("Save") { model.update { $0.continuePrompt = text == LaunchPlan.defaultContinuePrompt ? nil : text } }
                    .disabled(text == (model.config.continuePrompt ?? LaunchPlan.defaultContinuePrompt))
            }
        } header: { Text("Continue Prompt") } footer: {
            Text("Sent when a move cut work off. Placeholders: {reason} why it stopped, {jobs} and {crons} what was running, {from} and {to} profile names. \"[sessionhopper] \" is always put in front.").formFooter()
        }
        .onAppear { text = model.config.continuePrompt ?? LaunchPlan.defaultContinuePrompt }
    }
}

private struct ProfilesSettings: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    @State private var adding = false
    @State private var removing: Profile?
    @State private var renaming: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(model.config.profiles) { p in
                    ProfileSettingsRow(model: model, profile: p)
                        .accessibilityAction(named: "Rename") { renaming = p }
                        .accessibilityAction(named: "Move Up") { model.moveProfile(p.name, by: -1) }
                        .accessibilityAction(named: "Move Down") { model.moveProfile(p.name, by: 1) }
                }
                .onMove { model.moveProfiles(from: $0, to: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { names in
                if let p = names.first.flatMap(model.config.profile(named:)) { menu(p) }
            } primaryAction: { names in
                renaming = names.first.flatMap(model.config.profile(named:))  // double-click or Return
            }
            HStack(spacing: 8) {
                HStack(spacing: 0) {  // +/− under the list, like System Settings
                    Button { adding = true } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                        .help("Add Profile…").accessibilityLabel("Add Profile")
                    Divider().frame(height: 14)
                    Button { removing = selection.flatMap(model.config.profile(named:)) } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                        .help("Remove from List…").accessibilityLabel("Remove Profile from List")
                        .disabled(selection.flatMap(model.config.profile(named:)) == nil)  // a removed row may stay selected
                }
                .buttonStyle(.borderless)
                Spacer()
                let found = model.discovered
                if !found.isEmpty {
                    Button("Import \(found.count) Found (\(found.map(\.name).joined(separator: ", ")))") { model.importDiscovered() }
                        .help("Profiles on disk that are not in the list yet")
                }
                Button(model.checkingLogins ? "Checking…" : "Check Logins") { model.checkLogins() }
                    .disabled(model.checkingLogins)
            }
            .padding(.top, 6)
            Text("The list order is also the fallback order: drag to reorder. Lower priority numbers are preferred: Claude accounts default to 1, API-key profiles to 10. Profiles of equal priority are used in list order and don't trade places before one reaches its limit; a session moves back to a better priority as soon as one has room. Moving needs every profile to share one projects/ folder; profiles added here do.")
                .formFooter().fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            if let err = model.lastError { Text(err).foregroundStyle(.red).padding(.top, 6) }
        }
        .padding(20)
        .sheet(isPresented: $adding) { AddProfileSheet(model: model, isPresented: $adding) }
        .sheet(item: $renaming) { RenameProfileSheet(model: model, profile: $0) }
        .confirmationDialog("Remove \(removing?.displayName ?? "") from the list?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { p in
            Button("Remove", role: .destructive) { model.removeProfile(p.name) }
        } message: { p in
            Text(p.isGateway ? "Its key stays in the Keychain." : "Its folder and login stay on disk; add it again with Import.")
        }
    }

    @ViewBuilder private func menu(_ p: Profile) -> some View {
        let i = model.config.profiles.firstIndex { $0.name == p.name } ?? 0
        Button("Rename…") { renaming = p }
        Button("Move Up") { model.moveProfile(p.name, by: -1) }.disabled(i == 0)
        Button("Move Down") { model.moveProfile(p.name, by: 1) }.disabled(i == model.config.profiles.count - 1)
        Divider()
        Button("Remove from List…", role: .destructive) { removing = p }
    }
}

/// Display name (bold), login email, then `name · folder`; login state and priority on the trailing edge.
private struct ProfileSettingsRow: View {
    @ObservedObject var model: AppModel
    let profile: Profile

    var body: some View {
        let p = profile
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.displayName).bold()
                if let email = model.snapshot.emails[p.name] {
                    Text(email).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text("\(p.name) · " + (p.isGateway ? "\(Gateway.kindName(p)) · pay per use" : model.tilde(p.dir)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            LoginBadge(model: model, profile: p)
            Picker("Priority", selection: Binding(get: { p.priority ?? 0 }, set: { model.setPriority(p.name, $0 == 0 ? nil : $0) })) {
                Text("Default (\(model.priority({ var d = p; d.priority = nil; return d }())))").tag(0)
                Divider()
                ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("Priority \(model.priority(p)): lower is preferred")
            .accessibilityLabel("Priority of \(p.displayName)")
        }
        .padding(.vertical, 4)
    }
}

/// A sheet, not an inline field: a TextField inside a List row with `.onMove` can lose its clicks to the drag.
struct RenameProfileSheet: View {
    @ObservedObject var model: AppModel
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var clash = false
    @FocusState private var focused: Bool

    init(model: AppModel, profile: Profile) {
        self.model = model
        self.profile = profile
        _draft = State(initialValue: profile.label ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename \(profile.displayName)").font(.headline)
            TextField("Display name", text: $draft, prompt: Text(profile.name))
                .focused($focused)
                .onSubmit(save)
                .onChange(of: draft) { clash = false }
            if clash {
                Text("\"\(draft.trimmingCharacters(in: .whitespaces))\" is already another profile's name or label.").font(.caption).foregroundStyle(.red)
            } else {
                Text("Shown instead of \(profile.name) everywhere. Leave it empty to show \(profile.name). The profile name itself, used by aliases and -P, doesn't change.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .defaultFocus($focused, true)
        .onAppear { focused = true }
    }

    private func save() { if model.setLabel(profile.name, draft) { dismiss() } else { clash = true } }  // a clash keeps the sheet open
}

struct LoginBadge: View {
    @ObservedObject var model: AppModel
    let profile: Profile

    var body: some View {
        switch model.loggedIn[profile.name] {
        case true?:
            Label(profile.isGateway ? "Key found" : "Logged in", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
        case false? where profile.isGateway:
            Label("No key", systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.orange)
                .help("Remove it and add it again with its key, or run: sessionhopper profiles key \(profile.name)")
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

/// New profile: a Claude account (a folder next to ~/.claude with history shared; login runs in Claude Code's own
/// flow) or an API key: OpenRouter, Anthropic API or another gateway (pay per use, key in the Keychain).
struct AddProfileSheet: View {
    enum Kind: Hashable {
        case claude, openRouter, anthropic, gateway
        var id: String { self == .anthropic ? Gateway.anthropic : self == .gateway ? Gateway.custom : Gateway.openRouter }
    }
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var kind: Kind
    @State private var name: String
    @State private var share = true
    @State private var created: Profile?
    @State private var key = ""
    @State private var opus = "anthropic/claude-opus-5"
    @State private var sonnet = "anthropic/claude-sonnet-5"
    @State private var haiku = "anthropic/claude-haiku-4.5"
    @State private var resets = "daily"
    @State private var url = ""

    init(model: AppModel, isPresented: Binding<Bool>, kind: Kind = .claude) {
        self.model = model
        _isPresented = isPresented
        _kind = State(initialValue: kind)
        _name = State(initialValue: kind == .claude ? "" : kind.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a profile").font(.headline)
            if created == nil {
                Picker("Kind", selection: $kind) {
                    Text("Claude account").tag(Kind.claude)
                    Text("OpenRouter key (pay per use)").tag(Kind.openRouter)
                    Text("Anthropic API key (pay per use)").tag(Kind.anthropic)
                    Text("Other gateway, e.g. LiteLLM for an OpenAI key (pay per use)").tag(Kind.gateway)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .onChange(of: kind) { old, k in
                    if k != .claude, name.isEmpty || name == old.id { name = k.id }
                    (opus, sonnet, haiku) = k == .openRouter ? ("anthropic/claude-opus-5", "anthropic/claude-sonnet-5", "anthropic/claude-haiku-4.5") : ("", "", "")
                }
            }
            if kind != .claude, created == nil {
                openRouterForm
            } else if let p = created {
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
        .frame(width: 460)
        .onAppear { model.lastError = nil }
    }

    @ViewBuilder private var openRouterForm: some View {
        Form {
            TextField("Name", text: $name)
            if kind == .gateway { TextField("Gateway URL", text: $url, prompt: Text("http://localhost:4000")) }
            SecureField("API key", text: $key, prompt: Text(kind == .openRouter ? "sk-or-v1-…" : kind == .anthropic ? "sk-ant-api03-…" : "gateway key"))
            Picker("Credit resets", selection: $resets) {
                Text("Daily").tag("daily"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly")
            }
            if kind != .anthropic {
                Section {
                    TextField("Opus", text: $opus)
                    TextField("Sonnet", text: $sonnet)
                    TextField("Haiku", text: $haiku)
                } header: { Text(kind == .openRouter ? "Model names on OpenRouter" : "Model names on the gateway (empty = Claude's own)") }
            }
        }
        .formStyle(.grouped).frame(height: kind == .gateway ? 340 : 300)
        Text("Used only when no Claude profile has room (priority 10). The key is stored in your Keychain and handed only to Claude Code runs on this profile.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let err = model.lastError { Text(err).font(.caption).foregroundStyle(.red) }
        HStack {
            if kind != .gateway {
                Link("Get a key", destination: URL(string: kind == .anthropic ? "https://platform.claude.com/settings/keys" : "https://openrouter.ai/keys")!)
            }
            Spacer()
            Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            Button("Add") {
                let models = ["opus": opus, "sonnet": sonnet, "haiku": haiku].filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                if model.addGateway(name: name, kind: kind.id, baseURL: url, key: key, models: kind == .anthropic ? [:] : models, resets: resets) { isPresented = false }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!Profiles.isValidName(name) || key.trimmingCharacters(in: .whitespaces).isEmpty
                      || (kind == .gateway && !Gateway.validURL(url.trimmingCharacters(in: .whitespaces))))
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(Notifier.enabledKey) private var notifications = true
    @AppStorage(MenuBarLabel.showPercentKey) private var showPercent = true

    var body: some View {
        Form {
            Section {
                LaunchAtLoginToggle()
                Toggle("Notify me when a session should move", isOn: $notifications)
                Toggle("Show usage % next to the menu-bar icon", isOn: $showPercent)
            }
            Section("Keyboard Shortcut") { HotkeyRecorder() }
            Section {
                LabeledContent("Profiles, logins and shell") { Button("Run Setup Again…") { OnboardingWindow.show(model: model) } }
            } header: { Text("Setup") } footer: {
                Text("AgentsSessionHopper makes no network requests of its own and never reads your Claude login. Usage comes from what Claude Code shows its own status line; a profile not seen for 6 hours (or every profile, on Refresh) is checked with one tiny `claude -p` on Haiku, a small request on that account.").formFooter()
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
                LabeledContent("CLI") { Text(model.tilde(cli)).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                CopyRow(text: "ln -s \(FileIOQuote(cli)) /usr/local/bin/sessionhopper")
            } header: { Text("Command Line") } footer: {
                Text("Installed with Homebrew, `sessionhopper` is already on your PATH. Otherwise link it yourself with the command above.").formFooter()
            }
            Section {
                CopyRow(text: "alias claude='sessionhopper shim'")
            } header: { Text("Use It by Default (Optional)") } footer: {
                Text("Start sessions with `sessionhopper` instead of `claude`. To make every interactive `claude` a supervised session, add this line to your shell profile. The app edits your shell file only when you click Add the line in setup.").formFooter()
            }
            Section {
                CopyRow(text: "ln -s \(FileIOQuote(cli)) ~/.local/bin/sessionhopper-shim")
            } header: { Text("cmux or an IDE") } footer: {
                Text("For cmux or an IDE that asks for a Claude binary path, link the CLI under a name ending in -shim and use that path. Subcommands, -p and --version still go straight to claude.").formFooter()
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
            .overlay {
                if model.snapshot.events.isEmpty {
                    ContentUnavailableView("No Hand-offs Yet", systemImage: "list.bullet.rectangle",
                                           description: Text("Suggestions, moves and parked sessions show up here."))
                }
            }
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
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: AboutView.icon).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
            Text("AgentsSessionHopper").font(.title2.bold())
            Text("Version \(HopperInfo.version)").font(.caption).foregroundStyle(.secondary)
            Button("Check for Updates…") { Updates.check() }  // own row: the button row below is full at 600 pt
            HStack {
                Button("About…") { AboutWindow.show() }
                Button("Welcome Guide…") { WelcomeWindow.show(model: model) }
                Link("Support on Ko-fi ☕", destination: HopperInfo.koFi).buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 4)
            Text(HopperInfo.disclaimer).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.top, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
