#!/usr/bin/env bash
# collect_diff.sh — gather diff stats between HEAD and its base branch as
# clean, sectioned plain text for the pr-diff-visualizer skill.
#
# Usage: collect_diff.sh [base-branch]
#
# Base resolution order (first match wins):
#   1. the argument (or $PR_DIFF_BASE)   — origin/<name> preferred over <name>
#   2. origin/HEAD (the remote's default branch)
#   3. main                              — origin/main preferred over main
#   4. master                            — origin/master preferred over master
#
# Only committed changes are compared (base...HEAD). Uncommitted changes are
# reported in the UNCOMMITTED section but not included in the diff.
# The script never fetches and never modifies the repository.
#
# Exit codes: 0 ok (including no changes), 1 usage/repo error, 2 base not found,
#             3 no merge base.

set -euo pipefail

OUTPUT_FILE="pr-diff.md"

die() {
  local code=$1; shift
  echo "ERROR: $*" >&2
  exit "$code"
}

section() {
  printf '\n=== %s ===\n' "$1"
}

ref_exists() {
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1
}

# Given a branch name, print the ref to use: origin/<name> if it exists,
# else <name> if it exists. Returns non-zero if neither exists.
resolve_name() {
  local name=$1
  name=${name#refs/heads/}
  # Already remote-qualified (e.g. "origin/develop" or "upstream/main").
  if [[ $name == */* ]] && ref_exists "refs/remotes/$name"; then
    echo "$name"; return 0
  fi
  if ref_exists "refs/remotes/origin/$name"; then
    echo "origin/$name"; return 0
  fi
  if ref_exists "refs/heads/$name"; then
    echo "$name"; return 0
  fi
  if ref_exists "$name"; then          # tag, SHA, or other revision
    echo "$name"; return 0
  fi
  return 1
}

# --- preconditions ---------------------------------------------------------

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 1 "not inside a git work tree"

ref_exists HEAD || die 1 "HEAD has no commits yet"

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# --- resolve base ----------------------------------------------------------

override=${1:-${PR_DIFF_BASE:-}}
base=""
base_source=""

if [[ -n $override ]]; then
  base=$(resolve_name "$override") \
    || die 2 "base branch '$override' not found (tried origin/$override and $override)"
  base_source="user override"
else
  if origin_head=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) \
     && ref_exists "$origin_head"; then
    base=$origin_head
    base_source="origin/HEAD"
  else
    for candidate in main master; do
      if base=$(resolve_name "$candidate"); then
        base_source="default ($candidate)"
        break
      fi
    done
  fi
  [[ -n $base ]] \
    || die 2 "could not find a base branch (tried origin/HEAD, origin/main, main, origin/master, master); pass one explicitly"
fi

merge_base=$(git merge-base "$base" HEAD 2>/dev/null) \
  || die 3 "no common ancestor between '$base' and HEAD"

head_branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || echo "(detached)")

# --- output ----------------------------------------------------------------

section BASE
echo "base_ref: $base"
echo "base_source: $base_source"
echo "base_sha: $(git rev-parse --short "$base")"
echo "merge_base: $(git rev-parse --short "$merge_base")"
if [[ $base == */* ]]; then
  echo "note: remote-tracking ref; run 'git fetch' first if it may be stale"
fi

section HEAD
echo "branch: $head_branch"
echo "head_sha: $(git rev-parse --short HEAD)"
echo "repo_root: $repo_root"

section UNCOMMITTED
# Ignore the skill's own output file so re-runs don't flag themselves.
uncommitted=$(git status --porcelain --untracked-files=normal \
  | grep -v -E "^.. ${OUTPUT_FILE}\$" || true)
if [[ -n $uncommitted ]]; then
  echo "status: dirty (not included in diff)"
  echo "$uncommitted"
else
  echo "status: clean"
fi

section OUTPUT_FILE
if git check-ignore -q "$OUTPUT_FILE" 2>/dev/null; then
  echo "$OUTPUT_FILE: ignored"
else
  echo "$OUTPUT_FILE: not ignored"
fi

if git diff --quiet "$merge_base" HEAD; then
  section RESULT
  echo "NO_CHANGES"
  exit 0
fi

section COMMITS
git log --oneline --no-decorate "$merge_base..HEAD"

section STAT
git diff --stat=200 "$base...HEAD"

section NAME_STATUS
git diff --name-status -M "$base...HEAD"

section NUMSTAT
# added<TAB>deleted<TAB>path ("-" for binary files)
git diff --numstat -M "$base...HEAD"

section RESULT
echo "OK"
