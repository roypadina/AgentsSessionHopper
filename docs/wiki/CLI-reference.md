# CLI reference

```
sessionhopper [claude args...]            start a session on the first profile with room
sessionhopper -P work [claude args...]    start on "work" (others stay fallbacks); --only work = strict
sessionhopper --resume <id|name> | -c     adopt an existing session (bare --resume: numbered picker;
                                          a unique start of an id works too, 4+ characters)
sessionhopper run [-P a,b] [--only] -- <claude -p args>  one non-interactive run (bots, services): the
                                          prompt on stdin; a limit failure retries the turn on the next profile
sessionhopper sessions [n|all] [--all-dirs]  resumable sessions here (or everywhere), with names
sessionhopper switch [profile] [--now]    move this session at turn end (--session <id> from outside)
sessionhopper switch --cancel             drop this session's pending move (--session <id> from outside)
sessionhopper switch <profile> --all [--now]  move every live session there (at turn end unless --now)
sessionhopper hold on|off [--all]         never park or auto-move this session (or every session)
sessionhopper status [--json]             profiles (with login email), last-known usage, live sessions
sessionhopper refresh [profile...] [--stale]  fresh usage now: one tiny haiku `claude -p` per profile
                                        (--stale: only profiles with no sample in 6 h; the app does this by itself)
sessionhopper profiles [list|import|add <name> [--dir D] [--no-share] [--no-login]
                        |remove <name>|order a,b,c|export-config-dir <name> on|off]
sessionhopper profiles share <name> [--dry-run]  link history, task lists, /rewind and setup to the first profile
                                          and the live-session list (messaging across accounts)
sessionhopper profiles label <name> <text>|--clear  display name shown in the app, `status` and `profiles list`
                                          (the name used by aliases and -P never changes)
sessionhopper profiles priority <name> <n>|default  lower is preferred (Claude 1, API keys 10); equal priorities
                                          don't trade places before a limit; a freed-up better one is moved back to
sessionhopper profiles add <name> --openrouter [--model opus=anthropic/claude-opus-5 ...] [--key-file F]
                                          [--resets daily|weekly|monthly]  pay-per-use fallback on your OpenRouter key
sessionhopper profiles add <name> --anthropic [--key-file F] [--resets ...]  billed to a Claude Console API key
sessionhopper profiles add <name> --gateway <url> [--model opus=<name> ...] [--key-file F] [--resets ...]
                                          any Anthropic-compatible gateway (e.g. LiteLLM in front of an OpenAI key)
sessionhopper profiles key <name> < file  store that profile's secret: its API key, or for a Claude profile on a
                                          server a `claude setup-token` (Keychain on macOS, private file on Linux)
sessionhopper login <profile>             run `claude auth login` for that profile
sessionhopper login <profile> --token     make a `claude setup-token` for it in a throwaway folder, paste it
                                          (several lines are fine), check it works and is not another profile's account
sessionhopper mcp share on|off <profile...>  share one MCP login store between profiles that run on a
                                          setup-token; /login and /logout are off there (see Shared MCP logins)
sessionhopper mcp status | mcp store <dir>|default  which profiles share, what the store holds (names only)
sessionhopper alerts [status]             which alerts go where: Mac notification and/or ntfy, per profile
sessionhopper alerts set <profile|all> <switch|no-room|usage-warning|usage-critical|all> [mac on|off]
                        [ntfy on|off] [active-only on|off]
sessionhopper alerts ntfy <server url> <topic> | ntfy off | ntfy token < file
sessionhopper alerts test | alerts log [-n 20]
sessionhopper shell [install|remove|status] [--shell zsh|bash|fish|tcsh] [--force]
                                          one marked `alias claude=… shim` line in your shell's startup file
sessionhopper shell link-shim             ~/.local/bin/sessionhopper-shim for cmux / JetBrains
sessionhopper plugin [install|status] [--profile X]  the agents-session-hopper skill in every profile
sessionhopper config [suggest N|park-at N|park on|off|auto-move on|off|move-now on|off|wait on|off
                      |gateway last|order|manual|on-switch "<command>"|off]  when API-key profiles are used
                      (default: last); a command run on every move, limit stop and park
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

Exit codes: a session returns Claude Code's own exit code; `2` means the session was parked and no
reset time was known to wait for (the message shows how to resume it). `run` returns `75` when no
profile can take the turn (see [Servers, bots and OpenRouter](Servers-bots-and-OpenRouter)).
When a session ends, a session summary (name, about, recent prompts, status, dates, folder, resume
command) follows Claude Code's own resume hint: see [How it works](How-it-works#when-a-session-ends).

## Notes

- `switch` without a profile picks the next one in order with room. `--now` moves mid-turn; the
  resumed session is told what was interrupted.
- A bare `--resume` in a terminal is a numbered picker, 10 rows a page (`m` for more, Enter cancels);
  piped or scripted, it prints the list. `--resume "<name>"` takes the name `/resume` shows.
- `config move-now on` (needs `auto-move on`): past the park threshold the move or park happens at
  once, even mid-turn, instead of at the turn end. The cut-off turn is resumed with a note of what was
  interrupted. Held sessions are never cut into.
- `config wait on` (default): when a park leaves nowhere to run without paid usage, the session waits for
  the first known window reset (plus a minute) and carries on by itself; nothing runs, so nothing is billed.
  It waits for its own profile unless "move without asking" is on. Ctrl-C stops waiting;
  `switch <profile> --session <id>` moves it now. `wait off` exits with code 2 as before.
- `hold` keeps a session on its profile: no park, no automatic move. A move you confirm still happens.
- `switch --cancel` drops a pending move, also one you confirmed, and counts as "Not now" for its suggestion.
  A move the engine queued (move without asking, park) can come back at the next usage update; `hold on` stops that.
  The app has the same as **Cancel Move** in the session's menu.
- `install-hooks` edits one profile's `settings.json` (with a backup) so sessions started with plain
  `claude` also report usage and limit stops. Optional; `uninstall-hooks` restores your status line.
- `profiles share` never deletes: a folder with content becomes `<item>.ash-backup-<time>`, its files are
  merged into the first profile (newer copy wins; the replaced one stays in the backup). It refuses while
  `claude` runs on that profile. `--dry-run` shows the plan.
- `profiles share` also links `sessions/`, Claude Code's list of running sessions. With one list, sessions on
  every account find each other: `@name`, `/peers` and messages between sessions work across accounts. This
  relies on undocumented Claude Code behaviour; `doctor` shows it per profile (cross-account messaging on/off).
  A session moved to another profile keeps the name you gave it with `/rename`.
- `shell install` picks the file from `$SHELL`: zsh `~/.zshrc` (or `$ZDOTDIR`), bash `~/.bash_profile` (else
  `~/.bashrc`), tcsh `~/.tcshrc` (else `~/.cshrc`), fish its own `~/.config/fish/conf.d/sessionhopper.fish`.
  A symlinked startup file is edited at its target. `--force` adds the line even if you define `claude`
  yourself.
- `profiles remove` only removes the entry from the list; the folder and its login stay.
- `config prompt` prints the continue prompt in use. `--file F` sets your own (placeholders `{reason}`
  why it stopped, `{jobs}` and `{crons}` with their own headings or empty, `{from}` and `{to}` profile
  names); `[sessionhopper] ` is always put in front. An empty file or `--reset` restores the built-in one.
