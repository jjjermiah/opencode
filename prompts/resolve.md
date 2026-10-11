You are inside an in-progress `git cherry-pick` of one commit from the branch named above, applied onto upstream `dev`. The working tree has merge conflicts. Resolve them.

`git show CHERRY_PICK_HEAD` shows the commit being applied; read it to understand the patch's intent.

Rules:
- Resolve every conflicted file (`git diff --name-only --diff-filter=U`). Keep the patch's intent and upstream's new code; do not drop either side.
- Remove all conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`).
- Edit files outside the conflict only when typecheck requires it.
- Run the typechecks and fix errors until they pass: `bun run typecheck` in `packages/core`, `packages/cli`, `packages/tui`.
- `git add` each resolved file.
- Never commit. Never run `git cherry-pick`, `git push`, `git reset`, `git stash`, `git checkout <ref>`, `git rerere`, or `gh`. Never change branches.
- When every conflicted file is staged and the typechecks pass, stop. The caller continues the cherry-pick.
