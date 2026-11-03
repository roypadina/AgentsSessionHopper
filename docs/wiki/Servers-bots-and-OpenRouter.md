# Servers, bots and OpenRouter

## OpenRouter as a last fallback

An OpenRouter profile runs the same unmodified `claude` against [OpenRouter](https://openrouter.ai)
with your own OpenRouter API key, through Claude Code's documented
[gateway settings](https://code.claude.com/docs/en/llm-gateway). It is pay per use, so it is used only
when no Claude profile has room, and a session on it is offered the way back as soon as one has.

```bash
sessionhopper profiles add openrouter --openrouter \
  --model opus=anthropic/claude-opus-5 --model sonnet=anthropic/claude-sonnet-5
sessionhopper profiles key openrouter < ~/Downloads/openrouter-key.txt
sessionhopper doctor
```

- **The key** never goes on a command line or into `config.json`. On macOS it is a Keychain item
  (service `agents-session-hopper`, account = the profile name). On Linux it is the systemd credential
  `$CREDENTIALS_DIRECTORY/<profile>` when the service has one (`LoadCredential=`), else
  `~/.config/agents-session-hopper/<profile>.key`, which must be private (mode 600).
  `--key-file <path>` sets your own file instead. The key is handed only to the `claude` it launches.
- **`--model alias=name`** maps Claude Code's aliases to OpenRouter model names (sets
  `ANTHROPIC_DEFAULT_<ALIAS>_MODEL`, and `--model opus` becomes the mapped name).
- **When the key runs out of credit** (HTTP 402), the profile counts as full until the next daily reset
  (00:00 UTC). `--resets weekly|monthly` if your key's limit resets less often.

## Servers, bots and Linux

`sessionhopper run` is for callers that run one non-interactive turn at a time (`claude -p`), such as a
chat bot under systemd. It picks the profile, runs the turn, and when the turn fails on a usage limit it
runs the same turn again on the next profile: Claude profiles in order, OpenRouter last.

```bash
# instead of: claude -p --session-id <uuid> --model opus < prompt.txt
sessionhopper run -- -p --session-id <uuid> --model opus --permission-mode bypassPermissions < prompt.txt
sessionhopper run -- -p --resume <uuid> --model opus --permission-mode bypassPermissions < prompt.txt
```

- Everything after `--` goes to `claude` unchanged. Output is what `claude` would print for your
  `--output-format` (text, json or stream-json); the exit code is `claude`'s.
- Usage comes from `claude`'s own `rate_limit_event` output (it runs with `--output-format
  stream-json` and translates back), so `status` shows real numbers without a status line.
- A retry of a `--session-id` turn continues the same conversation with `--resume`. Every profile must
  share one `projects/` folder (`profiles add` does this; `doctor` checks).
- **Exit 75** means no profile can take the turn right now; stderr names the first reset.

**Linux install** (x86_64, any glibc distribution; the Swift runtime is built in):

```bash
curl -LO https://github.com/roypadina/AgentsSessionHopper/releases/latest/download/sessionhopper-linux-x86_64.tar.gz
tar -xzf sessionhopper-linux-x86_64.tar.gz
install -m 755 sessionhopper-linux-x86_64/sessionhopper ~/.local/bin/
sessionhopper profiles import && sessionhopper doctor
```

State lives in `${XDG_STATE_HOME:-~/.local/state}/agents-session-hopper/`. A systemd service needs no
change other than calling `sessionhopper run --` where it called `claude`; give it the OpenRouter key
with `LoadCredential=openrouter:/path/to/key` (the credential name is the profile name).

## Notes

- `run` adds no hooks and no status line: a one-shot turn has nothing to supervise between turns.
- On a retry, the failed attempt's prompt may already be in the conversation, so the resumed turn can
  show the prompt twice. Claude Code handles that like any repeated message.
- With `--output-format stream-json`, lines from a failed attempt are streamed too, before the retry's.
- Interactive sessions can use an OpenRouter profile as well: it is never picked while a Claude profile
  has room, and `switch openrouter` moves there on request.
- If you run it for a bot or service, check Anthropic's terms for your use case.
