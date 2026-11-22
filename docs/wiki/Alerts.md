# Alerts

AgentsSessionHopper can tell you, on your Mac and on your phone, when something happens to your profiles:

| Kind | When |
|---|---|
| `switch` | Sessions left a profile on their own (usage limit, login, threshold) and continue on another one. Names both. |
| `no-room` | No profile has room: a session waits for a reset or stopped. On by default as a Mac notification. |
| `usage-warning` | A profile passed the suggest threshold (85% by default). |
| `usage-critical` | A profile passed the park threshold (97% by default). |

A move you asked for yourself (menu, notification, `switch`) is not an alert.

## Where they go

- **Mac**: a notification from the menu-bar app (it must be running).
- **ntfy**: a push to [ntfy](https://ntfy.sh) on ntfy.sh or your own server, sent by `sessionhopper` itself,
  so it works on Linux servers too.

```bash
sessionhopper alerts ntfy https://ntfy.sh < topic.txt  # the topic on stdin (or as a 2nd argument); or your own server
sessionhopper alerts ntfy token < token.txt            # optional access token (Keychain / private file)
sessionhopper alerts ntfy fallback < url.txt           # optional 2nd topic URL, used only when a post fails
sessionhopper alerts test                              # a test alert on every channel set up
sessionhopper alerts ntfy off                          # stop, and forget the token and fallback
```

The token and the fallback URL are kept in the Keychain (macOS) or a private file (Linux). The topic itself
sits in plain `config.json` in the state folder: on ntfy.sh, where the topic name is the only lock, keep that
folder private. Each push holds the alert text (profile names, usage percent), this machine's short host name
and the path of its send log; anyone who knows a public topic can read them. Every send attempt is one line
in `ntfy.log` in the state folder (`topic=primary` or `topic=fallback`, never the topic name).

In the app: Settings → Alerts. It applies as you type; clear the topic to turn ntfy off.

## Per profile, per kind, per channel

Every kind is switched on or off for each profile, as a Mac notification and as an ntfy push. A box under
**All Profiles** sets it for every profile; a profile's own box overrides it.

```bash
sessionhopper alerts set all switch mac on ntfy on
sessionhopper alerts set work usage-critical ntfy on
sessionhopper alerts set personal all mac off ntfy off
sessionhopper alerts                                   # the table of what goes where
```

**Only with a session here** (`active-only`, on by default) holds usage alerts back while no session on
this Mac runs on that profile. An account you also use somewhere else can fill up without anything here
being affected, and that should not wake you.

## One alert, not twenty

Five sessions on one profile hitting its limit together move one after another. They give **one** alert,
and that profile then stays quiet for moves until its full window resets. "No profile has room" stays
quiet until the first profile frees up. A usage alert comes once per profile, window and level, and after
a critical one the warning does not follow. The memory sits in the state folder under a lock, so every
session, hook and the app share it.

`sessionhopper alerts log` lists what fired and where it went.
