#!/usr/bin/env bash
# verify.sh — after the Claude run, check that pr-diff.md exists and that
# nothing else in the checkout changed.
#
# Reads (environment): WORK_DIR (same as prepare.sh)
# Exit codes: 0 ok, 1 pr-diff.md missing or something else changed.

set -euo pipefail

fail() {
  echo "::error title=PR Diff Visualizer::$1"
  exit 1
}

: "${WORK_DIR:?}"

[[ $(git rev-parse HEAD) == "$(cat "$WORK_DIR/pr-diff-head.txt")" ]] \
  || fail "HEAD moved during the run; refusing to post"

# Compare the working tree before and after, leaving pr-diff.md itself out.
others() {
  grep -v -E '^.. pr-diff\.md$' || true
}
after=$(git status --porcelain --untracked-files=all | others)
before=$(others < "$WORK_DIR/pr-diff-before.txt")

if [[ $after != "$before" ]]; then
  echo "Working tree changes other than pr-diff.md:"
  diff <(echo "$before") <(echo "$after") || true
  fail "files other than pr-diff.md changed during the run; refusing to post"
fi

[[ -s pr-diff.md ]] || fail "the run did not produce pr-diff.md"

echo "pr-diff.md written ($(wc -c < pr-diff.md) bytes); no other files changed."
