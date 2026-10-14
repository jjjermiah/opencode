# opencode fork automation (`fork` branch)

Orphan branch holding only CI. A nightly workflow stacks personal patch branches onto `upstream/dev`, gates, builds a macOS arm64 binary, and publishes a GitHub Release. Nothing upstream-derived is ever pushed.

## Layout

- `patches.txt`: branches of `origin` to apply, top to bottom. `#` comments and blank lines ignored.
- `scripts/stack.sh`: stacks the patches (cherry-pick, rerere, agent conflict resolution), writes `stack-report.json`.
- `prompts/resolve.md`: instructions for the conflict-resolving agent.
- `.rr-cache/`: rerere resolutions, committed back to `fork` by CI after a green gate.
- `.github/workflows/nightly.yml`: workflow `nightly`.

## Patches

- Add: push the branch to `origin`, then add its name on a new line in `patches.txt`.
- Remove: delete its line. A patch merged upstream is detected and reported as `merged`; remove its line afterwards.
- Failures open an issue `patch failed: <branch>` (label `patch-failure`); it closes itself once the patch applies again.

## Setup

- Repo secret `ANTHROPIC_API_KEY` (conflict-resolving agent, `anthropic/claude-sonnet-5-5`).
- `fork` must be the default branch (scheduled workflows only run there).
- Actions are disabled by default on forks: enable them in the Actions tab.
- The fork inherits upstream's workflows, which would run on every patch-branch push. Disable them: `gh workflow list --repo jjjermiah/opencode`, then `gh workflow disable <id> --repo jjjermiah/opencode` for each except `nightly`. Re-check after pushing a rebased patch branch, since new upstream workflow files get registered then.

## Run

- Nightly at 06:00 UTC, or manually: `gh workflow run nightly --ref fork`.
- Green run: release `v<upstream version>-jjj.<run>.<attempt>` with `opencode-darwin-arm64.tar.gz`. Gate: typecheck must pass; core tests may fail only where the same tests also fail on the upstream base (those are listed under "Known upstream failures" in the release notes). Red run: issue `nightly failed`; the summary says `patches red`, `upstream red` (typecheck) or `gate error` (test run produced no usable result).

## Schedule auto-disable

GitHub disables scheduled workflows after 60 days without repo activity. Re-enable: `gh workflow enable nightly`, or Actions tab → nightly → Enable workflow. Repo activity such as a push to `fork` should reset the timer (unverified for manual dispatch).

## On the Mac

- Install with `opencode-fork update` from a plain terminal (it refuses inside an OpenCode session).
- The fork builds on channel `latest` and reports the plain upstream version (e.g. `2.0.29`; the run number lives only in the release tag, and `update` records it in `~/.local/state/opencode-fork/installed-tag`). It shares `service.json`, port 49374 and `opencode.db` with OpenCode.app, so the app and the fork TUI talk to one server.
- OpenCode.app's "Install CLI" button overwrites the fork binary. When upstream releases a newer version than the fork binary, the app's bundled CLI may replace the shared server until the next nightly catches up; the autoupdater stays off (`update: disable`, `OPENCODE_DISABLE_AUTOUPDATE=1`).
- Fresh Mac: run `mkdir -p ~/Library/LaunchAgents` before the first `dotfiles-stow`, or stow folds the whole directory into the repo.
