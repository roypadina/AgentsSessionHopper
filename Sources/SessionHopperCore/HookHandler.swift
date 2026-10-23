import Foundation

/// `sessionhopper hook`: the command Claude Code runs on hook events (input JSON on stdin).
///
/// Supervised sessions get it through `--settings` and keep the turn state current, so a hand-off
/// lands between turns. Profiles with `install-hooks` also run it (`--profile <name>`) in sessions
/// started without `sessionhopper`; there it only records limit stops.
///
/// Events and fields used (https://code.claude.com/docs/en/hooks):
/// - common input: `hook_event_name`, `session_id`
/// - `SessionStart.source` == "clear": `/clear` started a new conversation in the same process
/// - `Stop.background_tasks[]` (`id`, `type`, `status`, `description`, `command`): work still in flight
/// - `StopFailure.error` == "rate_limit" (not `error_type`)
/// - output: top-level `systemMessage` (shown to the user) and `hookSpecificOutput.additionalContext`
///   (given to the model) on UserPromptSubmit / PostToolUse. StopFailure output is ignored by Claude Code.
public enum HookHandler {
    public static let agentNotice = """
        [sessionhopper] The user asked to continue this conversation on another of their Claude accounts. \
        The move happens when this turn ends and no background work is left, with nothing lost. Get to a \
        clean stopping point: finish the step you are on, do not start new subagents or background jobs, let \
        the ones already running finish, then end your turn. The session resumes on the other account by \
        itself. Do not mention this unless the user asks.
        """

    /// Returns what to print on stdout (nil = nothing).
    public static func handle(input: Data, env: HopperEnvironment, installedProfile: String?) -> String? {
        guard let ev = FileIO.jsonObject(input), let event = ev["hook_event_name"] as? String else { return nil }

        guard let poolID = env.currentSessionID else {
            // Unsupervised session on a profile with installed hooks: log limit stops, nothing else.
            if let profile = installedProfile, event == "StopFailure", ev["error"] as? String == "rate_limit" {
                EventLog.append(HopperEvent(type: "limit", session: ev["session_id"] as? String, cwd: ev["cwd"] as? String,
                                            from: profile, trigger: "limit", source: "hook",
                                            detail: ev["error_details"] as? String), env.paths)
            }
            return nil
        }
        // Supervised: the copy injected with --settings does the work; an installed copy stays quiet.
        if installedProfile != nil { return nil }

        let f = env.paths.session(poolID)
        let conversation = FileIO.readString(f.current) ?? poolID
        let sid = ev["session_id"] as? String
        if event == "SessionStart" {
            if ev["source"] as? String == "clear", let sid { try? FileIO.write(sid, to: f.current) }
            return nil
        }
        // A different conversation (e.g. a nested `claude` that inherited our environment) is not ours.
        if let sid, sid != conversation { return nil }

        switch event {
        case "UserPromptSubmit":
            FileIO.touch(f.busy)
            FileIO.remove(f.interrupted)
            return notice(f, event: event)
        case "PostToolUse":
            return notice(f, event: event)
        case "Stop":
            let running = (ev["background_tasks"] as? [[String: Any]] ?? [])
                .filter { ["running", "pending"].contains(($0["status"] as? String) ?? "running") }
            if running.isEmpty { FileIO.remove(f.jobs) } else { try? FileIO.write(running.map(describe).joined(), to: f.jobs) }
            FileIO.remove(f.busy)
            FileIO.remove(f.interrupted)
        case "StopFailure":
            // The turn is over either way; a limit stop also tells the supervisor to ask (or move).
            FileIO.remove(f.busy)
            FileIO.touch(f.interrupted)
            if ev["error"] as? String == "rate_limit" {
                try? FileIO.write((ev["error_details"] as? String) ?? "rate_limit", to: f.limited)
            }
        default:
            break
        }
        return nil
    }

    static func describe(_ t: [String: Any]) -> String {
        let kind = (t["type"] as? String) ?? "task"
        let what = (t["description"] as? String) ?? (t["command"] as? String) ?? (t["agent_type"] as? String) ?? ""
        let id = (t["id"] as? String) ?? ""
        let short = what.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160)
        return [kind, id, "-", String(short)].filter { !$0.isEmpty }.joined(separator: " ") + "\n"
    }

    /// One-time messages: to the agent once a move is pending, to the user once a move is suggested.
    static func notice(_ f: SessionFiles, event: String) -> String? {
        var out: [String: Any] = [:]
        if let p = FileIO.decode(PendingMove.self, from: f.pending), !FileIO.exists(f.warned) {
            FileIO.touch(f.warned)
            if p.to == PendingMove.park {
                out["systemMessage"] = "[sessionhopper] This account is past its limit threshold: the session ends when this turn ends, so it does not run into paid usage. Resume it later or on another profile."
            } else {
                out["hookSpecificOutput"] = ["hookEventName": event, "additionalContext": agentNotice]
                out["systemMessage"] = "[sessionhopper] This conversation moves to \(p.to == PendingMove.anywhere ? "the next profile with room" : p.to) when this turn ends."
            }
        } else if let s = FileIO.decode(Suggestion.self, from: f.suggest), !s.dismissed, !FileIO.exists(f.suggestShown) {
            FileIO.touch(f.suggestShown)
            out["systemMessage"] = suggestionText(s) + " To continue this conversation there when the turn ends, run: ! sessionhopper switch"
        }
        guard !out.isEmpty, let data = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func suggestionText(_ s: Suggestion) -> String {
        let pct = s.percent.map { " (\(Int($0.rounded()))%)" } ?? ""
        let head = s.reason == "limit" ? "\(s.from) hit its usage limit." : "\(s.from) is near its usage limit\(pct)."
        return "[sessionhopper] " + head + (s.to.map { " \($0) has room." } ?? "")
    }
}
