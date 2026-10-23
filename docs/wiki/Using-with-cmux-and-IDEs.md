# Using with cmux and IDEs

## Make it the default in your shell

Add to `~/.zshrc` (the app never edits it for you):

```bash
alias claude='sessionhopper shim'
```

`shim` supervises interactive sessions and passes everything else straight to the real `claude`:
subcommands (`claude mcp …`, `claude plugin …`, `claude auth …`, `claude update`, …), `-p`/`--print`,
`--version`, `--help`, and any `claude` started inside a session that is already supervised.

## cmux, editors and other tools

Tools that ask for a **Claude binary path** need one executable, not a command with arguments. Link the
CLI under a name ending in `-shim`; it then behaves like `sessionhopper shim`:

```bash
ln -s /Applications/AgentsSessionHopper.app/Contents/Helpers/sessionhopper ~/.local/bin/sessionhopper-shim
```

Use `~/.local/bin/sessionhopper-shim` as the Claude binary path. The shim finds the real `claude` on your
PATH (and in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). Do not name the link `claude`.
