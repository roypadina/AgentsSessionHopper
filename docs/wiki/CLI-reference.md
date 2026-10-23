# CLI reference

```
sessionhopper [claude args...]            start a session on the first profile with room
sessionhopper -P work [claude args...]    start on "work" (others stay fallbacks); --only work = strict
sessionhopper --resume <id> | -c          adopt an existing session (bare --resume lists them)
sessionhopper sessions [n]                resumable sessions in this directory
sessionhopper switch [profile] [--now]    move this session at turn end (--session <id> from outside)
sessionhopper hold on|off [--all]         never park or auto-move this session (or every session)
sessionhopper status [--json]             profiles, last-known usage, live sessions
sessionhopper profiles [list|import|add <name> [--dir D] [--no-share] [--no-login]
                        |remove <name>|order a,b,c|export-config-dir <name> on|off]
sessionhopper login <profile>             run `claude auth login` for that profile
sessionhopper config [suggest N|park-at N|park on|off|auto-move on|off]
sessionhopper log [-n 20] [--json]        the switch log
sessionhopper doctor                      check claude, logins, shared history, thresholds
sessionhopper install-hooks --profile X   report usage from sessions started without sessionhopper
sessionhopper uninstall-hooks --profile X undo install-hooks
sessionhopper shim [claude args...]       for cmux/IDEs: interactive runs are supervised, the rest
                                          go straight to claude (or link the binary as *-shim)
```

Exit codes: a session returns Claude Code's own exit code; `2` means the session was parked (the
message shows how to resume it).

## Notes

- `switch` without a profile picks the next one in order with room. `--now` moves mid-turn; the
  resumed session is told what was interrupted.
- `hold` keeps a session on its profile: no park, no automatic move. A move you confirm still happens.
- `install-hooks` edits one profile's `settings.json` (with a backup) so sessions started with plain
  `claude` also report usage and limit stops. Optional; `uninstall-hooks` restores your status line.
- `profiles remove` only removes the entry from the list; the folder and its login stay.
