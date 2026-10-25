# How it works

## Starting a session

`sessionhopper` picks a session id up front and starts the official `claude`:

```
CLAUDE_CONFIG_DIR=<profile folder> claude --session-id <id> --settings '{"hooks":{…},"statusLine":{…}}'
```

- For `~/.claude` the variable is left unset by default (setting it makes Claude Code look for a
  differently named login). `sessionhopper profiles export-config-dir <name> on` changes that.
- `--settings` applies to this session only and writes no file. Its hooks are added to yours, not
  replacing them ([settings precedence](https://code.claude.com/docs/en/settings)).
- `claude` stays in the same process group, so it owns the terminal. Ctrl-C goes to Claude Code;
  SIGTERM/SIGHUP are passed on.

## Usage

Claude Code sends its status-line command a JSON object that includes, for Pro and Max plans,
`rate_limits.five_hour` and `rate_limits.seven_day` (`used_percentage`, `resets_at`)
([docs](https://code.claude.com/docs/en/statusline)). `sessionhopper statusline` saves those numbers per
profile, then runs **your** status-line command with the same input and prints its output.

A profile with no recent session has no numbers ("unknown") and counts as having room. A window whose
reset time has passed counts as reset.

## Turns and limit stops

Hooks ([docs](https://code.claude.com/docs/en/hooks)) keep track of the turn:

| Hook | What it records |
|---|---|
| `UserPromptSubmit` | a turn is running |
| `Stop` | the turn ended; `background_tasks` still running; `session_crons` (scheduled tasks) |
| `StopFailure` with `error: "rate_limit"` | the account hit its limit |
| `SessionStart` with `source: "clear"` | `/clear` started a new conversation in the same process |

## A move

1. You confirm (menu, notification, `sessionhopper switch`, or the agent runs it).
2. When the turn is over and no background job is left, the engine ends `claude` (SIGTERM, then SIGKILL
   after 10 s). "Over" means the hooks say so **and** the transcript ends with Claude's reply, so a
   reply still being written is never cut off.
3. It starts `claude --resume <id>` with the next profile's folder.

## What a move looks like

- **Idle session** (the turn is over, no background jobs): it comes back silently and waits for your
  next message. Nothing is lost and no turn runs.
- **Work in flight** (`switch --now`, the hard threshold with move-now on, a usage-limit stop, or a
  transcript that ends without Claude's reply): it comes back with one `[sessionhopper]` message telling
  the agent to redo the interrupted step, restart unfinished subagents and background jobs, and carry on.
  The message lists the background jobs and scheduled tasks that were running.
- **Scheduled tasks**: Claude Code restores `CronCreate` tasks on resume; a self-paced `/loop` and
  wakeups are not restored. The continue message asks the agent to check with `CronList` and re-create
  only what is missing.
- **Your own continue message**: `sessionhopper config prompt --file my-prompt.txt` (placeholders
  `{reason}` `{jobs}` `{crons}` `{from}` `{to}`); `--reset` goes back to the built-in one.

Resuming under another profile works because all profiles share one `projects/` folder, where Claude
Code keeps conversation transcripts. This sharing is not a documented Claude Code interface;
`sessionhopper doctor` checks it.

## Files

Everything lives in `~/Library/Application Support/AgentsSessionHopper/`:

| Path | What |
|---|---|
| `config.json` | profiles (order), thresholds, settings |
| `profiles/<name>.limits.json` | last-known usage per profile |
| `sessions/<id>.*` | live session state (removed when the session ends) |
| `events.jsonl` | the switch log, one JSON object per line, kept 90 days |
| `backups/` | copies of settings.json made by `install-hooks` |
