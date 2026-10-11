#!/usr/bin/env bash
# Stack the patch branches listed in patches.txt onto upstream/dev.
#
# usage: scripts/stack.sh <src-dir>
#
# env:
#   PATCHES_FILE  branch list, one origin branch per line (default <script dir>/../patches.txt)
#   RR_CACHE      rerere cache dir copied in at start and out at end (default <script dir>/../.rr-cache)
#   PREPARE_CMD   run in <src-dir> after checking out the base and again after the stack
#   RESOLVE_CMD   run in <src-dir> (env PATCH_BRANCH) while a pick has unresolved conflicts
#   VALIDATE_CMD  run in <src-dir> once per branch after it is fully applied
#
# Writes stack-report.json to $PWD (an old one is removed at start). Leaves <src-dir>
# on local branch `personal`. Exit 0 unless git itself breaks or PREPARE_CMD fails
# (then it exits non-zero; the report is not written if the first PREPARE_CMD fails).
# Note: `checkout -f` discards local edits in <src-dir>; failed branches run `git clean -fdq`
# (untracked, non-ignored files only). User commands run with stdin from /dev/null.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <src-dir>" >&2
  exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$1
PATCHES_FILE=${PATCHES_FILE:-$SCRIPT_DIR/../patches.txt}
RR_CACHE=${RR_CACHE:-$SCRIPT_DIR/../.rr-cache}
PREPARE_CMD=${PREPARE_CMD:-}
RESOLVE_CMD=${RESOLVE_CMD:-}
VALIDATE_CMD=${VALIDATE_CMD:-}
REPORT_FILE=$PWD/stack-report.json
rm -f "$REPORT_FILE"
MERGED_OWNER=jjjermiah

export GIT_EDITOR=true

g() {
  git -C "$SRC" \
    -c rerere.enabled=true -c rerere.autoupdate=true \
    -c user.name=opencode-fork -c user.email=opencode-fork@users.noreply.github.com \
    "$@"
}

log() { echo "stack: $*" >&2; }

# Run a user command string in $SRC, never inheriting our stdin.
run_in_src() {
  (cd "$SRC" && bash -c "$1" </dev/null)
}

# --- rerere cache -----------------------------------------------------------

RR_DIR=$(g rev-parse --git-path rr-cache)
case $RR_DIR in
  /*) ;;
  *) RR_DIR=$SRC/$RR_DIR ;;
esac
mkdir -p "$RR_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SNAP=$TMP/rr

# Copy cache entry directories (skips .gitkeep and other dotfiles).
copy_cache() { # <from> <to>
  local d
  mkdir -p "$2"
  for d in "$1"/*/; do
    [ -d "$d" ] || continue
    cp -R "${d%/}" "$2/"
  done
}

snapshot_cache() {
  rm -rf "$SNAP"
  copy_cache "$RR_DIR" "$SNAP"
}

restore_cache() {
  rm -rf "$RR_DIR"
  copy_cache "$SNAP" "$RR_DIR"
}

copy_cache "$RR_CACHE" "$RR_DIR"

# --- helpers ----------------------------------------------------------------

unmerged_paths() { g diff --name-only --diff-filter=U; }

pick_in_progress() { g rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1; }

has_markers() { # conflict markers in tracked-file changes vs HEAD
  local hits
  hits=$(g diff HEAD -U0 | grep -E '^\+(<{7}|>{7})( |$)' || true)
  [ -n "$hits" ]
}

REPORT='[]'
add_report() { # <branch> <head> <status> <detail>
  REPORT=$(jq -c --arg b "$1" --arg h "$2" --arg s "$3" --arg d "$4" \
    '. + [{branch: $b, head: (if $h == "" then null else $h end), status: $s, detail: $d}]' \
    <<<"$REPORT")
}

REASON=''
USED_RESOLVER=0
REPLAYED=0

# Last two lines of a command's output, on one line.
tail_msg() { printf '%s\n' "$1" | tail -n 2 | tr '\n' ' '; }

