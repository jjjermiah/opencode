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
- Green run: release `v<upstream version>-jjj.<run>.<attempt>` with `opencode-darwin-arm64.tar.gz`. Red run: issue `nightly failed`; the summary says `upstream red` or `patches red`.

## Schedule auto-disable

GitHub disables scheduled workflows after 60 days without repo activity. Re-enable: `gh workflow enable nightly`, or Actions tab → nightly → Enable workflow. Repo activity such as a push to `fork` should reset the timer (unverified for manual dispatch).
