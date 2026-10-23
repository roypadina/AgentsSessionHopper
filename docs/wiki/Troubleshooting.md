# Troubleshooting

Start with:

```bash
sessionhopper doctor
```

| Symptom | Fix |
|---|---|
| "cannot be opened" / the CLI is killed on first run | `xattr -dr com.apple.quarantine /Applications/AgentsSessionHopper.app` |
| `claude not found` | Install Claude Code; the app also looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`. |
| A profile asks to log in again after import | For `~/.claude`, leave `CLAUDE_CONFIG_DIR` unset (`sessionhopper profiles export-config-dir default off`), or turn it on if you always launched it with the variable set. |
| "projects/ not shared by: X" | Sessions cannot move to or from X. Move X's `projects/` contents into the shared folder `doctor` names, then replace X's folder with a link to it. Close sessions first. |
| Usage shows "–" | The profile has had no session since launch, or the plan has no usage windows (only Pro and Max report them). |
| No suggestion appears | Another profile must be under the threshold; a held session is never moved; check `sessionhopper status`. |
| "No conversation found with session ID" after a move | The profiles do not share `projects/`; see above. |
| My status line disappeared | Run `sessionhopper doctor`; if you used `install-hooks`, `uninstall-hooks --profile X` restores it. |
| Hooks do nothing | Managed settings with `disableAllHooks` or `allowManagedHooksOnly` turn them off; the app cannot work there. |
