import SessionHopperCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: Tab

    enum Tab: Hashable { case handOff, profiles, log, about }

    init(model: AppModel, tab: Tab = .handOff) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            HandOffSettings(model: model).tabItem { Label("Hand-off", systemImage: "arrow.triangle.swap") }.tag(Tab.handOff)
            ProfilesSettings(model: model).tabItem { Label("Profiles", systemImage: "person.2") }.tag(Tab.profiles)
            LogSettings(model: model).tabItem { Label("Log", systemImage: "list.bullet.rectangle") }.tag(Tab.log)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
        }
        .frame(width: 560)
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
                Text("New sessions start on the first profile with room. Add a profile in Terminal: sessionhopper profiles add <name> (it runs Claude Code's own login).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
