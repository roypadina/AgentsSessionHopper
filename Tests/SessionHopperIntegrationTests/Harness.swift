import Foundation
import XCTest
@testable import SessionHopperCore

/// Runs the built `sessionhopper` against a FAKE `claude` (a bash stub) in a temp home and state dir.
/// No real Claude Code, no login, no network, never the user's own profiles.
///
/// The stub logs each launch (`CLAUDE_CONFIG_DIR` and args) to `launches`, its cwd to `cwds`, its pid
/// to `pids`, then runs the test's `scenario` script with SID (conversation id) and N (launch number).
/// The scenario plays Claude Code: it pipes status-line and hook payloads into `$SESSIONHOPPER_BIN`,
/// exactly as Claude Code would run the commands we inject. Then the stub idles until SIGTERM.
final class Harness {
    let t: URL
    let home: URL
    let state: URL
    let work: URL
    var defaultDir: URL { home.appendingPathComponent(".claude") }
    var workDir: URL { home.appendingPathComponent(".claude-work") }
    var env: HopperEnvironment { HopperEnvironment(home: home, stateDir: state, selfPath: Harness.binary.path) }

    static let binary: URL = {
        let products = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }!.bundleURL.deletingLastPathComponent()
        return products.appendingPathComponent("sessionhopper")
    }()

    init() throws {
        // Resolved (/private/var/...) so cwd comparisons are exact.
        let tmp = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(tmp) }
        t = URL(fileURLWithPath: String(cString: tmp)).appendingPathComponent("hopper-it-\(UUID().uuidString.prefix(8))")
        home = t.appendingPathComponent("home")
        state = t.appendingPathComponent("state")
        work = t.appendingPathComponent("work")
        let fm = FileManager.default
        try fm.createDirectory(at: defaultDir.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: workDir.appendingPathComponent("projects"), withDestinationURL: defaultDir.appendingPathComponent("projects"))
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try write("""
            #!/bin/bash
            T='\(t.path)'
            if [ "$1" = auth ]; then
              echo "${CLAUDE_CONFIG_DIR:-<unset>} $*" >> "$T/auths"
              [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/logged-out" ] && exit 1; exit 0
            fi
            echo $$ >> "$T/pids"
            { printf '%s %s' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" | tr '\\n' ' '; echo; } >> "$T/launches"
            pwd >> "$T/cwds"
            case "$1" in --version) echo "9.9.9 (stub)"; exit 0;; esac
            SID=""; prev=""
            for a in "$@"; do { [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; } && SID="$a"; prev="$a"; done
            N=$(wc -l < "$T/launches" | tr -d ' ')
            # Claude Code saves a conversation once it has a prompt; `no-transcript` plays one that has none yet.
            [ -n "$SID" ] && [ ! -f "$T/no-transcript" ] && mkdir -p "$T/home/.claude/projects/-w" && touch "$T/home/.claude/projects/-w/$SID.jsonl"
            export SID N T
            emit() { printf '{"hook_event_name":"%s","session_id":"%s"%s}' "$1" "$SID" "$2" | "$SESSIONHOPPER_BIN" hook >> "$T/hook-out"; }
            usage() { printf '{"session_id":"%s","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":4102444800}}}' "$SID" "$1" | "$SESSIONHOPPER_BIN" statusline >> "$T/statusline-out"; }
            export -f emit usage
            trap 'exit 0' TERM
            [ -f "$T/scenario" ] && source "$T/scenario"
            while :; do sleep 0.1; done
            """, "claude", executable: true)
        _ = try run(["profiles", "import"])
    }

    func cleanup() {
        // Kill exactly the pids the stub recorded - never by pattern.
        for pid in (read("pids") ?? "").split(separator: "\n").compactMap({ Int32($0) }) { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: t)
    }

    func write(_ text: String, _ name: String, executable: Bool = false) throws {
        let url = t.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func read(_ name: String) -> String? { try? String(contentsOf: t.appendingPathComponent(name), encoding: .utf8) }

    func scenario(_ body: String) throws { try write(body, "scenario") }

    var launches: [String] { (read("launches") ?? "").split(separator: "\n").map(String.init) }

    func config(_ change: (inout HopperConfig) -> Void) throws {
        var c = HopperConfig.load(env.paths)
        change(&c)
        try c.save(env.paths)
    }

    struct Result { var code: Int32; var stdout: String; var stderr: String }

    /// Runs the CLI in `cwd` (default: the work dir) and waits up to `timeout`.
    @discardableResult
    func run(_ args: [String], cwd: URL? = nil, exe: URL? = nil, extraEnv: [String: String] = [:], timeout: TimeInterval = 20, onStart: ((Process) -> Void)? = nil) throws -> Result {
        let p = Process()
        p.executableURL = exe ?? Harness.binary
        p.arguments = args
        p.currentDirectoryURL = cwd ?? work
        p.environment = [
            "HOME": home.path, "PATH": "/usr/bin:/bin",
            "SESSIONHOPPER_HOME": home.path, "SESSIONHOPPER_STATE_DIR": state.path,
            "SESSIONHOPPER_CLAUDE_BIN": t.appendingPathComponent("claude").path,
            "SESSIONHOPPER_KILL_GRACE": "3", "SESSIONHOPPER_POLL": "0.05"
        ].merging(extraEnv) { $1 }
        let out = t.appendingPathComponent("out-\(UUID().uuidString.prefix(6))")
        FileManager.default.createFile(atPath: out.path + ".o", contents: nil)
        FileManager.default.createFile(atPath: out.path + ".e", contents: nil)
        p.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: out.path + ".o"))
        p.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: out.path + ".e"))
        p.standardInput = FileHandle.nullDevice
        try p.run()
        onStart?(p)
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
            XCTFail("sessionhopper \(args.joined(separator: " ")) timed out")
        }
        let o = (try? String(contentsOfFile: out.path + ".o", encoding: .utf8)) ?? ""
        let e = (try? String(contentsOfFile: out.path + ".e", encoding: .utf8)) ?? ""
        return Result(code: p.terminationStatus, stdout: o, stderr: e)
    }

    func events() -> [HopperEvent] { EventLog.read(env.paths) }

    func sessionID(fromLaunch line: String) -> String? {
        let parts = line.split(separator: " ").map(String.init)
        for flag in ["--session-id", "--resume"] {
            if let i = parts.firstIndex(of: flag), i + 1 < parts.count { return parts[i + 1] }
        }
        return nil
    }
}
