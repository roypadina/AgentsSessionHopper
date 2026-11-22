import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Shared MCP logins: opted-in Claude profiles that run on their own `claude setup-token` keep their MCP OAuth
/// logins (Atlassian, Slack, Notion, …) in ONE store, so each MCP server is logged in once for all of them.
///
/// Claude Code keeps the account login (`claudeAiOauth`) and the MCP logins (`mcpOAuth`) in one secure-storage
/// object: `<dir>/.credentials.json` on Linux, a Keychain item on macOS. The undocumented
/// `CLAUDE_SECURESTORAGE_CONFIG_DIR` moves that object away from `CLAUDE_CONFIG_DIR` (anthropics/claude-code#79223;
/// on macOS the Keychain service becomes `Claude Code-credentials-<sha256(dir)[:8]>`). The account then comes only
/// from `CLAUDE_CODE_OAUTH_TOKEN`, which wins over a stored login, so each profile stays on its own account.
/// `/login` would write an account login into the shared store and `/logout` deletes the whole store, so both
/// are turned off for these sessions, and `guardStore` repairs the store if either happened anyway.
public enum McpShare {
    public static let envVar = "CLAUDE_SECURESTORAGE_CONFIG_DIR"
    public static let defaultStore = "~/.claude-mcp-store"
    static let accountKey = "claudeAiOauth"
    static let mcpKey = "mcpOAuth"

