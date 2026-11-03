import Foundation

/// Gateway profiles: the same unmodified `claude`, pointed at an Anthropic-compatible gateway (OpenRouter)
/// with the user's own API key, through Claude Code's documented variables
/// (https://code.claude.com/docs/en/llm-gateway). Billed per use, so the policy reaches for one only when
/// no subscription profile has room. The key is the user's gateway key, never a Claude login.
public enum Gateway {
    public static let openRouter = "openrouter"
    public static let openRouterURL = "https://openrouter.ai/api"
    /// macOS Keychain service; the account is the profile name.
    public static let keychainService = "agents-session-hopper"

    /// Default key file where there is no Keychain: `${XDG_CONFIG_HOME:-~/.config}/agents-session-hopper/<profile>.key`.
    public static func defaultKeyFile(_ p: Profile, env: HopperEnvironment) -> URL {
        let base = env.vars["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? env.home.appendingPathComponent(".config")
        return base.appendingPathComponent("agents-session-hopper/\(p.name).key")
    }

    /// Where the key comes from, for messages: never the key itself.
    public static func keySource(_ p: Profile, env: HopperEnvironment) -> String {
        if let f = p.keyFile { return env.tilde(expand(f)) }
        #if os(macOS)
        return "Keychain (service \(keychainService), account \(p.name))"
        #else
        if let dir = credentialsDir(env) { return "systemd credential \(dir)/\(p.name)" }
        return env.tilde(defaultKeyFile(p, env: env).path)
        #endif
    }

    /// The API key: `keyFile` when set; else the macOS Keychain; else on Linux the systemd credential
    /// `$CREDENTIALS_DIRECTORY/<profile>` (`LoadCredential=`), else the default key file.
    /// Files must be owned by this user and closed to group and others.
    public static func key(_ p: Profile, env: HopperEnvironment) throws -> String {
        if let f = p.keyFile { return try readKeyFile(expand(f)) }
        #if os(macOS)
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-a", p.name, "-w"], timeout: 10)
        let k = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !k.isEmpty else { throw HopperError("\(p.name): no API key in the Keychain. Add it: sessionhopper profiles key \(p.name) < keyfile") }
        return k
        #else
        if let dir = credentialsDir(env), FileManager.default.fileExists(atPath: "\(dir)/\(p.name)") {
            return try readKeyFile("\(dir)/\(p.name)")
        }
        return try readKeyFile(defaultKeyFile(p, env: env).path)
        #endif
    }

    /// Stores `key` where `key(_:env:)` reads it. The key never goes on a command line.
    @discardableResult
    public static func storeKey(_ key: String, for p: Profile, env: HopperEnvironment) throws -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, k.count <= 512, k.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            throw HopperError("that does not look like an API key (letters, digits, - _ . only)")
        }
        #if os(macOS)
        if p.keyFile == nil {
            // `security -i` reads the command from stdin, so the key is not visible in `ps`.
            let r = Shell.run("/usr/bin/security", ["-i"], stdin: Data("add-generic-password -U -s \(keychainService) -a \(p.name) -w \(k)\n".utf8), timeout: 15)
            guard r.status == 0 else { throw HopperError("could not write the Keychain item (security exit \(r.status))") }
            return keySource(p, env: env)
        }
        #endif
        let url = URL(fileURLWithPath: p.keyFile.map(expand) ?? defaultKeyFile(p, env: env).path)
        try writePrivate(Data((k + "\n").utf8), to: url)
        return env.tilde(url.path)
    }

    /// Variables that send this `claude` to the gateway. Set even when the caller's environment has them.
    public static func environment(_ p: Profile, key: String) -> [String: String] {
        var e = [
            "ANTHROPIC_BASE_URL": p.baseURL ?? openRouterURL,
            "ANTHROPIC_AUTH_TOKEN": key,
            "ANTHROPIC_API_KEY": "",
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
            // Claude Code before 2.1.304 turns MCP tool search off behind a gateway: every tool schema
            // then loads up front and long sessions compact over and over.
            "ENABLE_TOOL_SEARCH": "true"
        ]
        for (alias, model) in p.models ?? [:] { e["ANTHROPIC_DEFAULT_\(alias.uppercased())_MODEL"] = model }
        return e
    }

    /// `--model opus` → `--model <gateway name>` when the profile maps that alias.
    public static func modelArgs(_ args: [String], _ p: Profile) -> [String] {
        guard let map = p.models, !map.isEmpty else { return args }
        var out = args
        for i in out.indices {
            if out[i] == "--model", i + 1 < out.count, let m = map[out[i + 1]] { out[i + 1] = m }
            else if out[i].hasPrefix("--model="), let m = map[String(out[i].dropFirst(8))] { out[i] = "--model=\(m)" }
        }
        return out
    }

    /// When a spent key has credit again: the next daily / weekly (Monday) / monthly boundary, 00:00 UTC.
    /// If the guess is early, the next run fails fast on the same error and marks it again.
    public static func nextReset(_ p: Profile, now: Double) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: now)
        let parts: DateComponents
        switch p.resets ?? "daily" {
        case "weekly": parts = DateComponents(hour: 0, minute: 0, weekday: 2)
        case "monthly": parts = DateComponents(day: 1, hour: 0, minute: 0)
        default: parts = DateComponents(hour: 0, minute: 0)
        }
        return cal.nextDate(after: date, matching: parts, matchingPolicy: .nextTime)?.timeIntervalSince1970 ?? now + 86_400
    }

    /// A spent gateway key: full (the `spend` window at 100%) until `until`.
    public static func markFull(_ p: Profile, until: Double, paths: StatePaths, now: Double) {
        try? LimitStore.write(ProfileLimits(fiveHour: nil, sevenDay: nil, spendLimit: LimitWindow(usedPercentage: 100, resetsAt: until),
                                            sampledAt: now), profile: p.name, paths)
    }

    static func credentialsDir(_ env: HopperEnvironment) -> String? {
        env.vars["CREDENTIALS_DIRECTORY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func readKeyFile(_ path: String) throws -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { throw HopperError("no API key file at \(path)") }
        guard st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw HopperError("\(path) must be owned by you and private (chmod 600 \(path))")
        }
        let k = (FileIO.readString(URL(fileURLWithPath: path)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { throw HopperError("\(path) is empty") }
        return k
    }

    /// Created 0600 in a 0700 folder, then renamed into place: never readable by others, not even briefly.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url.path + ".tmp-\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw HopperError("cannot write \(tmp)") }
        let n = data.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard n == data.count, rename(tmp, url.path) == 0 else { unlink(tmp); throw HopperError("cannot write \(url.path)") }
    }
}
