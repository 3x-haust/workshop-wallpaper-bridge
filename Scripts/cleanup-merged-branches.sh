#!/usr/bin/env bash
set -euo pipefail

remote="${1:-origin}"
base="${2:-main}"
base_ref="$remote/$base"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Run this script inside a git work tree." >&2
  exit 1
fi

git fetch --prune "$remote"

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
  echo "Base ref not found: $base_ref" >&2
  exit 1
fi

current_branch="$(git branch --show-current)"
checked_out_branches="$(
  git worktree list --porcelain |
    awk '/^branch / { sub("^refs/heads/", "", $2); print $2 }'
)"

is_checked_out() {
  local branch="$1"
  printf '%s\n' "$checked_out_branches" | grep -Fxq "$branch"
}

is_protected_branch() {
  case "$1" in
    "$base" | main | master | develop | trunk)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

echo "Cleaning branches already merged into $base_ref"

while IFS= read -r branch; do
  [ -n "$branch" ] || continue
  if is_protected_branch "$branch" || [ "$branch" = "$current_branch" ] || is_checked_out "$branch"; then
    echo "skip local: $branch"
    continue
  fi
  echo "delete local: $branch"
  git branch -d "$branch"
done < <(git for-each-ref --format='%(refname:short)' --merged "$base_ref" refs/heads)

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    "$remote/HEAD" | "$base_ref")
      echo "skip remote: $ref"
      continue
      ;;
  esac

  branch="${ref#"$remote/"}"
  if is_protected_branch "$branch"; then
    echo "skip remote: $ref"
    continue
  fi

  echo "delete remote: $branch"
  git push "$remote" --delete "$branch"
done < <(git for-each-ref --format='%(refname:short)' --merged "$base_ref" "refs/remotes/$remote")