    /// The shared store folder (`HopperConfig.mcpStore`, default `~/.claude-mcp-store`). Claude Code hashes this
    /// exact string for the Keychain name, so it is always the same absolute path with no trailing slash.
    public static func store(_ config: HopperConfig, env: HopperEnvironment) -> String {
        let raw = config.mcpStore ?? defaultStore
        let path = raw == "~" || raw.hasPrefix("~/") ? env.home.path + raw.dropFirst(1) : raw
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The profile's `claude` gets a Claude account token: its own stored setup-token, or the caller's for the first profile.
    public static func hasToken(_ p: Profile, env: HopperEnvironment) -> Bool {
        var e = env.vars
        Gateway.applyClaudeToken(&e, p, env: env, share: false)
        return !(e["CLAUDE_CODE_OAUTH_TOKEN"] ?? "").isEmpty
    }

    /// Called after the profile's token is set (`Gateway.applyClaudeToken`). Shares the store only for an opted-in
    /// Claude profile that runs on a token: without one, the account login itself would land in the shared store.
    /// A store the guard cannot check (locked, symlinked) is not used: the profile then runs on its own store.
    static func apply(_ e: inout [String: String], _ p: Profile, env: HopperEnvironment) {
        guard p.mcpShare == true, !p.isGateway, !(e["CLAUDE_CODE_OAUTH_TOKEN"] ?? "").isEmpty else { return }
        let dir = store(HopperConfig.load(env.paths), env: env)
        guard (try? guardStore(dir, env: env)) != nil else { return }
        e[envVar] = dir
        e["DISABLE_LOGIN_COMMAND"] = "1"
        e["DISABLE_LOGOUT_COMMAND"] = "1"
    }

    /// This process runs inside a session that uses the shared store (set by `apply`, inherited by hooks and tools).
    public static func inSharedSession(_ env: HopperEnvironment) -> Bool {
        guard let d = env.vars[envVar], !d.isEmpty else { return false }
        return d == store(HopperConfig.load(env.paths), env: env)
    }

    /// SessionStart / Stop hooks: repairs the store after a `/logout` or `/login` that got through anyway.
    static func guardIfShared(_ env: HopperEnvironment) {
        if inSharedSession(env), let d = env.vars[envVar] { _ = try? guardStore(d, env: env) }
    }

    /// `mcp status` / `doctor`: per Claude profile whether it shares, then the store (names only).
    public static func statusLines(_ config: HopperConfig, env: HopperEnvironment) -> [String] {
        var lines = config.profiles.filter { !$0.isGateway }.map { p -> String in
            guard p.mcpShare == true else { return "\(p.name): own MCP logins" }
            return hasToken(p, env: env) ? "\(p.name): shares MCP logins (runs on its setup-token; /login and /logout are off)"
                : "\(p.name): share is on, but it has no setup-token, so it keeps its own MCP logins. Run: sessionhopper login \(p.name) --token"
        }
        if config.profiles.contains(where: { $0.mcpShare == true }) {
            lines += describe(store(config, env: env), env: env)
            lines.append("(MCP logins a profile made before it shared stay in its own store: log in once more with /mcp in a shared session)")
        }
        return lines
    }

    #if os(macOS)
    /// `login --token`: drops a Keychain item Claude Code may have made for the throwaway folder.
    public static func forgetThrowaway(_ dir: String, env: HopperEnvironment) {
        KeychainStore.remove(dir: dir, user: env.vars["USER"] ?? NSUserName())
    }
    #endif

    // MARK: - Store guard

    enum Contents {
        case missing, invalid, object([String: Any])
        var isMissing: Bool { if case .missing = self { return true }; return false }
        var data: Data? { if case .object(let o) = self { return try? McpShare.json(o) }; return nil }
    }

    static func sameJSON(_ a: Data?, _ b: Data?) -> Bool {
        guard let x = FileIO.jsonObject(a), let y = FileIO.jsonObject(b) else { return a == b }
        return NSDictionary(dictionary: x).isEqual(to: y)
    }

    struct Outcome {
        /// New store contents to write, nil = unchanged.
        var store: [String: Any]?
        /// New backup to write, nil = unchanged.
        var backup: [String: Any]?
        var notes: [String] = []
    }

    /// What the guard does, as a pure function. Tests key names only; values are carried, never shown.
    /// - an account login in the store → removed (accounts come from tokens only)
    /// - MCP logins present → backed up (`{mcpOAuth}` only)
    /// - store deleted (`/logout`) or its MCP logins gone → restored from that backup
    /// - not valid JSON → left alone
    static func plan(_ current: Contents, backup: [String: Any]?) -> Outcome {
        var out = Outcome()
        var obj: [String: Any]
        switch current {
        case .invalid: out.notes.append("the shared MCP store is not valid JSON; left alone"); return out
        case .missing: obj = [:]
        case .object(let o): obj = o
        }
        var changed = false
        if obj.removeValue(forKey: accountKey) != nil {
            changed = true
            out.notes.append("removed an account login from the shared MCP store")
        }
        let saved = backup?[mcpKey] as? [String: Any] ?? [:]
        if let mcp = obj[mcpKey] as? [String: Any], !mcp.isEmpty {
            if !NSDictionary(dictionary: saved).isEqual(to: mcp) { out.backup = [mcpKey: mcp] }
        } else if !saved.isEmpty, current.isMissing || changed {
            // Deleted (`/logout`) or rewritten by a login: put the MCP logins back.
            obj[mcpKey] = saved
            changed = true
            out.notes.append("restored MCP logins from the backup")
        } else if !saved.isEmpty {
            // The user logged out of the last MCP server themselves: forget it, don't bring it back.
            out.backup = [mcpKey: [String: Any]()]
        }
        if changed { out.store = obj }
        return out
    }

    /// Runs `plan` on the store in `dir` under a lock (Claude Code sessions on several profiles share it).
    /// Throws when the store cannot be checked: the caller then does not use it.
    @discardableResult
    public static func guardStore(_ dir: String, env: HopperEnvironment) throws -> [String] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        let lock = open(dir + "/.guard.lock", O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { throw HopperError("cannot open \(dir)/.guard.lock") }
        defer { close(lock) }
        var tries = 0
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            tries += 1
            guard tries < 100 else { throw HopperError("the shared MCP store is locked by another process") }
            usleep(100_000)
        }
        let b = backend(dir, env: env)
        let before = try b.read()
        let out = plan(before, backup: b.readBackup())
        // Claude Code doesn't take our lock: if it wrote meanwhile (an MCP token refresh), leave its write; the next run retries.
        if let s = out.store, sameJSON(try b.read().data, before.data) { try b.write(s) }
        if let k = out.backup { try b.writeBackup(k) }
        return out.notes
    }

