#!/usr/bin/env bash
set -euo pipefail

# Gate one feature branch before it joins a release candidate (RELEASE.md,
# "Per-feature gate").
#
#   scripts/feature-gate.sh BRANCH --tier 1|2|3 [--base REF] [--legs LEG,...]
#                           [--awake | --skip-awake] [--slug NAME]
#
# Tier 1 runs every leg. Tiers 2 and 3 run the legs scripts/leg-coverage.py says
# the branch reaches (the full matrix when it reaches an unmapped path), plus
# any --legs the author knows the seam needs. Tiers 1 and 2 run the awake
# (display/focus) group too and need an unlocked, awake Mac; --skip-awake runs
# without it and the record lists every awake leg left unverified.
#
# The matrix runs through nightly-gate.sh --feature: the same quiet wait, shared
# lock, warm checkout and environment as the release gate. It never builds a
# candidate and writes nothing a ship reads.
#
# Every run appends to the feature's evidence record,
# ~/array-scratch/release-features/<slug>.md, which also lists what the tier
# still owes by hand (witness output, reviews, stills, a store-copy
# measurement). The script never writes a verdict: the release lead does.
# Exit status: 0 the selected legs are green, 1 red or refused, 2 bad usage.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
usage() { sed -n '6,8p' "$0" | sed 's/^# *//' >&2; exit 2; }
die() { printf 'feature-gate: %s\n' "$*" >&2; exit 1; }

