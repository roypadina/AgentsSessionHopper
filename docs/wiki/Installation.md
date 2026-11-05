# Installation

**Requirements:** macOS 14 Sonoma or later, Apple Silicon or Intel (universal), and
[Claude Code](https://code.claude.com/docs) installed. Usage numbers are shown for Pro and Max plans.

```bash
brew install --cask roypadina/tap/agents-session-hopper
```

This installs `AgentsSessionHopper.app` and links the `sessionhopper` command
(it lives in `AgentsSessionHopper.app/Contents/Helpers/`).

## Linux

x86_64, glibc 2.35 or newer, e.g. Ubuntu 22.04+ or Debian 12+ (the Swift runtime is built in). The CLI only, no menu-bar app:

```bash
curl -LO https://github.com/roypadina/AgentsSessionHopper/releases/latest/download/sessionhopper-linux-x86_64.tar.gz
tar -xzf sessionhopper-linux-x86_64.tar.gz
install -Dm755 sessionhopper-linux-x86_64/sessionhopper ~/.local/bin/sessionhopper
sessionhopper profiles import && sessionhopper doctor
```

State lives in `~/.local/state/agents-session-hopper/`. Uninstall: delete the binary and that folder.
For bots and services see [Servers, bots and OpenRouter](Servers-bots-and-OpenRouter).

## First launch

The app is self-signed, not notarized. If macOS blocks it, open **System Settings → Privacy & Security**
and click **Open Anyway**, or clear quarantine once (this also unblocks the CLI):

```bash
xattr -dr com.apple.quarantine /Applications/AgentsSessionHopper.app
```

On first launch a **Welcome** window explains what the app does and never does, where its icon is and how
to start Claude Code with it. It has an **Open at Login** switch (also in Settings → General) and a
**Set Up Profiles…** button that opens the setup window.

## Uninstall

```bash
sessionhopper uninstall-hooks --profile <name>   # only for profiles where you ran install-hooks
brew uninstall --zap --cask agents-session-hopper
```

Your Claude Code profiles and conversations are not touched.
