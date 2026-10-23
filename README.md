<div align="center">

# AgentsSessionHopper

**Profiles for Claude Code.** Keep your own accounts side by side, and when one runs low,
continue the same conversation on another with one click. Nothing lost, nothing re-explained.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange)](Package.swift)
[![CI](https://github.com/roypadina/AgentsSessionHopper/actions/workflows/ci.yml/badge.svg)](https://github.com/roypadina/AgentsSessionHopper/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/roypadina)

<img src="docs/screenshots/popover.png" width="400" alt="The menu-bar window: three profiles with their 5-hour and weekly usage, a prompt to move a session from work to personal, live sessions and recent hand-offs">

</div>

> **Status: in development (pre-0.1.0).** The engine and CLI work and are tested; the menu-bar app is a first shell.
> See [docs/ROADMAP.md](docs/ROADMAP.md).

## What it does

- **Profiles.** Each of your Claude accounts gets its own Claude Code configuration folder, the
  [way Claude Code documents for multiple accounts](https://code.claude.com/docs/en/authentication).
  `sessionhopper profiles import` picks up the ones you already have.
- **Usage from Claude Code itself.** Every session's status line reports its account's 5-hour and weekly
  usage. AgentsSessionHopper records it per profile (and still shows your own status line).
- **You confirm every move.** When a profile reaches 85% and another has room, you are asked:
  *"work is near its usage limit (88%). Continue this conversation on personal?"* Confirm and the session
  moves when the current turn ends: Claude Code restarts on the other profile and resumes the same
  conversation. Optional, off by default: *move without asking*.
- **Park before paid usage** (on by default). Past 97% with nothing confirmed, the session ends at its
  next turn end instead of running into paid extra usage, and tells you how to resume it.
- **Switch log.** Every suggestion, move, park and limit stop is written to a log you can browse in the app.

## Install

Not released yet. Build from source:

```bash
git clone https://github.com/roypadina/AgentsSessionHopper.git
cd AgentsSessionHopper
Scripts/package_app.sh          # dist/AgentsSessionHopper.app, CLI in Contents/Helpers/sessionhopper
```

## Use

```bash
sessionhopper profiles import            # find ~/.claude and ~/.claude-* profiles
sessionhopper profiles add work          # new profile: links shared history, then Claude Code's own login
sessionhopper doctor                     # claude found, logins, shared history, thresholds

sessionhopper                            # start a session on the first profile with room
sessionhopper -P work "fix the tests"    # start on work (others stay fallbacks)
sessionhopper -c                         # continue the newest session in this folder
sessionhopper switch                     # inside a session: move to the next profile at turn end
sessionhopper status                     # profiles, usage, live sessions
sessionhopper log                        # the switch log
```

Inside Claude Code you can also type `! sessionhopper switch`, or ask the agent to run it.

Moving a session needs every profile to share one `projects/` folder (where Claude Code keeps
conversations). `profiles add` sets that up; `doctor` checks it.

## What it never does

AgentsSessionHopper is an independent open-source tool. It is not made by, affiliated with, or endorsed
by Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.

- It starts the official, unmodified `claude` and never changes or intercepts its traffic.
- It never reads, copies, stores or sends your Claude login, tokens or Keychain items. Login always
  happens in Claude Code's own flow (`claude auth login`).
- It makes **no network requests** at all: no usage endpoint, no telemetry, no update check.
- Usage numbers come only from what Claude Code gives its own status line, and limit stops from its
  documented `StopFailure` hook.
- It does not change or get around any account's limits: each account keeps its own.

**Your part:** use it only with accounts that are yours, never shared with anyone. Each account is subject
to Anthropic's Consumer Terms, Usage Policy and Claude Code usage rules, which Anthropic may change at any time.

## How it works

`sessionhopper` starts `claude --session-id <id> --settings '<hooks + status line>'` under the profile's
config folder. `--settings` applies to that session only and writes no file. The status line records
usage; hooks tell the engine when a turn starts and ends. A confirmed move waits for the turn (and any
background jobs) to finish, then restarts `claude --resume <id>` under the next profile.

`sessionhopper install-hooks --profile <name>` (optional, reversible) adds the same status line and
limit-stop hook to a profile's `settings.json`, so sessions you start without `sessionhopper` report
usage too. `uninstall-hooks` restores your settings.

## Companion app

[Agents Monitor](https://github.com/roypadina/AgentsMonitor) watches usage limits for Claude Code and
Codex accounts from the menu bar. The two apps are independent.

## Support

If this app saves you time, a coffee keeps the next one coming:

[![Support me on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/roypadina)

## License

MIT © Roy Padina
