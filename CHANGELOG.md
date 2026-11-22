# Changelog

All notable changes to AgentsSessionHopper are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.15.0] - 2026-11-22

### Added
- Anthropic API key profiles (`sessionhopper profiles add <name> --anthropic`, or Settings → Profiles → + → Anthropic API key): the same `claude`, billed to a Claude Console API key, used like an OpenRouter profile when no Claude account has room (#43).
- Profiles for any Anthropic-compatible gateway (`--gateway <url>`, or Other gateway in the app), for example LiteLLM in front of an OpenAI key (#43).
- "Your credit balance is too low" (Anthropic) and `insufficient_quota` (OpenAI behind a gateway) count as an out-of-credit key, like OpenRouter's 402.

### Changed
- The Ko-fi card no longer follows a move onto a pay-per-use profile and never shows while a session runs on one. Its title now says since when hops are counted, and the receipt row reads "App price".

## [1.14.0] - 2026-11-19

### Changed
- Settings redesign, closer to System Settings. Profiles is a real list: select a row, drag to reorder (the list order is still the fallback order), double-click or press Return to rename in a small sheet, + and − under the list, right-click for Rename, Move Up, Move Down and Remove. Each row shows the display name in bold, the login email, then the profile name and folder.
- Every Settings pane is sized to its content instead of one fixed size, with help text in section footers and titled sections (Suggestions, Paid Usage, Continue Prompt, Keyboard Shortcut, Setup, Command Line).
- The Log pane says "No Hand-offs Yet" when the log is empty.
- Renaming to a name or label another profile already uses now says so instead of silently keeping the field open.

## [1.13.0] - 2026-11-19

### Added
- Rename a profile's display name (Settings → Profiles → Rename, or `sessionhopper profiles label <name> <text>|--clear`). The profile's name, used by aliases and `-P`, never changes. The label shows in the menu-bar window, session menus, notifications, Settings, `profiles list` and `status` (`status --json`: `config.profiles[].label`, when set).
- Settings notes that the profile list order is also the fallback order.

## [1.12.0] - 2026-11-19

### Added
- Each Claude profile now shows its login email (read from Claude Code's `.claude.json` for that profile, `~/.claude.json` for the default one; not a credential): under the name in the menu-bar panel and in Settings, in `sessionhopper profiles list` and `status`, and as `emails` in `status --json`.

## [1.11.3] - 2026-11-15

### Fixed
- No longer takes focus back from another app you clicked into right after opening a window.

## [1.11.2] - 2026-11-15

### Fixed
- On macOS 14 and later, Settings, About, Welcome and Setup windows opened from the menu bar come to the front and stay there, instead of opening behind the app you were using.
- The menu-bar panel now brings AgentsSessionHopper to the front when it opens (click or shortcut), which should stop a menu in the panel from closing on its first click.
- Check for Updates… brings the update window to the front.

## [1.11.1] - 2026-11-14

### Fixed
- In-app updates: 1.11.0 kept the previous build number, so Check for Updates on 1.10.0 said it was up to date. 1.11.1 has a higher build number, so the update is offered again. No other changes.

## [1.11.0] - 2026-11-14

### Added
- Ko-fi support card: after a hop kept a conversation going (still running on the new profile 30 seconds later, or a
  `run` turn served by another profile after a retry), the next time you close the menu-bar window with nothing
  needing you (no suggestion, pending move, parked session or error, the profiles in use under the suggest threshold
  and not on pace to reach it within the hour), a small receipt card may ask for a tip about 10 seconds later, only
  within 12 hours of the hop and never within 2 minutes of a logged event. It waits until 7 days after you install
  or update to this version, and until more than 10 hops (about 3 weeks of normal use) were counted since this
  version. It asks at most 3 times a year and once per hop, only when you used the Mac in the last 10 seconds, and
  never while you are typing, a menu or an AgentsSessionHopper window is open, a mouse button is held down, a usage
  refresh runs, the screen is locked or the microphone is in use; a park, limit stop or failed run since the hop
  cancels it. "Ask me in 2 weeks" snoozes it, a tip keeps it quiet for 180 days, and "Nope, don't ask again" keeps
  it quiet until the next major version, and for at least 90 days. A card still open when an AgentsSessionHopper
  window or update prompt opens, a session parks or hits a limit, or the Mac sleeps or locks, closes and counts as a
  snooze; one left unanswered for 5 minutes, or 2 minutes without input, fades and counts as a snooze too. The card
  never takes keyboard focus, and the same three choices head the right-click menu while it shows, for keyboard and
  VoiceOver users. Hold ⌥ in the right-click menu for "Show Support Prompt Now" to preview it. Its count (hops since
  this version) stays on your Mac, in the app's preferences; nothing is sent.

## [1.10.0] - 2026-11-11

### Added
- Refresh button in the menu-bar window (⌘R) and `sessionhopper refresh [profile...] [--stale]`: fresh usage for every
  Claude profile from one tiny `claude -p` on Haiku per profile (no tools, no MCP, no saved transcript).
- The app refreshes any Claude profile whose usage is over 6 hours old by itself (checked every 10 minutes).

### Fixed
- An idle profile kept usage numbers for days. A limit reset on the account page went unseen, so sessions moved to
  that profile were sent straight back by the old 97% sample.

## [1.9.1] - 2026-11-06

### Fixed
- Task lists move with a session again: `profiles share` (and `profiles add`) also link `tasks/`, where Claude Code
  now keeps them (`todos/` before). `doctor` checks only the folders the first profile has, so it no longer reports
  `todos` as not shared after Claude Code stopped using it.
- `profiles share` no longer says "links elsewhere" for a link to a folder it has just created in the first profile.
- The Linux CLI runs on glibc 2.35 or newer (Ubuntu 22.04+, Debian 12+). 1.8.1 and 1.9.0 needed glibc 2.43 and did
  not start on Ubuntu 24.04.

## [1.9.0] - 2026-11-05

### Added
- **Messaging across accounts**: `sessionhopper profiles share <name>` also links `sessions/`, Claude Code's list of
  running sessions, so `@name`, `/peers` and messages between sessions reach sessions on every account. `doctor`
  shows it per profile. It relies on undocumented Claude Code behaviour.
- **Cancel a pending move**: `sessionhopper switch --cancel [--session <id>]`, and **Cancel Move** in a session's menu.
  It drops a move you confirmed too; before, `hold` dropped only the moves the engine queued.

### Fixed
- `profiles share` now sees the sessions running on a profile whose `sessions/` folder is a link, and with a
  shared list it counts only that profile's own sessions (from each process's `CLAUDE_CONFIG_DIR`).

## [1.8.1] - 2026-11-04

### Added
- **Check for Updates…** in the menu-bar icon's right-click menu; it reads **Install Update X.Y.Z…** once an update has been found.

### Changed
- Settings → About now matches the About tab in the other apps: app icon, version, a **Check for Updates…** button, and the About, Welcome Guide and Ko-fi buttons.

## [1.8.0] - 2026-11-04

### Added
- Updates from inside the app, with your permission. The app asks once, on its second launch, whether to check for updates automatically; with your yes it checks once a day (downloading the release feed from GitHub, which sends nothing about you) and asks before installing a new version. Check by hand with **Check for Updates…** in the About window. Updates are signed and need no `xattr` step. The `sessionhopper` CLI and the Linux build are unchanged and never check.

## [1.7.0] - 2026-11-04

### Added
- A global keyboard shortcut opens the menu-bar window from any app: record it in Settings → General (none by default; no Accessibility permission needed).

### Changed
- The menu-bar window is short again: one row per profile with a usage bar and the one fact that matters next — when it switches at the current pace (and to which profile), when a full profile is free again, or that it is ready. Both windows and the reset time are in the row's tooltip.
- Sessions moved into a menu on their profile's row (each session a submenu with its moves and Hold). The recent hand-offs list is gone from the window; it is in Settings → Log and the new More menu (⋯), which also holds About, Ko-fi and Quit.

### Fixed
- Right-click → Open did nothing on macOS 27; it opens the menu-bar window again.

## [1.6.0] - 2026-11-03

### Added
- Settings → Profiles: add an OpenRouter profile (name, key stored in your Keychain, model names, credit reset), set each profile's priority, and remove a profile from the list (right-click).

### Changed
- Settings → Profiles shows what each row is (folder, or OpenRouter · pay per use), whether its login or key is there, and explains priorities.

## [1.5.0] - 2026-11-03

### Added
- VS Code side panel: set the Claude Code extension's `claudeCode.claudeProcessWrapper` to `sessionhopper` and every panel conversation runs as a supervised session: picked by the same rules, shown in `status` and the app with live usage, and moved like a terminal session. A turn that hits a usage limit runs again on the next profile without the panel noticing; `switch`, `hold`, "move without asking" and priorities apply, also while the conversation is idle.
- Profile priorities: `sessionhopper profiles priority <name> <n>` (lower is preferred; Claude 1, OpenRouter 10 by default). A better priority with room always wins and a session on a worse one moves back up as soon as one frees up; equal priorities never trade places before the current profile reaches its limit (also for `sessionhopper run`, which keeps the profile that served the last turn).

## [1.4.2] - 2026-11-03

### Fixed
- `sessionhopper doctor` no longer warns "no usage sample yet" for an OpenRouter profile, which never reports usage windows; it says when the profile counts as full instead.

## [1.4.1] - 2026-11-03

### Fixed
- `sessionhopper doctor` no longer warns that `CLAUDE_CODE_OAUTH_TOKEN` is used on every profile: since 1.4.0 it goes to the first Claude profile only.

## [1.4.0] - 2026-11-03

### Added
- Several Claude accounts on a server: a profile can hold its own `claude setup-token` (`sessionhopper profiles key <name> < file`; Keychain on macOS, systemd credential or private file on Linux). A `CLAUDE_CODE_OAUTH_TOKEN` in the caller's environment is kept for the first Claude profile only, never given to the others or to an OpenRouter profile. `doctor` says which login each profile uses.
- `sessionhopper config on-switch "<command>"`: a command run on every move, limit stop and park, with `SESSIONHOPPER_EVENT`, `_FROM`, `_TO`, `_REASON`, `_DETAIL` and `_SESSION` set.

### Fixed
- On Linux, a `claude` started by `sessionhopper run` ends when `sessionhopper` is killed (a caller's timeout), instead of running on.
- No colour codes on stderr when it is not a terminal or `NO_COLOR` is set.
- The Linux tarball carries no macOS metadata (GNU tar printed "Ignoring unknown extended header keyword").

## [1.3.0] - 2026-11-03

### Added
- OpenRouter profiles: `sessionhopper profiles add <name> --openrouter [--model alias=name]` runs the same unmodified `claude` against OpenRouter with your own API key. Pay per use, so it is used only when no Claude profile has room; a session on it is offered the way back once one has. Out of credit (402) = full until the next daily (or `--resets weekly|monthly`) reset.
- `sessionhopper profiles key <name>` stores that key: macOS Keychain, or on Linux a private file (or the systemd credential `$CREDENTIALS_DIRECTORY/<name>`). Never on a command line or in `config.json`.
- `sessionhopper run -- <claude -p args>`: one non-interactive turn for bots and services. Picks the profile, records usage from `claude`'s own `rate_limit_event` output, and on a limit failure runs the same turn again on the next profile. Exit 75 when no profile can take it.
- `sessionhopper config gateway last|order|manual`: when OpenRouter profiles are used. Default `last`: Claude subscriptions always first.
- The switch log records which profile served each `run` (`sessionhopper log`).
- Live tests with the real `claude`: `Scripts/live/run-swaps.sh` and `Scripts/live/interactive-swaps.py` move one conversation across every profile, forced by mocked usage (`SESSIONHOPPER_MOCK_LIMITS`).
- Linux x86_64 build of the `sessionhopper` CLI (no menu-bar app): `Scripts/package_linux.sh`, state in `~/.local/state/agents-session-hopper/`. CI builds and tests on Linux too.

## [1.2.1] - 2026-11-03

### Fixed
- `sessionhopper doctor` no longer reports `todos` and `file-history` as "not shared" on profiles where they are correctly linked to the first profile.

### Changed
- README: a short demo of a hand-off at the top, and the app is no longer called beta.

## [1.2.0] - 2026-10-30

### Added
- **A Welcome window on first launch** (and under Settings > About > Welcome Guide…): why the app exists, where
  the icon is, how to start Claude Code with it, and Open at Login. Set Up Profiles… opens the setup window,
  which no longer opens by itself or on every launch.
- Opening AgentsSessionHopper again from Applications or Raycast shows Settings, so a hidden menu-bar icon is
  never a dead end.
- Release Hold in a session's Move… menu (and Hold), the missing undo for the Hold button.
- A real app menu while Settings, About or the setup window is open (Dock icon, Cmd-Tab, Settings… Cmd-,).
- The panel's Settings gear answers to Cmd-, and Settings… in the right-click menu shows it.
- No profiles yet: the panel offers Set Up Profiles… instead of a Terminal command.

### Changed
- Each profile row in the panel has two lines: usage on top, the reset time and sample age below, full width
  instead of cut off. A profile's state is a symbol (ok, near, full, no data), not a color alone.
- With more than 8 live sessions the Sessions list scrolls, so About and Quit stay on screen.
- Open at Login handles the "Allow in Login Items" and "move to Applications" states and follows a change made in
  System Settings.
- The right-click item "Switch log…" is now "Show Hand-off Log"; the panel's Quit reads "Quit AgentsSessionHopper"
  (Cmd-Q), and its About button is just "About". Section titles are no longer in capitals.
- VoiceOver: the menu-bar icon reads the fullest profile's percent and whether a profile is full or a session needs
  you; profile and session rows read as one item each, and a session's menu names its folder.

### Fixed
- A hand-off with no trigger no longer ends in an empty "()" in the recent list.

## [1.1.0] - 2026-10-29

### Added
- **A session summary when a session ends.** After Claude Code's own resume hint, `sessionhopper` prints
  what the session is, not just its id: its name, what it is about, the last three prompts you typed,
  how it ended (last turn finished or cut off, the profile, moves this run), when it started and was last
  used, its folder, the id and the resume command. A parked session shows it too, above the resume lines.

### Fixed
- Sessions whose first prompt comes after large attachments (over 256 KB into the transcript) now show
  in `sessionhopper sessions` and `--resume`'s picker; the first 1 MB is read.

## [1.0.1] - 2026-10-29

### Fixed
- **A session moved (or resumed after a wait) before its first prompt no longer dies.** Claude Code saves a
  conversation only once it has a prompt, so `--resume` failed with "No conversation found". The session now
  starts again under the same id on the new profile.

## [1.0.0] - 2026-10-28

First stable release: out of BETA.

### Removed
- The BETA labels: the version no longer carries "BETA" in the app, the About and setup windows, the
  popover, `sessionhopper --version`, the README and the wiki.

### Added
- **Wait for a reset instead of stopping.** When a park leaves no profile to run on without paid usage,
  the session now waits for the first known usage-window reset (plus a minute, so it never lands before
  the account itself reset) and then carries on by itself. Nothing runs while it waits, so nothing is
  billed. Without "move without asking" it waits for its own profile; a move you confirm meanwhile
  (`sessionhopper switch <profile> --session <id>`, or the app) is taken at once. Ctrl-C stops waiting.
  No reset time known, or `sessionhopper config wait off`: it exits with code 2 as before. The app sends
  one notification per park and shows waiting sessions.
- **How old the usage numbers are, and when they reset**, on every surface: the park list, the "skipped"
  line at start, `sessionhopper status` and the app's profile rows (e.g. `5h 98% · resets 18:00 ·
  sampled 3 h ago`; the age shows once a sample is over 10 minutes old).
- **The limit is named.** A usage-limit stop shows Claude Code's own words for it in the suggestion and
  the notification, so a model's own limit (fixable with `/model`) is told apart from the account window.
- **Login check before a move.** The target profile's login is checked with Claude Code's own
  `claude auth status` (as `doctor` does); a profile that is not logged in is skipped instead of
  landing the session on a login screen.
- `doctor` warns when `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `CLAUDE_CODE_OAUTH_TOKEN` is set
  (sessions bill that key on every profile and report no usage limits, so hand-offs never trigger), and
  when a profile has no usage sample yet (it counts as having room).

### Changed
- A gateway spend limit (`rate_limits.spend_limit`, behind a Claude apps gateway) now counts like a usage
  window: past the park threshold of it is paid usage, so the session parks or moves instead.

## [0.2.1] - 2026-10-27

Still **BETA**.

### Fixed
- **A move onto a profile whose Claude login expired no longer leaves the session dead.** A login error
  at the end of a turn (`authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`) is handled
  like a usage-limit stop: with "move without asking" the session moves on to the next profile and
  resumes with a "login expired" continue prompt; otherwise you are asked, and told to log that profile in.
- **A profile you move a session to yourself is respected**: no threshold suggestion or automatic move
  away from it a moment later. The park threshold still protects against paid usage.
- A turn that ended on an API error counts as finished for a pending move.

## [0.2.0] - 2026-10-25

Still **BETA**.

### Added
- **Setup window** that sets up the whole multi-account setup, one click per step, showing what each
  step changes first: profiles and logins, shared history, the `claude` alias, the shim link for cmux
  and JetBrains, the Claude skill in every profile, and a final check. Run it again from Settings →
  General.
- **Share history for profiles you already had** (`sessionhopper profiles share <name>`): links
  conversation history, todo lists, `/rewind` checkpoints, CLAUDE.md, agents, commands and skills to the
  first profile. Existing folders are moved to a backup and merged (the newer file wins), never deleted;
  refuses while `claude` runs on that profile.
- **`sessionhopper shell install | remove | status`**: one marked `alias claude=… shim` line in your shell's
  startup file (zsh, bash, fish or tcsh), after a backup; a symlinked startup file is edited at its
  target, and your own `claude` alias or function is never overridden. `shell link-shim` creates
  `~/.local/bin/sessionhopper-shim`.
- **`sessionhopper plugin install | status`**: installs the `agents-session-hopper` Claude skill into every
  profile with Claude Code's own `claude plugin install`.
- **Continue prompt editor** in Settings → Hand-off (with Reset to built-in).
- Supervised sessions are told at start that they run under AgentsSessionHopper and on which profile.
- `doctor` shows whether `todos/` and `file-history/` are shared and whether the shell alias is set.

### Changed
- New profiles also share `todos/` and `file-history/` with the first profile.

## [0.1.8] - 2026-10-25

Still **BETA**.

### Fixed
- **A move no longer cuts off a reply that is still being written.** Besides the hooks' turn state, the
  engine now checks that the conversation transcript ends with Claude's reply before ending `claude`.
- **A session that was cut off anyway now always resumes with the continue prompt**, also when the hooks
  missed the turn (the transcript shows a turn that never got its reply).
- `sessionhopper --version` and `-v` print the version instead of starting a session; the version shown
  everywhere now comes from one place.

### Added
- **Your own continue prompt**: `sessionhopper config prompt` shows it, `--file F` sets yours,
  `--reset` restores the built-in one. Placeholders `{reason}` `{jobs}` `{crons}` `{from}` `{to}`.
- The continue prompt lists scheduled tasks (`CronCreate`, `/loop`) that were active and asks the
  agent to re-create only the ones Claude Code did not restore.
- `doctor` warns when Claude Code is older than 2.1.145 and lists `claude` sessions running without
  sessionhopper (they cannot move).

## [0.1.7] - 2026-10-25

Still **BETA**.

### Changed
- Releases are now signed with a stable identity, so permissions survive future updates. After this one update you may need to re-allow notifications once.

## [0.1.6] - 2026-10-24

Still **BETA**.

### Changed
- **Settings window uses the classic macOS preferences toolbar**: an icon and label per tab, the selected tab highlighted, and the window title follows the tab. Replaces the cramped tab strip.

## [0.1.5] - 2026-10-24

Still **BETA**.

### Fixed
- **Settings… and Switch log… now open the Settings window**, from the right-click menu and from the popover's gear button. macOS 14+ ignores the old way of opening it. Switch log… opens on the Log tab.

## [0.1.4] - 2026-10-24

Still **BETA**.

### Added
- **Right-click (or control-click) menu** on the menu-bar icon: Open, Settings…, Switch log…, Request a feature, Contribute, About, Support on Ko-fi, Quit. Left click still opens the popover.

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
