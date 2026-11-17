#!/usr/bin/env bash
# Tests for the GitHub Action helper scripts in action/.
#
# Usage: bash tests/test_action_scripts.sh
#
# Everything runs locally: git repos are built in a temp directory, and `gh`
# and the Mermaid renderer are replaced by small fakes. No network, no API key.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
action=$root/action

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

pass=0
fail=0
out=""
code=0

ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; echo "$out" | sed 's/^/       | /'; }

expect_code()  { if [[ $code -eq $1 ]]; then ok "$2"; else bad "$2 (exit $code, wanted $1)"; fi; }
expect_has()   { if grep -qF -- "$1" <<<"$out"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
expect_hasnt() { if grep -qF -- "$1" <<<"$out"; then bad "$2 (unexpected: $1)"; else ok "$2"; fi; }

commit() {  # commit <dir> <file> <message> [lines]
  mkdir -p "$(dirname "$1/$2")"
  seq 1 "${4:-1}" >> "$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "$3"
}

new_repo() {  # new_repo <name> — one commit on main, then a feature branch
  local dir="$tmp/$1"
  git init -q -b main "$dir"
  commit "$dir" app.py "initial"
  git -C "$dir" checkout -q -b feature
  echo "$dir"
}

# ---------------------------------------------------------------------------
echo "gate.sh"

# gate <dir> [VAR=value ...] — run gate.sh with sensible defaults; the output
# file content and the log are both captured in $out.
gate() {
  local dir=$1; shift
  local outfile="$tmp/gate-output"
  : > "$outfile"
  out=$(cd "$dir" && env GITHUB_OUTPUT="$outfile" EVENT_NAME=pull_request \
    HEAD_REPO=me/repo BASE_REPO=me/repo IS_DRAFT=false HAS_API_KEY=true \
    BASE_BRANCH=main SKIP_PATHS=$'docs/**\n**/*.md' MAX_CHANGED_LINES=20000 \
    "$@" bash "$action/gate.sh" 2>&1)
  code=$?
  out+=$'\n'$(cat "$outfile")
}

r=$(new_repo gate)
commit "$r" src/service.py "add service" 10

gate "$r"
expect_code 0 "code change exits 0"
expect_has "run=true" "code change runs"
expect_has "base_ref=main" "reports the base ref"
expect_has "changed_lines=10" "counts changed lines"

gate "$r" EVENT_NAME=push
expect_has "run=false" "non-PR event is skipped"
expect_has "not a pull_request event" "non-PR skip gives the reason"

gate "$r" HEAD_REPO=someone/fork
expect_code 0 "fork PR exits 0 (quiet skip)"
expect_has "run=false" "fork PR is skipped"
expect_has "fork" "fork skip gives the reason"

gate "$r" IS_DRAFT=true
expect_has "run=false" "draft PR is skipped"

gate "$r" HAS_API_KEY=false
expect_code 0 "missing key exits 0 (quiet skip)"
expect_has "run=false" "missing key is skipped"

gate "$r" BASE_BRANCH=nope
expect_code 1 "unknown base fails"
expect_has "fetch-depth: 0" "unknown base points at fetch-depth"

gate "$r" MAX_CHANGED_LINES=5
expect_has "run=false" "over the cap does not run"
expect_has "too_large=true" "over the cap asks for the too-large note"

gate "$r" MAX_CHANGED_LINES=0
expect_has "run=true" "a cap of 0 disables the limit"

commit "$r" package-lock.json "lockfile" 5000
commit "$r" web/app.min.js "bundle" 5000
gate "$r" MAX_CHANGED_LINES=100
expect_has "changed_lines=10" "lockfiles and minified files are not counted"
expect_has "run=true" "lockfile churn does not trip the cap"

r=$(new_repo gate-docs)
commit "$r" docs/guide/intro.md "docs"
commit "$r" README.md "readme"
commit "$r" skills/x/SKILL.md "skill text"
gate "$r"
expect_has "run=false" "docs-only change is skipped"
expect_has "skip_paths" "docs-only skip gives the reason"

gate "$r" SKIP_PATHS='docs/**'
expect_has "run=true" "narrower skip_paths lets Markdown outside docs/ run"

gate "$r" SKIP_PATHS=''
expect_has "run=true" "empty skip_paths never skips"

commit "$r" docs/build.py "script under docs"
commit "$r" src/docs/notes.txt "not the docs folder"
gate "$r"
expect_has "run=true" "a non-matching file makes it run"

r=$(new_repo gate-empty)
gate "$r"
expect_has "run=false" "no changes is skipped"

git clone -q "$tmp/gate" "$tmp/gate-clone"
git -C "$tmp/gate-clone" checkout -q feature 2>/dev/null
gate "$tmp/gate-clone"
expect_has "base_ref=origin/main" "prefers origin/<base> when it exists"

# ---------------------------------------------------------------------------
echo "prepare.sh and verify.sh"

r=$(new_repo prepare)
commit "$r" src/a.py "change"
home="$tmp/home"; work="$tmp/work"; mkdir -p "$home" "$work"

prepare() {
  local outfile="$tmp/prepare-output"
  : > "$outfile"
  out=$(cd "$r" && env HOME="$home" GITHUB_OUTPUT="$outfile" ACTION_PATH="$root" \
    BASE_REF=main HEAD_BRANCH='feature/x' MODEL=claude-sonnet-5-5 MAX_TURNS=40 \
    WORK_DIR="$work" "$@" bash "$action/prepare.sh" 2>&1)
  code=$?
  out+=$'\n'$(cat "$outfile")
}

prepare
expect_code 0 "prepare exits 0"
expect_has "--model claude-sonnet-5-5" "passes the model"
expect_has "--permission-mode dontAsk" "denies anything not allowed"
expect_has "--setting-sources user" "ignores settings from the checkout"
expect_has "Edit(pr-diff.md)" "only pr-diff.md may be written"
expect_hasnt "git push" "no push permission"
if [[ -f $home/.claude/skills/pr-diff-visualizer/SKILL.md \
   && -f $home/.claude/skills/pr-diff-visualizer/scripts/collect_diff.sh ]]; then
  ok "skill is installed under ~/.claude/skills"
else
  bad "skill is installed under ~/.claude/skills"
fi
out=$(cat "$work/pr-diff-prompt.txt")
expect_has "collect_diff.sh main" "prompt names the collector command and base"
expect_has '"feature/x"' "prompt names the PR branch"

prepare MODEL='x; rm -rf /'
expect_code 1 "a model with shell characters is rejected"
prepare HEAD_BRANCH='feat$(whoami)`id`'
out=$(cat "$work/pr-diff-prompt.txt")
expect_hasnt '$(' "branch name is reduced to safe characters"

verify() {
  out=$(cd "$r" && env WORK_DIR="$work" bash "$action/verify.sh" 2>&1)
  code=$?
}

prepare
verify
expect_code 1 "verify fails when pr-diff.md is missing"

echo "# PR Diff" > "$r/pr-diff.md"
verify
expect_code 0 "verify passes when only pr-diff.md was written"

echo "x" > "$r/extra.txt"
verify
expect_code 1 "verify fails when another file appears"
expect_has "extra.txt" "verify names the unexpected file"
rm "$r/extra.txt"

echo "x" >> "$r/src/a.py"
verify
expect_code 1 "verify fails when a tracked file is edited"
git -C "$r" checkout -q -- src/a.py

# ---------------------------------------------------------------------------
echo "validate_mermaid.sh"

cat > "$tmp/mmdc-ok.sh" <<'EOF'
while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && { echo "<svg>fine</svg>" > "$2"; exit 0; }; shift; done
EOF
cat > "$tmp/mmdc-parse.sh" <<'EOF'
echo "Error: Parse error on line 2:" >&2; exit 1
EOF
cat > "$tmp/mmdc-broken.sh" <<'EOF'
echo "Error: Failed to launch the browser process" >&2; exit 1
EOF
cat > "$tmp/mmdc-errsvg.sh" <<'EOF'
while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && { echo '<svg aria-roledescription="error">Syntax error in text</svg>' > "$2"; exit 0; }; shift; done
EOF

cat > "$tmp/in.md" <<'EOF'
# PR Diff: feature vs main

## Diagram

```mermaid
flowchart TD
  a["A"] --> b["B"]
```

**Legend:** text

## Summary

- one
EOF

validate() {  # validate <fake-mmdc> [input]
  local outfile="$tmp/validate-output"
  : > "$outfile"
  out=$(env GITHUB_OUTPUT="$outfile" MMDC="bash $tmp/$1" \
    bash "$action/validate_mermaid.sh" "${2:-$tmp/in.md}" "$tmp/out.md" 2>&1)
  code=$?
  out+=$'\n'$(cat "$outfile")$'\n---\n'$(cat "$tmp/out.md" 2>/dev/null)
}

validate mmdc-ok.sh
expect_code 0 "valid diagram exits 0"
expect_has "mermaid=ok" "valid diagram is reported ok"
expect_has '```mermaid' "valid diagram is kept"
expect_hasnt "could not be rendered" "valid diagram gets no warning"

validate mmdc-parse.sh
expect_code 0 "syntax error still exits 0 so the comment is posted"
expect_has "mermaid=invalid" "syntax error is reported invalid"
expect_has "could not be rendered" "syntax error shows a visible warning"
expect_hasnt '```mermaid' "broken diagram is not posted as a diagram"
expect_has 'a["A"] --> b["B"]' "diagram source is preserved"
expect_has "## Summary" "the rest of the file is kept"

validate mmdc-errsvg.sh
expect_has "mermaid=invalid" "an error image counts as a syntax error"

validate mmdc-broken.sh
expect_code 0 "renderer failure exits 0"
expect_has "mermaid=unvalidated" "renderer failure is reported unvalidated"
expect_has '```mermaid' "unchecked diagram is kept"
expect_has "could not be checked" "unchecked diagram gets a note"

printf '# PR Diff\n\nno diagram here\n' > "$tmp/none.md"
validate mmdc-ok.sh "$tmp/none.md"
expect_has "mermaid=none" "a file without a diagram is reported"

# ---------------------------------------------------------------------------
echo "post_comment.sh"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh: logs each call; "list comments" prints $FAKE_EXISTING_ID.
echo "gh $*" >> "$FAKE_GH_LOG"
for arg in "$@"; do
  case $arg in
    body=@*) cp "${arg#body=@}" "$FAKE_GH_BODY" ;;
  esac
