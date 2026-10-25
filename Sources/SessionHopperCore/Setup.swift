import Foundation

/// The pieces of a full setup beyond profiles: shared history for existing profiles, the `claude` alias,
/// the shim link for tools, and the Claude skill per profile. Each one shows what it will do, changes
/// only what it names, and never deletes: replaced folders and files are moved to a backup next to them.
public enum Setup {
    // MARK: - Sharing history and setup with the base profile

    /// Claude Code's own registry of running sessions (`<dir>/sessions/<pid>.json`, best effort):
    /// moving a folder a live `claude` writes to would split its transcript.
    public static func livePIDs(_ profile: Profile) -> [Int32] {
        let dir = URL(fileURLWithPath: profile.dir).appendingPathComponent("sessions")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).compactMap { f in
            guard f.pathExtension == "json", let pid = (FileIO.jsonObject(FileIO.read(f))?["pid"] as? NSNumber)?.int32Value,
                  FileIO.isAlive(pid) else { return nil }
            return pid
        }
    }

    /// Links `projects/` (always) and `items` of `profile` to the base profile's. A missing item is linked;
    /// an empty folder is replaced by the link; a folder with content is moved to `<item>.ash-backup-<time>`,
    /// its files copied into the base (on a clash the newer file wins; the base's older copy goes into the
    /// backup too), then linked. `dryRun` only reports. Refuses while `claude` runs on that profile.
    public static func share(_ profile: Profile, base: Profile, items: [String] = Profiles.sharedSetup,
                             dryRun: Bool, now: Date = Date()) throws -> [String] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: profile.dir), baseDir = URL(fileURLWithPath: base.dir)
        guard dir.standardizedFileURL != baseDir.standardizedFileURL else { return ["\(profile.name) is the base profile; nothing to share"] }
        if !dryRun, !livePIDs(profile).isEmpty {
            throw HopperError("claude is running on \(profile.name) (pid \(livePIDs(profile).map(String.init).joined(separator: ", "))). Quit those sessions first, then share.")
        }
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: now) }()
        var did: [String] = []
        for item in ["projects"] + items.filter({ $0 != "projects" }) {
            let at = dir.appendingPathComponent(item), src = baseDir.appendingPathComponent(item)
            if !fm.fileExists(atPath: src.path) {
                guard item == "projects" || item == "todos" || item == "file-history" else { continue }  // folders Claude Code creates on first use
                if !dryRun { try fm.createDirectory(at: src, withIntermediateDirectories: true) }
            }
            let target = src.resolvingSymlinksInPath()
            if let dest = try? fm.destinationOfSymbolicLink(atPath: at.path) {
                did.append(URL(fileURLWithPath: dest, relativeTo: dir).resolvingSymlinksInPath() == target ? "\(item): already shared" : "\(item): links elsewhere, left alone")
                continue
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: at.path, isDirectory: &isDir) {
                let empty = isDir.boolValue && ((try? fm.contentsOfDirectory(atPath: at.path)) ?? []).filter { $0 != ".DS_Store" }.isEmpty
                let backup = dir.appendingPathComponent("\(item).ash-backup-\(stamp)")
                if empty {
                    did.append("\(item): empty folder replaced by a link")
                    if !dryRun { try fm.removeItem(at: at) }
                } else {
                    did.append("\(item): moved to \(backup.lastPathComponent)" + (isDir.boolValue ? ", its files merged into \(base.name)" : "; \(base.name)'s copy is used"))
                    if !dryRun {
                        try fm.moveItem(at: at, to: backup)
                        if isDir.boolValue { try merge(backup, into: target, keepReplacedIn: backup.appendingPathComponent(".replaced-in-\(base.name)")) }
                    }
                }
            } else {
                did.append("\(item): linked")
            }
            if !dryRun { try fm.createSymbolicLink(at: at, withDestinationURL: target) }
        }
        return did
    }

    /// Copies every file under `from` into `into`. On a clash the newer file wins; a replaced file is kept
    /// under `keepReplacedIn` (same relative path). Never deletes.
    static func merge(_ from: URL, into: URL, keepReplacedIn: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: from, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { return }
        let fromPath = from.standardizedFileURL.path, skip = keepReplacedIn.standardizedFileURL.path
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  path.hasPrefix(fromPath + "/"), !path.hasPrefix(skip) else { continue }
            let rel = String(path.dropFirst(fromPath.count + 1))
            let real = url
            let dest = into.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
                guard mtime(real) > mtime(dest) else { continue }
                let keep = keepReplacedIn.appendingPathComponent(rel)
                try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: dest, to: keep)
            }
            try fm.copyItem(at: real, to: dest)
        }
    }

    // MARK: - The `claude` alias in the user's shell

    public enum ShellKind: String, CaseIterable, Sendable { case zsh, bash, fish, tcsh }

    public static let marker = "# AgentsSessionHopper"

    public static func shellKind(_ vars: [String: String]) -> ShellKind {
        switch ((vars["SHELL"] ?? "/bin/zsh") as NSString).lastPathComponent {
        case "bash": .bash
        case "fish": .fish
        case "tcsh", "csh": .tcsh
        default: .zsh
        }
    }

    /// The file the alias goes in. fish gets a file of its own in `conf.d` (no edit to the user's config).
    public static func rcFile(_ kind: ShellKind, home: URL, vars: [String: String]) -> URL {
        let fm = FileManager.default
        func first(_ names: [String], else fallback: String) -> URL {
            names.map { home.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) } ?? home.appendingPathComponent(fallback)
        }
        switch kind {
        case .zsh: return URL(fileURLWithPath: vars["ZDOTDIR"] ?? home.path).appendingPathComponent(".zshrc")
        case .bash: return first([".bash_profile", ".bashrc"], else: ".bash_profile")  // macOS terminals start login shells

        case .fish: return home.appendingPathComponent(".config/fish/conf.d/sessionhopper.fish")
        case .tcsh: return first([".tcshrc", ".cshrc"], else: ".cshrc")  // tcsh reads .tcshrc, else .cshrc
        }
    }

    public static func aliasLine(_ kind: ShellKind, cli: String) -> String {
        let q = FileIO.shellQuote(cli)
        return (kind == .zsh || kind == .bash ? "alias claude=\"\(q) shim\"" : "alias claude \"\(q) shim\"") + "  \(marker)"
    }

    /// An existing `claude` alias or function the user wrote (ours is marked) would clash.
    public static func foreignClaude(in text: String) -> String? {
        text.split(separator: "\n").map(String.init).first { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), !t.contains(marker) else { return false }
            return t.range(of: #"^(alias\s+claude[\s=]|claude\s*\(\)|function\s+claude\b)"#, options: .regularExpression) != nil
        }
    }

    public static func shellInstalled(_ kind: ShellKind, home: URL, vars: [String: String]) -> Bool {
        FileIO.readString(rcFile(kind, home: home, vars: vars).resolvingSymlinksInPath())?.contains(marker) ?? false
    }

    /// Adds the one marked alias line (after a backup). A symlinked rc file (dotfiles) is edited at its target.
    public static func installShell(_ kind: ShellKind, cli: String, home: URL, vars: [String: String], force: Bool = false) throws -> String {
        let rc = rcFile(kind, home: home, vars: vars).resolvingSymlinksInPath()
        let text = FileIO.readString(rc) ?? ""
        if text.contains(marker) { return "already in \(rc.path)" }
        if !force, let clash = foreignClaude(in: text) {
            throw HopperError("\(rc.path) already defines claude (\(clash.trimmingCharacters(in: .whitespaces))). Remove it, or add the line yourself: \(aliasLine(kind, cli: cli))")
        }
        if FileManager.default.fileExists(atPath: rc.path) {
            try? FileManager.default.removeItem(at: rc.appendingPathExtension("ash-backup"))
            try FileManager.default.copyItem(at: rc, to: rc.appendingPathExtension("ash-backup"))
        }
        try FileManager.default.createDirectory(at: rc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileIO.write(text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + aliasLine(kind, cli: cli) + "\n", to: rc)
        return "added to \(rc.path) (open a new terminal tab)"
    }

    /// Removes exactly the marked lines.
    public static func removeShell(_ kind: ShellKind, home: URL, vars: [String: String]) throws -> String {
        let rc = rcFile(kind, home: home, vars: vars).resolvingSymlinksInPath()
        guard let text = FileIO.readString(rc), text.contains(marker) else { return "nothing to remove in \(rc.path)" }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(marker) }.joined(separator: "\n")
        if kind == .fish, kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.removeItem(at: rc)
        } else {
            try FileIO.write(kept, to: rc)
        }
        return "removed from \(rc.path)"
    }

    // MARK: - The shim link for tools that take one Claude binary path

    public static func shimLink(home: URL) -> URL { home.appendingPathComponent(".local/bin/sessionhopper-shim") }

    public static func linkShim(cli: String, home: URL) throws -> String {
        let link = shimLink(home: home)
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if dest == cli { return "already linked: \(link.path)" }
            try fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            throw HopperError("\(link.path) exists and is not a link; left alone")
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: cli)
        return "linked \(link.path). Use it as the Claude binary path in cmux or JetBrains."
    }

    // MARK: - The Claude skill (plugin) in every profile

    public static let marketplace = "roypadina/padina-claude-code-plugins"
    public static let plugin = "agents-session-hopper@padina"

    /// Installed per `claude plugin list --json` (documented CLI). nil = claude not found or the list failed.
    public static func pluginInstalled(_ profile: Profile, env: HopperEnvironment) -> Bool? {
        guard let claude = Claude.locate(env) else { return nil }
        let r = Shell.run(claude, ["plugin", "list", "--json"], timeout: 30, env: Profiles.environment(for: profile, base: env.vars))
        guard r.status == 0 else { return nil }
        return r.stdout.contains("\"\(plugin)\"")
    }

    /// Runs the unmodified `claude plugin marketplace add` + `claude plugin install` for this profile.
    /// The download is done by `claude`, not by AgentsSessionHopper.
    public static func installPlugin(_ profile: Profile, env: HopperEnvironment) throws -> String {
        guard let claude = Claude.locate(env) else { throw HopperError("claude not found") }
        let e = Profiles.environment(for: profile, base: env.vars)
        // Through sh for `2>&1`: Shell keeps stdout only, and the reason a step failed is on stderr.
        let cli = FileIO.shellQuote(claude)
        let add = Shell.run("exec \(cli) plugin marketplace add \(marketplace) 2>&1", timeout: 120, env: e)
        if add.status != 0, !add.stdout.lowercased().contains("already") {
            throw HopperError("\(profile.name): marketplace add failed: \(add.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        let inst = Shell.run("exec \(cli) plugin install \(plugin) --scope user 2>&1", timeout: 120, env: e)
        guard inst.status == 0 else {
            throw HopperError("\(profile.name): plugin install failed: \(inst.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        return "\(profile.name): \(plugin) installed"
    }
}
