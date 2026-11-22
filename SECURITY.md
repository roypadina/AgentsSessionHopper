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

AgentsSessionHopper runs on-device. Its own network connections are the opt-in update check and the
ntfy alerts you set up. It never reads or sends your Claude login. It stores only the secrets you give it
(API keys, setup-tokens, an ntfy token) in the Keychain or a private file. The exception is opt-in shared
MCP logins, where it reads and rewrites the shared Claude Code credential store and keeps a local backup
of its MCP logins. Relevant areas: the `sessionhopper`
supervisor (process launch, signals, relaunch), the `hook` and `statusline` commands that
Claude Code runs, `install-hooks` / `uninstall-hooks` (edits to a profile's `settings.json`),
and the files under `~/Library/Application Support/AgentsSessionHopper/`.
