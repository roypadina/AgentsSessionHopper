# Getting started

The quickest way: open the app. On first launch a **Welcome** window explains it (Settings → About →
**Welcome Guide…** shows it again); its **Set Up Profiles…** button opens the **setup window**. The
panel offers the same button while there are no profiles, and Settings → General → **Run setup again**
brings the window back. It covers everything on this page plus three extras, each shown before it
changes anything:

- **Share history** for profiles you already had: `sessionhopper profiles share <name>`. Links
  `projects/`, `todos/`, `file-history/` (/rewind), CLAUDE.md, agents, commands and skills to your first
  profile. A folder with content is moved to `<name>.ash-backup-<time>` and its files merged in (the newer
  copy wins; the other is kept in the backup). Quit sessions on that profile first.
- **Make `claude` use it**: `sessionhopper shell install` adds one marked alias line to the startup file of
  your shell (zsh, bash, fish or tcsh), after a backup; `sessionhopper shell remove` takes it out.
  An existing `claude` alias or function of yours is never overridden.
- **Teach Claude about it**: `sessionhopper plugin install` puts the `agents-session-hopper` skill in
  every profile, with Claude Code's own `claude plugin install`.

## 1. Profiles

A profile is a Claude Code configuration folder with its own login. Claude Code documents this as the
way to use several accounts: one `CLAUDE_CONFIG_DIR` per account.

- **Already have them?** `sessionhopper profiles import` (or **Use these** in the setup window)
  picks up `~/.claude`, `~/.claude-*` and `~/.claudeN`. Nothing inside them is changed.
- **New one:** `sessionhopper profiles add work` (or Settings → Profiles → **Add Profile…**). It creates
  `~/.claude-work`, links `projects/` (conversation history) to your first profile, optionally shares
  CLAUDE.md, agents, commands and skills, copies settings.json, then runs Claude Code's own
  `claude auth login` for it.

The order in the list is the fallback order: new sessions start on the first profile with room.

Check everything with:

```bash
sessionhopper doctor
```

It must say that all profiles share one `projects/` folder, or sessions cannot move between them.

## 2. Start sessions through sessionhopper

```bash
sessionhopper                          # like `claude`, on the first profile with room
sessionhopper -P work "fix the tests"  # start on work
sessionhopper -c                       # continue the newest session in this folder
sessionhopper --resume <id>            # adopt an existing session (bare --resume: numbered picker)
```

Any other argument goes to `claude` unchanged. To make this the default, see
[Using with cmux and IDEs](Using-with-cmux-and-IDEs).

## 3. When a profile runs low

At 85% of its 5-hour or weekly window, if another profile has room, you are asked — in a notification,
in the menu bar, and once inside Claude Code. Choose **Move at turn end**, **Not now** or **Hold**.

From the terminal, inside the session: `! sessionhopper switch` (or name a profile:
`sessionhopper switch personal`). You can also ask the agent to run it.

The session moves when the current turn and its background jobs finish, and the conversation
continues on the other account.

## 4. Settings

- **Suggest a move at** — 85% by default.
- **Move without asking** — off by default. When on, sessions move at turn end without a prompt.
- **Park before paid usage** — on by default, at 97%. A session you did not move ends at its next turn
  end instead of running into paid extra usage.
- **Hold** a session (or all) to keep it where it is: no park, no automatic move. **Release Hold** in the
  session's **Move…** menu undoes it; it is disabled while **Hold every session** (Settings → Hand-off) is on.