done
if [[ "$*" == *--paginate* ]]; then
  [[ -n ${FAKE_EXISTING_ID:-} ]] && echo "$FAKE_EXISTING_ID"
fi
exit 0
EOF
chmod +x "$tmp/bin/gh"

post() {  # post <body-file> [VAR=value ...]
  local body=$1; shift
  : > "$tmp/gh.log"; : > "$tmp/gh.body"
  out=$(env PATH="$tmp/bin:$PATH" FAKE_GH_LOG="$tmp/gh.log" FAKE_GH_BODY="$tmp/gh.body" \
    GH_TOKEN=fake REPO=me/repo PR_NUMBER=7 HEAD_SHA=abcdef1234567890 "$@" \
    bash "$action/post_comment.sh" "$body" 2>&1)
  code=$?
  out+=$'\n'$(cat "$tmp/gh.log")$'\n---\n'$(cat "$tmp/gh.body")
}

post "$tmp/in.md"
expect_code 0 "first post exits 0"
expect_has "--method POST repos/me/repo/issues/7/comments" "first run creates a comment"
expect_hasnt "PATCH" "first run does not update"
if [[ $(head -n 1 "$tmp/gh.body") == '<!-- pr-diff-visualizer -->' ]]; then
  ok "comment starts with the hidden marker"
