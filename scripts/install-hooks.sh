#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR="$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage: scripts/install-hooks.sh [--repo <path>]

Installs Continuum's opt-in git hooks into <repo> (default: this checkout).
The pre-commit hook runs ./scripts/run-matrix.sh --fast from the repository root
and refuses the commit if the fast matrix fails.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "install-hooks: --repo requires a path" >&2; exit 2; }
      REPO_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "install-hooks: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "install-hooks: not a git repository: $REPO_DIR" >&2
  exit 1
fi

git_dir=$(git -C "$REPO_DIR" rev-parse --git-dir)
case "$git_dir" in
  /*) hook_dir="$git_dir/hooks" ;;
  *) hook_dir="$REPO_DIR/$git_dir/hooks" ;;
esac
mkdir -p "$hook_dir"

hook_path="$hook_dir/pre-commit"
if [[ -e "$hook_path" ]] && ! grep -q "Continuum opt-in fast matrix gate" "$hook_path"; then
  backup="$hook_path.continuum-backup.$(date +%Y%m%d%H%M%S)"
  cp "$hook_path" "$backup"
  echo "Existing pre-commit hook backed up to $backup"
fi

cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

# Continuum opt-in fast matrix gate.
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [[ ! -x ./scripts/run-matrix.sh ]]; then
  echo "pre-commit: ./scripts/run-matrix.sh is missing or not executable" >&2
  exit 1
fi

exec ./scripts/run-matrix.sh --fast
HOOK
chmod +x "$hook_path"

echo "Installed Continuum pre-commit hook at $hook_path"