    /// Key names and MCP server names in the store, for `mcp status` and `doctor`. Never a value.
    public static func describe(_ dir: String, env: HopperEnvironment) -> [String] {
        let b = backend(dir, env: env)
        var lines = ["store \(env.tilde(dir)) (\(b.name))"]
        switch Result(catching: { try b.read() }) {
        case .failure(let e): lines.append("cannot read it: \(e)")
        case .success(.missing): lines.append("empty: no MCP logins yet (log in once with /mcp in a shared session)")
        case .success(.invalid): lines.append("not valid JSON: left alone")
        case .success(.object(let o)):
            lines.append("keys: " + (o.keys.sorted().joined(separator: ", ").nilIfEmpty ?? "none")
                         + (o[accountKey] != nil ? "  (an account login: removed at the next launch)" : ""))
            lines.append("MCP logins: " + (servers(o).joined(separator: ", ").nilIfEmpty ?? "none"))
        }
        lines.append("backup of the MCP logins: " + (b.readBackup().map { servers($0).joined(separator: ", ").nilIfEmpty ?? "empty" } ?? "none yet"))
        return lines
    }

    /// `mcpOAuth` keys are `<server>|<hash of its type, url and headers>`.
    static func servers(_ obj: [String: Any]) -> [String] {
        Array(Set(((obj[mcpKey] as? [String: Any]) ?? [:]).keys.map { String($0.split(separator: "|", maxSplits: 1).first ?? "") })).sorted()
    }

    // MARK: - Backends

    /// Where Claude Code keeps the store for `dir`: a file on Linux, a Keychain item on macOS.
    /// `SESSIONHOPPER_MCP_BACKEND=file` forces the file (tests never touch the Keychain).
    static func backend(_ dir: String, env: HopperEnvironment) -> StoreBackend {
        #if os(macOS)
        if env.vars["SESSIONHOPPER_MCP_BACKEND"] != "file" { return KeychainStore(dir: dir, user: env.vars["USER"] ?? NSUserName()) }
        #endif
        return FileStore(dir: dir)
    }

    static func parse(_ data: Data?) -> Contents {
        guard let data, !data.isEmpty else { return .missing }
        return FileIO.jsonObject(data).map(Contents.object) ?? .invalid
    }

