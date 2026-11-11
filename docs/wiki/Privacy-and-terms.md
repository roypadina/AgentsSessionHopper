# Privacy and terms

AgentsSessionHopper is an independent open-source tool. It is not made by, affiliated with, or endorsed by
Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.

## What it does

It starts the official, unmodified Claude Code (`claude`) with a separate configuration folder for each
of your own accounts, and, when you confirm, continues the same conversation under another of your
accounts.

## What it never does

- It never reads, copies or sends your Claude login, `.credentials.json` or Claude Code's Keychain
  items. The only secrets it handles are ones you give it with `sessionhopper profiles key`: an
  OpenRouter API key, or on a server a `claude setup-token` for a profile. Each is kept in its own
  Keychain item (macOS) or a private file (Linux), and handed only to the `claude` it launches for that
  profile.
- It makes no network requests of its own to Anthropic or anyone else: no usage endpoint, no telemetry. The update check is opt-in: the app asks once whether to check automatically; with your yes it downloads the release feed from GitHub once a day, sending nothing about you. The optional skill
  install runs Claude Code's own `claude plugin install`, which downloads the plugin from GitHub. To refresh usage it runs `claude`: one tiny `claude -p` on Haiku per profile, a request to Anthropic on that account that uses a little of its usage and can start an idle account's 5-hour window. It runs by itself for a profile not seen for 6 hours, or when you click Refresh / run `sessionhopper refresh`.
- It edits your shell's startup file only when you click **Add the line** (or run `sessionhopper shell
  install`): one marked line, after a backup, removable the same way.
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
