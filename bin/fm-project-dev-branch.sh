#!/usr/bin/env bash
# Print the long-lived development branch a project develops on, or nothing.
# Reads the dev:<branch> token from the project's bracket in data/projects.md:
#   - <name> [<mode> +yolo] [dev:<branch>] - <desc> (added <date>)
# The token rides beside the mode bracket, so existing entries keep their
# meaning and a project without the token behaves exactly as today. The branch
# name follows git check-ref-format rules for a branch component; anything else
# is refused with exit 1 so a typo never silently redirects a spawn or a sync.
# Usage: fm-project-dev-branch.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-dev-branch.sh <project-name>}

[ -f "$REG" ] || exit 0

line=$(awk -v n="$NAME" '$1=="-" && $2==n { print; exit }' "$REG")
[ -n "$line" ] || exit 0

token=$(printf '%s\n' "$line" | grep -oE '\[dev:[^]]+\]' | head -1 || true)
[ -n "$token" ] || exit 0
branch=${token#\[dev:}
branch=${branch%\]}

git check-ref-format --branch "$branch" >/dev/null 2>&1 || {
  echo "error: invalid dev branch \"$branch\" for $NAME in $REG" >&2
  exit 1
}
printf '%s\n' "$branch"