    static func json(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

protocol StoreBackend {
    var name: String { get }
    func read() throws -> McpShare.Contents
    func write(_ obj: [String: Any]) throws
    func readBackup() -> [String: Any]?
    func writeBackup(_ obj: [String: Any]) throws
}

/// Linux: `<dir>/.credentials.json`, which Claude Code opens with O_NOFOLLOW. Backup `<dir>/mcp-backup.json`, 0600.
struct FileStore: StoreBackend {
    let dir: String
    var name: String { "file" }
    var file: String { dir + "/.credentials.json" }
    var backup: String { dir + "/mcp-backup.json" }

    func read() throws -> McpShare.Contents {
        var st = stat()
        guard lstat(file, &st) == 0 else { return .missing }
        guard st.st_mode & S_IFMT != S_IFLNK else { throw HopperError("\(file) is a symlink; refusing to use it") }
        return McpShare.parse(FileIO.read(URL(fileURLWithPath: file)))
    }
    func write(_ obj: [String: Any]) throws { try Gateway.writePrivate(McpShare.json(obj), to: URL(fileURLWithPath: file)) }
    func readBackup() -> [String: Any]? { FileIO.jsonObject(FileIO.read(URL(fileURLWithPath: backup))) }
    func writeBackup(_ obj: [String: Any]) throws { try Gateway.writePrivate(McpShare.json(obj), to: URL(fileURLWithPath: backup)) }
}

#if os(macOS)
/// macOS: the Keychain item Claude Code uses for `dir`, read and written with `/usr/bin/security` the way Claude Code
/// does (so its access list keeps letting `claude` in). The backup is our own Keychain item
/// (service `agents-session-hopper`, account `.mcp-backup`): MCP tokens never land in a plain file here.
struct KeychainStore: StoreBackend {
    let dir: String
    let user: String
    var name: String { "Keychain item \(service)" }
    var service: String { Self.service(for: dir) }
    static let backupAccount = ".mcp-backup"

    /// `Claude Code-credentials-<first 8 hex of sha256(NFC dir)>`, as Claude Code 2.1.3xx names it.
    static func service(for dir: String) -> String {
        let hash = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash.prefix(8)
    }

    func read() throws -> McpShare.Contents {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-a", user, "-w", "-s", service], timeout: 15)
        if r.status == 44 { return .missing }
        guard r.status == 0 else { throw HopperError("cannot read the Keychain item \(service) (security exit \(r.status))") }
        return McpShare.parse(Self.decode(r.stdout))
    }
    func write(_ obj: [String: Any]) throws { try Self.add(account: user, service: service, data: McpShare.json(obj)) }
    func readBackup() -> [String: Any]? {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-a", Self.backupAccount, "-w", "-s", Gateway.keychainService], timeout: 15)
        return r.status == 0 ? FileIO.jsonObject(Self.decode(r.stdout)) : nil
    }
    func writeBackup(_ obj: [String: Any]) throws { try Self.add(account: Self.backupAccount, service: Gateway.keychainService, data: McpShare.json(obj)) }

    /// `security -w` prints the secret as text, or as hex when it holds bytes it won't print.
    static func decode(_ out: String) -> Data {
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.hasPrefix("{"), s.count % 2 == 0, s.allSatisfy(\.isHexDigit) else { return Data(s.utf8) }
        var d = Data(), i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return d
    }

    /// `security -i` reads the command from stdin, so the secret is never on a command line (`ps`). It cuts a line
    /// at about 4 KB, so a longer one goes on argv for the moment it runs, as Claude Code does. Read back after.
    static func add(account: String, service: String, data: Data) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let r = line.utf8.count < 4000
            ? Shell.run("/usr/bin/security", ["-i"], stdin: Data(line.utf8), timeout: 15)
            : Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex], timeout: 15)
        guard r.status == 0 else { throw HopperError("could not write the Keychain item \(service) (security exit \(r.status))") }
        let back = Shell.run("/usr/bin/security", ["find-generic-password", "-a", account, "-w", "-s", service], timeout: 15)
        guard back.status == 0, McpShare.sameJSON(decode(back.stdout), data) else {
            throw HopperError("the Keychain item \(service) did not read back as written")
        }
    }

    /// Removes the item Claude Code may leave for a throwaway folder (`login --token`).
    static func remove(dir: String, user: String) {
        _ = Shell.run("/usr/bin/security", ["delete-generic-password", "-a", user, "-s", service(for: dir)], timeout: 15)
    }
}
#endif

/// A `claude setup-token` token as pasted. The terminal wraps the ~108 characters over two or more lines, so a
/// one-line read keeps only part of it (a 78-character token gets a 401).
public enum SetupToken {
    public static let prefix = "sk-ant-oat01-"

    /// Joins every pasted line and drops all whitespace, then checks prefix, length and characters.
    public static func parse(_ pasted: String) throws -> String {
        let t = String(pasted.filter { !$0.isWhitespace })
        guard t.hasPrefix(prefix) else { throw HopperError("that does not look like a setup-token (\(prefix)…). Nothing stored.") }
        guard t.count >= 100 else { throw HopperError("the token is only \(t.count) characters: the paste was cut off (a full one is about 108). Nothing stored.") }
        guard t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw HopperError("the token has unexpected characters. Nothing stored.")
        }
        return t
    }

    /// Two profiles whose windows reset at the same moments with the same usage are almost surely one account:
    /// a setup-token made while the browser was signed in to another account works, but bills that one.
    /// Claude Code shows no email for a token login, so usage is the only sign. Needs both windows on both.
    public static func sameAccount(_ a: ProfileLimits, _ b: ProfileLimits) -> Bool {
        guard let a5 = a.fiveHour, let b5 = b.fiveHour, let a7 = a.sevenDay, let b7 = b.sevenDay,
              let r5a = a5.resetsAt, let r5b = b5.resetsAt, let r7a = a7.resetsAt, let r7b = b7.resetsAt else { return false }
        return abs(r5a - r5b) < 1 && abs(r7a - r7b) < 1 && a5.usedPercentage == b5.usedPercentage && a7.usedPercentage == b7.usedPercentage
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
