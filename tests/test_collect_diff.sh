#!/usr/bin/env bash
# Tests for skills/pr-diff-visualizer/scripts/collect_diff.sh
#
# Usage: bash tests/test_collect_diff.sh
#
# Builds throwaway git repos under a temp directory; never touches this repo.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/../skills/pr-diff-visualizer/scripts/collect_diff.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Isolate from the user's git configuration.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset PR_DIFF_BASE

pass=0
fail=0
out=""
code=0

# run <dir> [args...] — runs the script in <dir>, capturing $out and $code.
run() {
  local dir=$1; shift
  out=$(cd "$dir" && bash "$script" "$@" 2>&1)
  code=$?
}

ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; echo "$out" | sed 's/^/       | /'; }

expect_code()   { if [[ $code -eq $1 ]]; then ok "$2"; else bad "$2 (exit $code, wanted $1)"; fi; }
expect_has()    { if grep -qF -- "$1" <<<"$out"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
expect_hasnt()  { if grep -qF -- "$1" <<<"$out"; then bad "$2 (unexpected: $1)"; else ok "$2"; fi; }

commit() {  # commit <dir> <file> <message>
  mkdir -p "$(dirname "$1/$2")"
  echo "$3" >> "$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "$3"
}

# new_repo <name> — repo with one commit on main, then a feature branch
# with one extra commit.
new_repo() {
  local dir="$tmp/$1"
  git init -q -b main "$dir"
  commit "$dir" app.py "initial"
  git -C "$dir" checkout -q -b feature
  commit "$dir" src/service.py "add service"
  echo "$dir"
}

echo "preconditions"
mkdir "$tmp/notrepo"
run "$tmp/notrepo"
expect_code 1 "outside a repo exits 1"

git init -q -b main "$tmp/empty"
run "$tmp/empty"
expect_code 1 "repo without commits exits 1"

echo "base resolution"
r=$(new_repo basic)
run "$r"
expect_code 0 "feature branch exits 0"
expect_has "base_ref: main" "falls back to local main"
expect_has "base_source: default (main)" "reports the base source"
expect_has "branch: feature" "reports the head branch"
expect_has $'A\tsrc/service.py' "lists the added file"
expect_has "add service" "lists the commit"
expect_has "OK" "RESULT is OK"
expect_hasnt "remote-tracking" "no stale-ref note for a local base"

run "$r/src"
expect_code 0 "works from a subdirectory"

run "$r" nope
expect_code 2 "unknown override exits 2"

git init -q -b trunk "$tmp/nobase"
commit "$tmp/nobase" a.txt "initial"
run "$tmp/nobase"
expect_code 2 "no main/master exits 2"

git -C "$r" checkout -q main
git -C "$r" checkout -q -b release/1.2
git -C "$r" checkout -q feature
run "$r" release/1.2
expect_code 0 "local base with a slash resolves"
expect_has "base_ref: release/1.2" "uses the local slash-named branch"
expect_has "base_source: user override" "reports the override"
expect_hasnt "remote-tracking" "slash-named local base is not called remote"

PR_DIFF_BASE=release/1.2 run "$r"
expect_has "base_ref: release/1.2" "PR_DIFF_BASE is honoured"

git -C "$r" checkout -q main
run "$r"
expect_code 0 "no changes exits 0"
expect_has "NO_CHANGES" "RESULT is NO_CHANGES on the base itself"
git -C "$r" checkout -q feature

echo "remote base"
git clone -q "$r" "$tmp/clone"
git -C "$tmp/clone" checkout -q feature 2>/dev/null
run "$tmp/clone"
expect_code 0 "clone exits 0"
expect_has "base_ref: origin/" "prefers the remote-tracking base"
expect_has "remote-tracking" "notes that a remote base may be stale"
run "$tmp/clone" main
expect_has "base_ref: origin/main" "override prefers origin/<name>"

echo "shallow clone"
git clone -q --depth 1 --no-single-branch "file://$r" "$tmp/shallow"
git -C "$tmp/shallow" checkout -q feature 2>/dev/null
run "$tmp/shallow" main
expect_code 3 "shallow clone without a merge base exits 3"
expect_has "shallow clone" "error names the shallow clone"
expect_has "git fetch --unshallow" "error suggests the fix"

git init -q -b main "$tmp/unrelated"
commit "$tmp/unrelated" a.txt "initial"
git -C "$tmp/unrelated" checkout -q --orphan other
commit "$tmp/unrelated" b.txt "unrelated root"
run "$tmp/unrelated"
expect_code 3 "unrelated histories exit 3"
expect_has "no common ancestor" "error names the missing ancestor"
expect_hasnt "shallow" "full clone is not called shallow"

echo "output file and uncommitted changes"
r=$(new_repo output)
run "$r"
expect_has "status: clean" "clean tree reported clean"
expect_has "pr-diff.md: not ignored" "untracked output file is not ignored"

echo "generated" > "$r/pr-diff.md"
run "$r"
expect_has "status: clean" "the output file does not make the tree dirty"

echo "x" > "$r/pr-diffXmd"
run "$r"
expect_has "status: dirty" "a similarly named file still counts as dirty"
expect_has "pr-diffXmd" "the similarly named file is listed"
rm "$r/pr-diffXmd"

echo "pr-diff.md" > "$r/.gitignore"
git -C "$r" add .gitignore
git -C "$r" commit -q -m "ignore output"
run "$r"
expect_has "pr-diff.md: ignored" "ignored output file is reported"

git -C "$r" add -f pr-diff.md
git -C "$r" commit -q -m "track output"
run "$r"
expect_has "pr-diff.md: tracked" "tracked output file is reported"

echo "unusual filenames"
r=$(new_repo names)
commit "$r" "docs/my notes.md" "add notes"
commit "$r" "docs/résumé.md" "add resume"
run "$r"
expect_has $'A\tdocs/my notes.md' "path with a space is listed verbatim"
expect_has $'A\tdocs/résumé.md' "non-ASCII path is not octal-escaped"
echo "x" > "$r/naïve file.txt"
run "$r"
expect_has "naïve file.txt" "non-ASCII uncommitted path is readable"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
