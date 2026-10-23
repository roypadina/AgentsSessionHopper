import SessionHopperCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: Tab

    enum Tab: Hashable { case general, handOff, profiles, commandLine, log, about }

    init(model: AppModel, tab: Tab = .general) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            HandOffSettings(model: model).tabItem { Label("Hand-off", systemImage: "arrow.triangle.swap") }.tag(Tab.handOff)
            ProfilesSettings(model: model).tabItem { Label("Profiles", systemImage: "person.2") }.tag(Tab.profiles)
            CommandLineSettings(model: model).tabItem { Label("Command line", systemImage: "terminal") }.tag(Tab.commandLine)
            LogSettings(model: model).tabItem { Label("Log", systemImage: "list.bullet.rectangle") }.tag(Tab.log)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
        }
        .frame(width: 600)
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
            if let err = model.lastError { Text(err).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ key: WritableKeyPath<HopperConfig, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: key] }, set: { v in model.update { $0[keyPath: key] = v } })
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
                Button("Show the first-run guide again") { OnboardingWindow.show(model: model) }
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
                Text("The app never edits your shell files.").font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("AgentsSessionHopper", value: "Version \(HopperInfo.version) \(HopperInfo.stage)")
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
