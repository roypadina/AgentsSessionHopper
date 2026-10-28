# FAQ

**Does it work without the app?** Yes. The CLI does everything; the app adds the menu bar,
notifications and settings.

**Does it read my usage from Anthropic's servers?** No. It makes no network requests. It only uses the
numbers Claude Code gives its own status line, so a profile with no running session shows "unknown".

**Does it move sessions on its own?** Only if you turn on **Move without asking** (off by default).
Otherwise every move is your click or command. **Park before paid usage** only ever ends a session (and
then waits for its own profile's usage window to reset); it never moves one.

**It moved my session but the agent didn't continue.** The session was idle when it moved: the turn
was over, so there was nothing to continue and it waits for your next message (see
[What a move looks like](How-it-works#what-a-move-looks-like)). `sessionhopper log` shows the move. If
a session was cut off mid-work and got no `[sessionhopper]` message, please report it as a bug.

**My session didn't move at all.** Only sessions started through `sessionhopper` (or the alias / shim)
can move. `sessionhopper doctor` lists `claude` sessions running without it. Terminals that restore
panes (cmux, tmux-resurrect, iTerm) re-run each pane's original command: restart those panes once.

**Do I need cmux, or a particular shell?** No. Any terminal and any shell work; cmux and IDEs are
optional and use the same shim.

**Can I use it with someone else's account?** No. Use it only with accounts that are yours, never
shared. See [Privacy and terms](Privacy-and-terms).

**Codex?** Not yet. Claude Code only.

**What about Team or Enterprise seats?** They can be profiles, but Claude Code reports no usage windows
for them, so no suggestions appear; manual `switch` still works.

**How is it related to Agents Monitor?** [Agents Monitor](https://github.com/roypadina/AgentsMonitor)
is a separate usage monitor for Claude Code and Codex. The two apps are independent.
