# CLI reference

```
sessionhopper [claude args...]            start a session on the first profile with room
sessionhopper -P work [claude args...]    start on "work" (others stay fallbacks); --only work = strict
sessionhopper --resume <id|name> | -c     adopt an existing session (bare --resume: numbered picker)
sessionhopper sessions [n|all] [--all-dirs]  resumable sessions here (or everywhere), with names
sessionhopper switch [profile] [--now]    move this session at turn end (--session <id> from outside)
sessionhopper hold on|off [--all]         never park or auto-move this session (or every session)
sessionhopper status [--json]             profiles, last-known usage, live sessions
sessionhopper profiles [list|import|add <name> [--dir D] [--no-share] [--no-login]
                        |remove <name>|order a,b,c|export-config-dir <name> on|off]
sessionhopper login <profile>             run `claude auth login` for that profile
sessionhopper config [suggest N|park-at N|park on|off|auto-move on|off|move-now on|off]
sessionhopper config prompt [--file F | --reset]  the prompt a cut-off session resumes with
sessionhopper version | --version | -v    this tool's version (does not start claude)
sessionhopper log [-n 20] [--json]        the switch log
sessionhopper doctor                      check claude (2.1.145+), logins, shared history, thresholds,
                                          sessions running without sessionhopper
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
- A bare `--resume` in a terminal is a numbered picker, 10 rows a page (`m` for more, Enter cancels);
  piped or scripted, it prints the list. `--resume "<name>"` takes the name `/resume` shows.
- `config move-now on` (needs `auto-move on`): past the park threshold the move or park happens at
  once, even mid-turn, instead of at the turn end. The cut-off turn is resumed with a note of what was
  interrupted. Held sessions are never cut into.
- `hold` keeps a session on its profile: no park, no automatic move. A move you confirm still happens.
- `install-hooks` edits one profile's `settings.json` (with a backup) so sessions started with plain
  `claude` also report usage and limit stops. Optional; `uninstall-hooks` restores your status line.
- `profiles remove` only removes the entry from the list; the folder and its login stay.
- `config prompt` prints the continue prompt in use. `--file F` sets your own (placeholders `{reason}`
  why it stopped, `{jobs}` and `{crons}` with their own headings or empty, `{from}` and `{to}` profile
  names); `[sessionhopper] ` is always put in front. An empty file or `--reset` restores the built-in one.