BRANCH="" TIER="" BASE=origin/array/integration EXTRA="" AWAKE="" SLUG=""
[[ $# -gt 0 && "$1" != -* ]] && { BRANCH=$1; shift; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier) [[ $# -ge 2 ]] || usage; TIER=$2; shift 2 ;;
    --base) [[ $# -ge 2 ]] || usage; BASE=$2; shift 2 ;;
    --legs) [[ $# -ge 2 ]] || usage; EXTRA=$2; shift 2 ;;
    --slug) [[ $# -ge 2 ]] || usage; SLUG=$2; shift 2 ;;
    --awake) AWAKE=1; shift ;;
    --skip-awake) AWAKE=0; shift ;;
    *) usage ;;
  esac
done
[[ -n "$BRANCH" && "$TIER" =~ ^[123]$ ]] || usage
[[ -n "$AWAKE" ]] || { [[ "$TIER" == 3 ]] && AWAKE=0 || AWAKE=1; }
[[ -n "$SLUG" ]] || SLUG=$(printf '%s' "${BRANCH#array/}" | tr '/ ' '--')
[[ "$SLUG" =~ ^[A-Za-z0-9._-]+$ ]] || die "slug '$SLUG' must be letters, digits, dot, dash or underscore"

git fetch --quiet origin || die "git fetch origin failed"
SHA=$(git rev-parse --verify "$BRANCH^{commit}") || die "unknown branch $BRANCH"
MERGE_BASE=$(git merge-base "$BASE" "$SHA") || die "$BRANCH shares no history with $BASE"
[[ "$MERGE_BASE" != "$SHA" ]] || die "$BRANCH has no commits beyond $BASE"
RECORDS=${ARRAY_FEATURE_RECORDS:-$HOME/array-scratch/release-features}
mkdir -p "$RECORDS"
RECORD="$RECORDS/$SLUG.md"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/feature-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Which legs. Tier 1 is always every leg.
SELECTION="every leg (tier 1)"
LEGS=""
if [[ "$TIER" != 1 ]]; then
  python3 scripts/leg-coverage.py select "$MERGE_BASE" "$SHA" --json > "$WORK/selection.json" ||
    die "leg-coverage.py could not read $MERGE_BASE..$SHA; run every leg (--tier 1) instead"
  LEGS=$(python3 - "$WORK/selection.json" "$EXTRA" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if d['full']:
    sys.exit(0)  # empty: every leg
extra = [leg.strip() for leg in sys.argv[2].split(',') if leg.strip()]
print('\n'.join(sorted(set(d['legs']) | set(extra))))
PY
)
  SELECTION=$(python3 - "$WORK/selection.json" "$EXTRA" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
extra = [leg for leg in sys.argv[2].split(',') if leg.strip()]
if d['full']:
    print('every leg: ' + '; '.join(d['full_reasons']))
else:
    print(f"{len(d['legs'])} leg(s) from leg-coverage.py" + (f", plus {len(extra)} named by the author" if extra else ''))
PY
)
  if [[ -z "$LEGS" ]] && python3 -c 'import json,sys; sys.exit(0 if not json.load(open(sys.argv[1]))["full"] else 1)' "$WORK/selection.json"; then
    SELECTION="no leg reaches this change (release paths only)"
  fi
fi

echo "feature-gate: $BRANCH ($(git rev-parse --short "$SHA")) tier $TIER; $SELECTION; awake group: $([[ $AWAKE == 1 ]] && echo yes || echo no)"
STATUS=0
if [[ "$SELECTION" == "no leg reaches"* ]]; then
  printf '{"green": true, "passed": 0, "failed": 0, "failed_legs": [], "not_run": [], "commit": "%s"}\n' "$SHA" > "$WORK/feature.json"
else
  ARRAY_NIGHTLY_LEGS="$LEGS" ARRAY_NIGHTLY_AWAKE="$AWAKE" \
    bash scripts/nightly-gate.sh --feature "$SHA" > "$WORK/feature.json" || STATUS=1
fi
[[ -s "$WORK/feature.json" ]] || die "nightly-gate.sh --feature produced no result (lock held, or it could not start)"

python3 - "$RECORD" "$WORK/feature.json" "$SLUG" "$BRANCH" "$SHA" "$MERGE_BASE" "$TIER" "$AWAKE" "$SELECTION" <<'PY'
import datetime as dt, json, sys
from pathlib import Path
record, result, slug, branch, sha, base, tier, awake, selection = sys.argv[1:]
r = json.load(open(result))
TIERS = {
    '1': ('state, persistence, supervisor or agent lifecycle, auth or accounts; anything that can lose work or crash',
          ['RED before and GREEN after, through the production path: both outputs pasted below',
           'Every leg on this branch alone, awake group included (this script, --tier 1)',
           'Two independent reviews given the diff, not the author\'s conclusions: one Codex, one Claude',
           'A measurement on a COPY of a real store, where state or persistence is touched (or why it does not apply)']),
    '2': ('user-visible behaviour: pointer, camera, sidebar, perf',
          ['RED before and GREEN after, through the real event path: both outputs pasted below',
           'Every leg on the touched seams plus the affected legs (this script, --tier 2; add seam legs with --legs)',
           'One independent review given the diff',
           'Light and dark stills, or a short film of the real app: paths below']),
    '3': ('cosmetic or copy',
          ['In-situ render, light and dark: paths below',
           'Targeted legs (this script, --tier 3)',
           'One independent review given the diff']),
}
what, owes = TIERS[tier]
path = Path(record)
if not path.exists():
    lines = [f'# {slug}', '', f'Branch: `{branch}`. Tier {tier}: {what}.', '',
             f'## What tier {tier} requires', '']
    lines += [f'- [ ] {item}' for item in owes]
    lines += ['', '## Matrix runs', '', '## Witness (RED, then GREEN)', '', '## Reviews', '',
              '## Visual evidence and measurements', '', '## Verdict', '',
              'OPEN. The release lead writes PASS or HOLD here, with the reason.', '']
    path.write_text('\n'.join(lines))
text = path.read_text()
green = bool(r.get('green'))
not_run = r.get('not_run') or []
run = [f"### {dt.datetime.now().strftime('%Y-%m-%d %H:%M')}, `{sha[:12]}` on `{base[:12]}`: "
       + ('GREEN' if green else 'RED'), '',
       f"- Selection: {selection}.",
       f"- Awake group: {'run' if awake == '1' else 'NOT run; awake legs below are unverified'}.",
       f"- Passed {r.get('passed', 0)}; failed {r.get('failed', 0)}"
       + (f": {', '.join(r.get('failed_legs') or [])}" if r.get('failed_legs') else '') + '.']
if r.get('known'):
    run.append(f"- Listed known failures: {', '.join(r['known'])}.")
if r.get('retry_passed'):
    run.append(f"- Passed only on serial retry: {', '.join(r['retry_passed'])}.")
if not_run:
    run.append(f"- Selected but not run ({len(not_run)}): {', '.join(not_run)}.")
if r.get('matrix_results'):
    run.append(f"- Results: `{r['matrix_results']}`.")
run.append('')
marker = '## Witness (RED, then GREEN)'
text = text.replace(marker, '\n'.join(run) + '\n' + marker, 1) if marker in text else text + '\n' + '\n'.join(run)
path.write_text(text)
print(f"Record: {record}")
print(f"Still owed by hand for tier {tier}: " + '; '.join(owes[:1] + owes[2:]) + '.')
PY
exit "$STATUS"
