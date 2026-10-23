# Contributing to AgentsSessionHopper

Thanks for your interest! Bug reports, feature ideas, docs and code are all welcome.

## Ground rules

- **`main` is protected.** No direct pushes; changes land via Pull Request and are
  reviewed/merged by the maintainer ([@roypadina](https://github.com/roypadina)).
- Be respectful — see the [Code of Conduct](CODE_OF_CONDUCT.md).
- Keep changes focused. One logical change per PR, smallest diff that solves it.
- **Terms-safe by design.** No code that reads, stores or sends Claude logins or tokens, no
  network calls, no changes to the `claude` binary or its traffic. PRs that add any of these
  will be closed. Usage data comes only from Claude Code's documented status-line input and
  `StopFailure` hook.

## Getting started

```bash
git clone https://github.com/roypadina/AgentsSessionHopper.git
cd AgentsSessionHopper
swift test                 # unit + integration tests (fake `claude` stub, no real sessions)
Scripts/package_app.sh     # builds dist/AgentsSessionHopper.app (CLI in Contents/Helpers)
```

Requirements: **macOS 14+**, Xcode or the Xcode command line tools (Swift 6).

Never test against your real Claude Code profiles. The tests point the engine at temp dirs
through `SESSIONHOPPER_STATE_DIR`, `SESSIONHOPPER_HOME` and `SESSIONHOPPER_CLAUDE_BIN`
(a shell stub that prints status-line and hook payloads). Do the same for manual tries.

## Layout

- `Sources/SessionHopperCore` — the engine: profiles, limits, hand-off policy, hooks,
  status-line bridge, supervisor, doctor. No UI, no network.
- `Sources/sessionhopper` — the CLI.
- `Sources/AgentsSessionHopper` — the SwiftUI menu-bar app.
- `Tests/SessionHopperCoreTests` — unit tests.
- `Tests/SessionHopperIntegrationTests` — runs the built CLI against a fake `claude`.
- `Tests/ScreenshotTests` — renders the app's views offscreen into `docs/screenshots/`.

## Workflow

1. **Fork** and branch: `git checkout -b feat/my-thing`.
2. Make your change; run `swift test`.
3. Match the surrounding style; no drive-by refactors.
4. Open a **Pull Request** against `main`. CI must be green and the maintainer must approve.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org): `feat: ...`, `fix: ...`, `docs: ...`.

## Feature requests and bugs

- **Feature requests:** [open one](https://github.com/roypadina/AgentsSessionHopper/issues/new?template=feature_request.yml) and say what you're trying to do; that matters more than the exact feature. Search the [open requests](https://github.com/roypadina/AgentsSessionHopper/issues?q=is%3Aissue+is%3Aopen+label%3Aenhancement) first and 👍 an existing one if it's there.
- **Bugs:** use the [bug report](https://github.com/roypadina/AgentsSessionHopper/issues/new?template=bug_report.yml).
- **Ko-fi supporters:** add your Ko-fi name to the request and it goes to the front of my queue. It's a thank-you, not a purchase: no promise on what ships or when.
- **Bigger changes:** open an issue before the PR so we agree on the shape first. Small, focused PRs can come straight in.
- Replies are best effort, evenings and weekends. I read everything.
