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

## Next, to v0.1.0

1. **M2 finish:** notifications with "Move at turn end" action (UNUserNotificationCenter), launch at
   login, menu-bar label setting, 90-day log retention, Command-line tab (CLI path, shell snippet; the
   app never edits rc files).
2. **M3 onboarding:** first-run disclosure sheet, profile detection/import in the app, Add profile
   (folder + shared items + login command / "Open in Terminal" via a `.command` file), logged-in state via
   `claude auth status`, "history not shared" fix-up steps.
3. **Engine follow-ups:** `shim` mode for cmux/IDE "Claude binary path" (non-interactive calls pass
   straight to `claude`), interactive resume picker, session titles in `sessions`, optional OSC 9
   `terminalSequence` notice on a limit stop.
4. **M4 public package:** app + menu-bar icons, README screenshots pass, wiki, CHANGELOG, social preview,
   privacy check, flip repo public, `v0.1.0` release, cask `agents-session-hopper` with
   `binary "#{appdir}/AgentsSessionHopper.app/Contents/Helpers/sessionhopper"`.
5. **Soak:** side by side with Roy's existing setup, then cut-over.

## Open risks

- Shared `projects/` across config folders is not a documented Claude Code interface; a storage change
  would break moves (doctor checks; fallback: copy the transcript before resuming).
- `rate_limits` is absent for non-subscribers and before a session's first response; idle profiles are
  "unknown" and count as having room.
- Managed settings with `disableAllHooks` / `allowManagedHooksOnly` silence our hooks and status line.
- A prompt typed in the instant between the idle check and the restart can be cut off (same race as before;
  the continuation prompt covers it).
- Ad-hoc signing: quarantine also blocks the bundled CLI until cleared.
