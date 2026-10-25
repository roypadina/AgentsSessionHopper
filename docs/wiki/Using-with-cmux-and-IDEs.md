# Using with cmux and IDEs

## Make it the default in your shell

Any terminal app works (Terminal, iTerm, Ghostty, Warp, cmux, an IDE terminal): what matters is your
shell. Add one line to your shell's startup file (the app never edits it for you):

| Shell | File | Line |
|---|---|---|
| zsh (macOS default) | `~/.zshrc` | `alias claude='sessionhopper shim'` |
| bash | `~/.bash_profile` or `~/.bashrc` | `alias claude='sessionhopper shim'` |
| fish | `~/.config/fish/config.fish` | `alias claude 'sessionhopper shim'` |
| tcsh / csh | `~/.tcshrc` or `~/.cshrc` | `alias claude 'sessionhopper shim'` |

Open a new terminal tab afterwards. Without the alias, start sessions with `sessionhopper` instead of
`claude`; that works everywhere with no setup.

`shim` supervises interactive sessions and passes everything else straight to the real `claude`:
subcommands (`claude mcp …`, `claude plugin …`, `claude auth …`, `claude update`, …), `-p`/`--print`,
`--version`, `--help`, and any `claude` started inside a session that is already supervised.

## cmux, editors and other tools

Tools that ask for a **Claude binary path** need one executable, not a command with arguments. Link the
CLI under a name ending in `-shim`; it then behaves like `sessionhopper shim`:

```bash
ln -s /Applications/AgentsSessionHopper.app/Contents/Helpers/sessionhopper ~/.local/bin/sessionhopper-shim
```

Use `~/.local/bin/sessionhopper-shim` as the Claude binary path.

**Restored panes.** cmux, tmux-resurrect and iTerm arrangements restore a pane by re-running the command
it was first opened with. Panes opened before you set the shim keep their old command, so their
sessions are not supervised (`sessionhopper doctor` lists them). Restart each once: `/exit`, then
`sessionhopper -c`.

**VS Code side panel**: not supported. The extension drives Claude Code directly over its own channel,
and a restart under another profile would break the panel. Use `claude` in VS Code's terminal instead
(with the alias). **JetBrains**: set Settings → Tools → Claude Code → Claude command to the shim; it runs
in the IDE terminal, so it should be supervised like any terminal (not yet tested; reports welcome). The shim finds the real `claude` on your
PATH (and in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). Do not name the link `claude`.