# Cherry-pick one commit; resolve conflicts if needed. Sets REASON on failure.
pick_commit() { # <sha>
  local sha=$1 files out
  if out=$(g cherry-pick --empty=drop "$sha" 2>&1); then
    return 0
  fi
  if ! pick_in_progress; then
    REASON="cherry-pick of $sha failed before starting: $(tail_msg "$out")"
    return 1
  fi
  files=$(unmerged_paths)
  if [ -z "$files" ]; then
    REPLAYED=1 # rerere resolved every path on its own
  else
    if [ -z "$RESOLVE_CMD" ]; then
      REASON="conflict picking $sha: $(echo "$files" | tr '\n' ' ')"
      return 1
    fi
    log "conflict at $sha, running RESOLVE_CMD"
    USED_RESOLVER=1
    if ! PATCH_BRANCH=$BRANCH run_in_src "$RESOLVE_CMD" >&2; then
      REASON="RESOLVE_CMD failed at $sha"
      return 1
    fi
    if ! pick_in_progress; then
      REASON="RESOLVE_CMD ended the cherry-pick at $sha"
      return 1
    fi
    files=$(unmerged_paths)
    if [ -n "$files" ]; then
      REASON="unresolved paths after RESOLVE_CMD at $sha: $(echo "$files" | tr '\n' ' ')"
      return 1
    fi
    if has_markers; then
      REASON="conflict markers remain after RESOLVE_CMD at $sha"
      return 1
    fi
    g rerere >/dev/null 2>&1 || true # record the resolution
  fi
  if g diff --cached --quiet; then
    out=$(g cherry-pick --skip 2>&1) || {
      REASON="cherry-pick --skip failed at $sha: $(tail_msg "$out")"
      return 1
    }
  else
    out=$(g cherry-pick --continue 2>&1) || {
      REASON="cherry-pick --continue failed at $sha: $(tail_msg "$out")"
      return 1
    }
  fi
  if pick_in_progress; then
    REASON="cherry-pick still in progress after continue at $sha"
    return 1
  fi
  return 0
}

merged_pr() { # <branch>; prints PR number if merged upstream from MERGED_OWNER
  gh pr list --repo anomalyco/opencode --head "$1" --state merged \
    --json number,headRepositoryOwner 2>/dev/null |
    jq -r --arg o "$MERGED_OWNER" \
      '[.[] | select((.headRepositoryOwner.login // "" | ascii_downcase) == $o)][0].number // empty' ||
    true
}

# --- main -------------------------------------------------------------------

g fetch -q upstream dev
BASE=$(g rev-parse upstream/dev)
g checkout -q -f -B personal upstream/dev
if [ -n "$PREPARE_CMD" ]; then
  log "PREPARE_CMD (base)"
  run_in_src "$PREPARE_CMD" >&2
fi

# Read the list up front so no child command can consume it from stdin.
BRANCHES=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%%#*}
  line=${line//$'\r'/}
  BRANCH=''
  read -r BRANCH _ <<<"$line" || true
  if [ -n "$BRANCH" ]; then BRANCHES+=("$BRANCH"); fi
done <"$PATCHES_FILE"

# A stale sequencer state from an earlier run would break the first pick.
g cherry-pick --quit >/dev/null 2>&1 || true

for BRANCH in ${BRANCHES[@]+"${BRANCHES[@]}"}; do
  log "branch $BRANCH"
  pr=$(merged_pr "$BRANCH")
  if [ -n "$pr" ]; then
    add_report "$BRANCH" "" merged "merged upstream as PR #$pr"
    continue
  fi

  if ! g fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null; then
    add_report "$BRANCH" "" failed "could not fetch origin/$BRANCH"
    continue
  fi

  before=$(g rev-parse HEAD)
  snapshot_cache
  REASON=''
  USED_RESOLVER=0
  REPLAYED=0
  ok=1

  commits=$(g rev-list --reverse --no-merges "upstream/dev..origin/$BRANCH")
  for sha in $commits; do
    if ! pick_commit "$sha"; then
      ok=0
      break
    fi
  done

  picked=0
  if [ "$ok" = 1 ] && [ "$(g rev-parse HEAD)" != "$before" ]; then
    picked=1
    if [ -n "$VALIDATE_CMD" ]; then
      log "VALIDATE_CMD ($BRANCH)"
      if ! PATCH_BRANCH=$BRANCH run_in_src "$VALIDATE_CMD" >&2; then
        ok=0
        REASON="VALIDATE_CMD failed"
      fi
    fi
  fi

  if [ "$ok" = 0 ]; then
    log "failed $BRANCH: $REASON"
    if pick_in_progress; then
      g cherry-pick --abort >/dev/null 2>&1 || true
    fi
    g reset -q --hard "$before"
    g clean -fdq
    restore_cache
    add_report "$BRANCH" "" failed "$REASON"
  elif [ "$picked" = 0 ]; then
    add_report "$BRANCH" "$(g rev-parse HEAD)" empty "no commits to apply"
  elif [ "$USED_RESOLVER" = 1 ]; then
    add_report "$BRANCH" "$(g rev-parse HEAD)" resolved "conflicts resolved by RESOLVE_CMD"
  elif [ "$REPLAYED" = 1 ]; then
    add_report "$BRANCH" "$(g rev-parse HEAD)" applied "applied (rerere replay)"
  else
    add_report "$BRANCH" "$(g rev-parse HEAD)" applied "applied cleanly"
  fi
done

copy_cache "$RR_DIR" "$RR_CACHE"

jq -n --arg base "$BASE" --argjson patches "$REPORT" '{base: $base, patches: $patches}' >"$REPORT_FILE"

if [ -n "$PREPARE_CMD" ]; then
  log "PREPARE_CMD (stack)"
  run_in_src "$PREPARE_CMD" >&2
fi
