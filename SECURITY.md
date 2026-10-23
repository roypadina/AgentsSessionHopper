# Security Policy

## Reporting a Vulnerability

AgentsSessionHopper starts the Claude Code CLI on your behalf, writes hook and status-line
settings into Claude Code profiles you choose, and supervises those processes, so security
reports are taken seriously. Please **do not** open a public issue for security problems.

Instead, use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on this repository).

You'll get an acknowledgement within a few days. Once a fix is available it will be released
and the report disclosed, with credit unless you prefer otherwise.

## Scope

AgentsSessionHopper runs entirely on-device and makes no network connections. It never reads,
stores or sends Claude logins, tokens or Keychain items. Relevant areas: the `sessionhopper`
supervisor (process launch, signals, relaunch), the `hook` and `statusline` commands that
Claude Code runs, `install-hooks` / `uninstall-hooks` (edits to a profile's `settings.json`),
and the files under `~/Library/Application Support/AgentsSessionHopper/`.
