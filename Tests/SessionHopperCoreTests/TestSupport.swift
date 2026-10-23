import Foundation
@testable import SessionHopperCore

/// A throwaway home + state dir. Never touches the real ~/.claude* profiles.
final class Sandbox {
    let root: URL
    let home: URL
    let state: URL

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hopper-test-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        state = root.appendingPathComponent("state")
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func env(_ vars: [String: String] = [:]) -> HopperEnvironment {
        HopperEnvironment(home: home, stateDir: state, claudeBin: "/nonexistent/claude", selfPath: "/opt/x/sessionhopper",
                          killGrace: 1, pollInterval: 0.05, vars: vars)
    }

    /// A profile dir under the fake home.
    @discardableResult
    func profileDir(_ entry: String, settings: String? = nil) -> URL {
        let d = home.appendingPathComponent(entry)
        try! FileManager.default.createDirectory(at: d.appendingPathComponent("projects"), withIntermediateDirectories: true)
        if let settings { try! settings.write(to: d.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8) }
        return d
    }

    func write(_ text: String, _ path: String) {
        let url = root.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }
}

func profile(_ name: String, _ dir: String = "/p", export: Bool = true) -> Profile {
    Profile(name: name, dir: dir == "/p" ? "/p/\(name)" : dir, exportConfigDir: export)
}

func limits(_ five: Double?, week: Double? = nil, resets: Double? = nil) -> ProfileLimits {
    ProfileLimits(fiveHour: five.map { LimitWindow(usedPercentage: $0, resetsAt: resets) },
                  sevenDay: week.map { LimitWindow(usedPercentage: $0, resetsAt: resets) }, sampledAt: 0)
}

func json(_ s: String?) -> [String: Any]? { s.flatMap { FileIO.jsonObject(Data($0.utf8)) } }
