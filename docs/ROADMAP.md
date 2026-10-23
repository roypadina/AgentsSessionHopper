# Roadmap to v0.1.0

## Done

**M0: scaffold.** SwiftPM package (macOS 14): `SessionHopperCore` (engine), `sessionhopper` (CLI),
`AgentsSessionHopper` (menu-bar app). CI (build + test on macos-latest, packages the app), MIT license,
community files, universal ad-hoc/self-signed packaging (`Scripts/package_app.sh`, CLI in `Contents/Helpers/`).

**M1: engine + CLI.**
- Profiles: discovery (`~/.claude`, `~/.claude-*`, `~/.claudeN`), import, add (links `projects/` and
  optionally CLAUDE.md/agents/commands/skills, copies settings.json, never overwrites), remove, order,
  per-profile `CLAUDE_CONFIG_DIR` export flag (unset for `~/.claude` by default), `login` (runs the
  unmodified `claude auth login`).
- Supervisor: start (`--session-id`), adopt (`--resume <id>`, `-c`), follow the session's folder, refuse
  a live session, posix_spawn in the same process group, SIGINT/SIGQUIT ignored, SIGTERM/SIGHUP forwarded,
  relaunch with `--resume` under the next profile, first prompt never replayed, continuation prompt only
  when work was cut off or a limit stop is resumed.
- Status-line bridge: records `rate_limits.five_hour/seven_day` per profile, chains the user's own status
  line (stdin passthrough, 5 s timeout, keeps padding/refreshInterval).
- Hooks: SessionStart (`/clear` follow), UserPromptSubmit / PostToolUse (busy + one-time messages),
  Stop (`background_tasks`), StopFailure (`error == "rate_limit"`). Ignores other conversations.
- Policy: suggest at 85% (default, confirm), opt-in move without asking, park before paid usage at 97%
  (default on), hold per session / all. Limit stop asks (or moves when opted in), never parks.
- Switch log `events.jsonl` (schema v1) in `~/Library/Application Support/AgentsSessionHopper/`.
- `doctor`, `status [--json]`, `log`, `config`, `sessions`, `switch [--now]`, `hold`.
- `install-hooks` / `uninstall-hooks --profile X`: explicit, idempotent, backup before every write,
  restores the user's status line.
- Tests: 42 unit + 22 integration (built CLI against a fake `claude` stub; no real Claude Code).

**M2: app shell.** Menu-bar icon with state (plain / needs you / past park threshold) and worst live %,
popover (profile rows with severity, confirm card with Move / Not now / Hold, sessions with Move…, recent
hand-offs), Settings (Hand-off: thresholds, move-without-asking with explanation, park, hold all;
Profiles: order; Log: table + Reveal in Finder; About), custom About window with Ko-fi.
Offscreen renders in `docs/screenshots/`.

## Done since (toward v0.1.0)

Notifications with Move / Not now / Hold actions; first-run onboarding (disclosure, detect/import,
Add Profile with shared history, login via Terminal `.command` or copied command, login state via
`claude auth status`); `shim` mode (+ `*-shim` link name) for cmux/IDEs; launch at login; General and
Command-line settings tabs; 90-day log retention; app icon + template menu-bar glyph; README landing
page; wiki drafts in `docs/wiki/`; CHANGELOG; privacy pass. Tests: 44 unit + 26 integration + 1 app.

## Left for v0.1.0 (needs Roy)

1. Approve: flip the repo public, tag `v0.1.0`, release `AgentsSessionHopper.zip`.
2. Cask `agents-session-hopper`: `app "AgentsSessionHopper.app"`,
   `binary "#{appdir}/AgentsSessionHopper.app/Contents/Helpers/sessionhopper"`, quarantine caveat,
   `zap trash: ["~/Library/Application Support/AgentsSessionHopper", "~/Library/Preferences/com.padina.agents-session-hopper.plist"]`.
3. Push `docs/wiki/` to the repo wiki (wiki exists once the repo is public), social preview, branch protection.
4. Real-world check on one spare profile (never done here: no real `claude` was run).

## Later

Interactive resume picker, session titles in `sessions`, OSC 9 notice on a limit stop, Codex (after a
terms check), "show icon only while sessions run".

## Open risks

- Shared `projects/` across config folders is not a documented Claude Code interface; a storage change
  would break moves (doctor checks; fallback: copy the transcript before resuming).
- `rate_limits` is absent for non-subscribers and before a session's first response; idle profiles are
  "unknown" and count as having room.
- Managed settings with `disableAllHooks` / `allowManagedHooksOnly` silence our hooks and status line.
- A prompt typed in the instant between the idle check and the restart can be cut off (same race as before;
  the continuation prompt covers it).
- Ad-hoc signing: quarantine also blocks the bundled CLI until cleared.
