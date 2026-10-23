import Foundation

/// How the unmodified `claude` is started for a supervised session. Pure functions, unit-tested.
public enum LaunchPlan {
    /// Hook events the engine listens to (https://code.claude.com/docs/en/hooks).
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "StopFailure"]

    /// Passed with `--settings`, which ranks above user, project and local settings for this session only
    /// and writes no file; hook arrays merge with the user's own hooks instead of replacing them
    /// (https://code.claude.com/docs/en/settings, "Settings precedence"). Our status line replaces the
    /// user's for the session and runs theirs itself (see `StatusLineBridge`).
    /// `caller`: settings passed to us with `--settings` (see `extractSettings`); merged in, not passed twice.
    public static func settingsJSON(selfPath: String, userStatusLine: [String: Any]?, caller: [String: Any]? = nil) -> String {
        let bin = FileIO.shellQuote(selfPath)
        var obj = caller ?? [:]
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        for ev in hookEvents {
            hooks[ev] = (hooks[ev] as? [Any] ?? []) + [["hooks": [["type": "command", "command": "\(bin) hook", "timeout": 10]]]]
        }
        var statusLine: [String: Any] = ["type": "command", "command": "\(bin) statusline"]
        for key in ["padding", "refreshInterval", "hideVimModeIndicator"] { statusLine[key] = userStatusLine?[key] }
        obj["hooks"] = hooks
        // shortcut: a caller's own statusLine is replaced, not chained; chain it if a tool ever sends one.
        obj["statusLine"] = statusLine
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Takes `--settings <json or file>` out of the caller's args. Claude Code reads only one of several
    /// `--settings` flags (which one changed across versions), so ours absorbs theirs: cmux passes its
    /// hooks this way. A value that is neither a JSON object nor a readable JSON file stays in the args.
    public static func extractSettings(_ args: [String]) -> (args: [String], settings: [String: Any]?) {
        var rest: [String] = []
        var merged: [String: Any]?
        var i = 0
        while i < args.count {
            var value: String?
            if args[i] == "--settings", i + 1 < args.count { value = args[i + 1] }
            else if args[i].hasPrefix("--settings=") { value = String(args[i].dropFirst("--settings=".count)) }
            let obj = value.flatMap { v in FileIO.jsonObject(Data(v.utf8)) ?? FileIO.jsonObject(FileIO.read(URL(fileURLWithPath: (v as NSString).expandingTildeInPath))) }
            guard let obj else { rest.append(args[i]); i += 1; continue }
            var m = merged ?? [:]
            var hooks = m["hooks"] as? [String: Any] ?? [:]
            for (ev, list) in obj["hooks"] as? [String: Any] ?? [:] { hooks[ev] = (hooks[ev] as? [Any] ?? []) + (list as? [Any] ?? []) }
            m.merge(obj) { _, new in new }
            if !hooks.isEmpty { m["hooks"] = hooks }
            merged = m
            i += args[i] == "--settings" ? 2 : 1
        }
        return (rest, merged)
    }

    /// A trailing positional is the first prompt (`sessionhopper "fix the tests"`). It belongs to the first
    /// launch only: a relaunch resumes the conversation, so sending it again would replay the task.
    // shortcut: a flag value at the end (`--model opus`) is kept unless it has spaces;
    // `--some-bool-flag word` would keep the prompt. Upgrade to a flag table if that bites.
    public static func relaunchArgs(_ args: [String]) -> [String] {
        guard let last = args.last, !last.hasPrefix("-") else { return args }
        let prev = args.count > 1 ? args[args.count - 2] : ""
        return (!prev.hasPrefix("-") || last.contains(where: \.isWhitespace)) ? Array(args.dropLast()) : args
    }

    /// Variables Claude Code sets for its own child processes. Cleared so a session started from inside
    /// another Claude Code session behaves like one started from a plain terminal.
    public static let scrubbed = [
        "CLAUDECODE", "CLAUDE_CODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_PARENT_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SSE_PORT"
    ]

    public static func childEnvironment(base: [String: String], profile: Profile, sessionID: String,
                                        env: HopperEnvironment, userStatusCommand: String?) -> [String: String] {
        var e = Profiles.environment(for: profile, base: base)
        for k in scrubbed { e[k] = nil }
        e["SESSIONHOPPER_SESSION_ID"] = sessionID
        e["SESSIONHOPPER_PROFILE"] = profile.name
        e["SESSIONHOPPER_STATE_DIR"] = env.paths.root.path
        e["SESSIONHOPPER_BIN"] = env.selfPath
        e["SESSIONHOPPER_USER_STATUSLINE"] = userStatusCommand
        return e
    }

    /// Sent only when a move cut work off (or the last turn died on an error). An idle session resumes
    /// with no prompt, so no turn runs.
    public static func continuePrompt(jobs: [String], limitStop: Bool) -> String {
        var s = limitStop
            ? "[sessionhopper] The last turn stopped on a usage limit. The user moved this conversation to another of their Claude accounts so the work can go on."
            : "[sessionhopper] This conversation was moved to another of the user's Claude accounts. The move restarted Claude Code in the middle of your work, so everything that was running stopped with it."
        if !jobs.isEmpty { s += "\n\nBackground jobs that were still running:\n" + jobs.map { "- \($0)" }.joined(separator: "\n") }
        s += """


            Do this, in order:
            1. Re-read the end of the conversation to find exactly where you stopped.
            2. Redo the interrupted step, and restart every subagent and background job that had not finished.
            3. Carry on with the original work.
            Reply with one status line: what you restarted and what you are continuing. Only the account changed; do not ask whether to continue.
            """
        return s
    }
}
