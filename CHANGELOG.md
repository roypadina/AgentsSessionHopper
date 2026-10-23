# Changelog

All notable changes to AgentsSessionHopper are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.3] - 2026-10-24

Still **BETA**.

### Fixed
- Profile discovery no longer offers other tools' folders such as `~/.claude-swap-backup`: a folder needs a Claude Code marker (`settings.json`, `projects/` or `.claude.json`; `sessions/` alone no longer counts), and names containing `backup`, `swap`, `bak` or `tmp` are skipped.

## [0.1.2] - 2026-10-23

Still **BETA**.

### Added
- **Resume picker.** A bare `--resume` in a terminal shows a numbered list, 10 at a time (`m` for more); pick a number to continue that conversation.
- **Session names** in `sessions` and the picker (the name `/resume` shows), `sessions all`, `--all-dirs` for every folder, and `--sessions [n|all]` as a launch flag.
- **Resume by name:** `--resume "<name>"` finds the conversation with that name, here first, then anywhere.
- **Move now past the park threshold** (`config move-now on`, off by default): with "move without asking" on, a move or park past the park threshold happens at once, even mid-turn, so a long turn cannot run into paid usage. Held sessions are never cut into.
- The start message names the profiles that were passed over and their usage. `--account` works as an alias of `-P`.

### Fixed
- A caller's own `--settings` (cmux passes its hooks this way) is merged into ours instead of being passed as a second flag. Claude Code reads only one `--settings`, so either the usage status line and hooks or cmux's notifications were lost.

## [0.1.1] - 2026-10-23

Still **BETA**.

### Added
- About: request a feature / contribute. Two new buttons in the About window open the feature-request form and CONTRIBUTING.md; Ko-fi supporters' requests go to the front of the queue.

## [0.1.0] - 2026-10-23

First public release, **BETA**: not fully tested; real account hand-offs are new.

### Added

- Menu-bar app: usage per profile, a prompt (and notification with **Move at turn end** / **Not now** /
  **Hold**) when a session should move, live sessions, recent hand-offs.
- Settings: launch at login, notifications, menu-bar %, suggest threshold, opt-in move without asking,
  park before paid usage, profile order, add/import profiles with Claude Code's own login, command-line
  setup, switch log (90 days).
- First-run guide with what the app does and never does.
- `sessionhopper` CLI: supervised sessions (start, resume, continue), confirmed hand-off at turn end,
  `switch`, `hold`, `status`, `profiles`, `login`, `config`, `log`, `doctor`, optional
  `install-hooks` / `uninstall-hooks`, and `shim` for cmux and IDEs.
- Usage from Claude Code's status-line input; limit stops from the `StopFailure` hook. No network
  requests, no credential access.

[Unreleased]: https://github.com/roypadina/AgentsSessionHopper/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/roypadina/AgentsSessionHopper/releases/tag/v0.1.0
