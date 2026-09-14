#!/usr/bin/env bash
# Report every bench (worktree) and whether it is safe to return.
#
# WHY THIS EXISTS. Parallel tickets are the point of this repo, and each one
# leaves a bench behind: a worktree, its .build, its qa-runs. Nothing reclaims
# them, so on 2026-09-13 there were 55 worktrees across seven roots holding
# ~185GB, and reconstructing which were safe to delete took twelve agents an
# hour. This is that hour, as one command.
#
# WHY SUBJECT MATCHING, NOT `git cherry`. `git cherry` and `branch --no-merged`
# compare patch-ids. Work that lands via cherry-pick, squash or an adapted
# rebase gets a different patch-id, so both report it unmerged forever: all
# eight commits on array/transcript-renovation read as orphaned for three weeks
# after every one of them had shipped. A commit whose SUBJECT appears in the
# upstream log landed under a new sha. Subjects are how the work is actually
# traced here, so that is what this checks.
#
#   scripts/benches.sh            # report
#   scripts/benches.sh --safe     # print only the slugs safe to remove
#
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

UPSTREAM=origin/array/integration
git rev-parse --verify --quiet "$UPSTREAM" >/dev/null || UPSTREAM=array/integration

SAFE_ONLY=0
[[ "${1:-}" == "--safe" ]] && SAFE_ONLY=1

HOME_DIR="$ROOT_DIR/.worktrees"

# Did every commit unique to $ref reach $UPSTREAM, by sha or by subject?
landed() {
  local ref="$1" sha subject
  git merge-base --is-ancestor "$ref" "$UPSTREAM" 2>/dev/null && return 0
  local unique
  unique=$(git rev-list "$UPSTREAM..$ref" 2>/dev/null) || return 1
  [[ -z "$unique" ]] && return 0
  while read -r sha; do
    [[ -z "$sha" ]] && continue
    subject=$(git log -1 --format=%s "$sha")
    git log "$UPSTREAM" --format=%s --fixed-strings --grep="$subject" \
      | grep -Fqx -- "$subject" || return 1
  done <<<"$unique"
  return 0
}

safe=() review=()

while IFS= read -r line; do
  path=${line%% *}
  [[ "$path" == "$ROOT_DIR" ]] && continue
  slug=$(basename "$path")

  # An independent clone keeps its own object store, so its commits exist
  # nowhere else. Never a candidate for removal from this script.
  if [[ -d "$path/.git" ]]; then
    review+=("$slug|CLONE — isolated history, not a worktree|$path")
    continue
  fi

  dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  ref=$(git -C "$path" rev-parse HEAD 2>/dev/null || echo "")
  branch=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "detached")

  reason=""
  [[ "$dirty" != "0" ]] && reason="$dirty uncommitted"
  if ! landed "$ref"; then
    ahead=$(git rev-list --count "$UPSTREAM..$ref" 2>/dev/null || echo "?")
    reason="${reason:+$reason; }$ahead commits not upstream"
  fi
  [[ "$path" != "$HOME_DIR"/* ]] && reason="${reason:+$reason; }off-home"

  if [[ -z "$reason" ]]; then
    safe+=("$slug|$branch|$path")
  else
    review+=("$slug|$reason|$path")
  fi
done < <(git worktree list)

# A clone under .worktrees/ never appears in `git worktree list`, which is
# precisely why six of them sat there unnoticed until a full-disk audit. Scan
# the directory itself so they cannot hide behind git's own inventory.
if [[ -d "$HOME_DIR" ]]; then
  for path in "$HOME_DIR"/*/; do
    path=${path%/}
    [[ -d "$path/.git" ]] || continue
    slug=$(basename "$path")
    head=$(git -C "$path" rev-parse HEAD 2>/dev/null || echo "")
    if [[ -n "$head" ]] && git cat-file -e "$head^{commit}" 2>/dev/null; then
      review+=("$slug|CLONE — history also in canonical repo|$path")
    else
      review+=("$slug|CLONE — history EXISTS NOWHERE ELSE|$path")
    fi
  done
fi

if (( SAFE_ONLY )); then
  printf '%s\n' "${safe[@]+"${safe[@]}"}" | cut -d'|' -f3
  exit 0
fi

printf '\n=== SAFE TO RETURN (%d) — landed upstream, clean ===\n' "${#safe[@]}"
for e in ${safe[@]+"${safe[@]}"}; do
  IFS='|' read -r slug branch path <<<"$e"
  printf '  %-32s %s\n' "$slug" "$branch"
done
[[ ${#safe[@]} -gt 0 ]] && printf '\n  git worktree remove <path>   # refuses if dirty; trust the refusal\n'

printf '\n=== NEEDS A LOOK (%d) ===\n' "${#review[@]}"
for e in ${review[@]+"${review[@]}"}; do
  IFS='|' read -r slug reason path <<<"$e"
  printf '  %-32s %s\n' "$slug" "$reason"
done

if [[ -d qa-runs ]]; then
  runs=$(find qa-runs -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')
  printf '\n=== qa-runs: %s runs, %s ===\n' "$runs" "$(du -sh qa-runs | cut -f1)"
  printf '  find qa-runs -maxdepth 1 -mindepth 1 -mtime +7 -exec rm -rf {} +\n'
fi
printf '\n'
