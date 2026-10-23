# Changelog

All notable changes to AgentsSessionHopper are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - not yet released

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