else
  bad "comment starts with the hidden marker"
fi
expect_has "for commit abcdef1" "footer names the commit"
expect_has "## Summary" "comment contains the content"

post "$tmp/in.md" FAKE_EXISTING_ID=4242
expect_has "--method PATCH repos/me/repo/issues/comments/4242" "later run updates the same comment"
expect_hasnt "--method POST" "later run does not add a comment"

post "$tmp/in.md" PR_NUMBER='7;echo'
expect_code 2 "a non-numeric PR number is rejected"

{
  cat "$tmp/in.md"
  printf '\n<details>\n<summary>Raw diff stat</summary>\n\n```\n'
  for i in $(seq 1 3000); do echo " src/some/long/path/file_$i.ts | 12 ++++++------"; done
  printf '```\n\n</details>\n'
} > "$tmp/long.md"
post "$tmp/long.md"
expect_code 0 "oversized comment still posts"
expect_hasnt "file_2999.ts" "raw diff stat is dropped from an oversized comment"
expect_has "## Summary" "summary survives the trim"
if [[ $(wc -c < "$tmp/gh.body") -le 65000 ]]; then ok "posted body fits the size limit"; else bad "posted body fits the size limit"; fi

{ cat "$tmp/in.md"; for i in $(seq 1 3000); do echo "- a very long summary line number $i that keeps going"; done; } > "$tmp/huge.md"
post "$tmp/huge.md"
expect_has "cut short" "a body that is still too long is cut with a note"
if [[ $(wc -c < "$tmp/gh.body") -le 65000 ]]; then ok "cut body fits the size limit"; else bad "cut body fits the size limit"; fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
