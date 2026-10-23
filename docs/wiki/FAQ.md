# FAQ

**Does it work without the app?** Yes. The CLI does everything; the app adds the menu bar,
notifications and settings.

**Does it read my usage from Anthropic's servers?** No. It makes no network requests. It only uses the
numbers Claude Code gives its own status line, so a profile with no running session shows "unknown".

**Does it move sessions on its own?** Only if you turn on **Move without asking** (off by default).
Otherwise every move is your click or command. **Park before paid usage** only ever ends a session; it
never moves one.

**Can I use it with someone else's account?** No. Use it only with accounts that are yours, never
shared. See [Privacy and terms](Privacy-and-terms).

**Codex?** Not yet. Claude Code only.

**What about Team or Enterprise seats?** They can be profiles, but Claude Code reports no usage windows
for them, so no suggestions appear; manual `switch` still works.

**How is it related to Agents Monitor?** [Agents Monitor](https://github.com/roypadina/AgentsMonitor)
is a separate usage monitor for Claude Code and Codex. The two apps are independent.
