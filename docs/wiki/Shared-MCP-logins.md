# Shared MCP logins (opt-in)

Each profile normally keeps its own MCP logins (Atlassian, Slack, Notion, Figma, …), so every MCP server
has to be logged in once per profile. Profiles that run on a `claude setup-token` can share one store instead:

```bash
sessionhopper login work --token          # makes a setup-token in a throwaway folder; paste it (several lines are fine)
sessionhopper login work2 --token
sessionhopper mcp share on work work2     # log in to each MCP server once (/mcp), it works on both
sessionhopper mcp status                  # which profiles share, which MCP servers the store holds (names only)
```

- Each profile stays on its own Claude account: the account comes only from its token. Claude Code keeps
  account and MCP logins in one secure-storage object; the shared profiles point it at one folder
  (`~/.claude-mcp-store`, change with `mcp store <dir>`) through `CLAUDE_SECURESTORAGE_CONFIG_DIR`. That variable
  is undocumented, so `doctor` checks your `claude` still knows it.
- `/login` and `/logout` are turned off in those sessions (`/logout` would delete everyone's MCP logins), and
  `claude auth login|logout` / `setup-token` are refused there. A guard runs before each launch and at session
  start and end: it removes an account login that got into the store, backs up the MCP part (a private file
  on Linux, a Keychain item on macOS) and puts it back if the store was deleted or emptied.
- A profile without a token keeps its own MCP logins, even with sharing on. A token profile loses claude.ai
  connectors and Remote Control, so keep a profile that needs those on its normal login and out of sharing.
- `login --token` asks you to sign in in a **private browser window**: a window already signed in to another
  account makes a token that works but bills that account. It then compares usage and reset times with your
  other profiles and warns if two look like the same account (Claude Code shows no email for a token login).
