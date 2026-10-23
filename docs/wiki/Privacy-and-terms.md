# Privacy and terms

AgentsSessionHopper is an independent open-source tool. It is not made by, affiliated with, or endorsed by
Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.

## What it does

It starts the official, unmodified Claude Code (`claude`) with a separate configuration folder for each
of your own accounts, and, when you confirm, continues the same conversation under another of your
accounts.

## What it never does

- It never reads, copies, stores or sends your Claude login, OAuth tokens, `.credentials.json` or
  Keychain items. There is no Keychain code in it.
- It makes no network requests: no usage endpoint, no telemetry, no update check.
- It never modifies, patches or wraps the `claude` binary's traffic, and never logs in for you. Login
  happens only through Claude Code's own `claude auth login` or `/login`.
- It does not change or get around any account's limits: each account keeps its own. Usage numbers come
  only from the data Claude Code gives its own status line.
- Nothing is shared across machines or people.

## Your part

Use it only with accounts that are yours, never shared with anyone. Each account is subject to
Anthropic's [Consumer Terms](https://www.anthropic.com/legal/consumer-terms),
[Usage Policy](https://www.anthropic.com/legal/aup) and
[Claude Code usage rules](https://code.claude.com/docs/en/legal-and-compliance), which Anthropic may
change at any time.

## What it stores

Only in `~/Library/Application Support/AgentsSessionHopper/`: your profile list and settings, the last
usage percentages per profile, live session state, and the switch log (90 days). Preferences are in the
defaults domain `com.padina.agents-session-hopper`.
