#!/usr/bin/env bash
# gate.sh — decide whether the PR Diff Visualizer action should run.
#
# Reads (environment):
#   EVENT_NAME         github.event_name
#   HEAD_REPO          full name of the PR's head repository
#   BASE_REPO          full name of the repository the workflow runs in
#   IS_DRAFT           "true" if the PR is a draft
#   HAS_API_KEY        "true" if an Anthropic API key was supplied
#   BASE_BRANCH        branch to compare against (e.g. main)
#   SKIP_PATHS         newline-separated globs; skip if every changed file matches
#   MAX_CHANGED_LINES  skip (with a short comment) above this many changed lines
#
# Writes to $GITHUB_OUTPUT:
#   run        true|false   whether to generate the diagram
#   too_large  true|false   whether to post the "too large" comment instead
#   reason     why it was skipped (empty when run=true)
#   base_ref   the resolved base ref (e.g. origin/main)
#   changed_lines, changed_files
#
# Exit codes: 0 decided (run or skip), 1 setup error (e.g. shallow checkout).

set -euo pipefail

out() {
  echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"
}

skip() {
  echo "::notice title=PR Diff Visualizer::Skipped: $1"
  out run false
  out too_large false
  out reason "$1"
  exit 0
}

fail() {
  echo "::error title=PR Diff Visualizer::$1"
  exit 1
}

# Convert one glob to an anchored regex: **/ = any directories, ** = anything,
# * = anything except "/", ? = one character except "/".
glob_to_regex() {
  local glob=$1 re="" i c
  for ((i = 0; i < ${#glob}; i++)); do
    c=${glob:i:1}
    case $c in
      '*')
        if [[ ${glob:i:3} == '**/' ]]; then
          re+='(.*/)?'; i=$((i + 2))
        elif [[ ${glob:i:2} == '**' ]]; then
          re+='.*'; i=$((i + 1))
        else
          re+='[^/]*'
        fi
        ;;
      '?') re+='[^/]' ;;
      '.' | '+' | '(' | ')' | '[' | ']' | '{' | '}' | '^' | '$' | '|' | '\') re+="\\$c" ;;
      *) re+=$c ;;
    esac
  done
  printf '^%s$' "$re"
}

# --- cheap checks first (no git needed) -------------------------------------

case ${EVENT_NAME:-} in
  pull_request) ;;
  *) skip "not a pull_request event (got '${EVENT_NAME:-}')" ;;
esac

if [[ -n ${HEAD_REPO:-} && ${HEAD_REPO} != "${BASE_REPO:-}" ]]; then
  skip "pull request comes from a fork, where secrets are not available"
fi

[[ ${IS_DRAFT:-false} == true ]] && skip "pull request is a draft"

[[ ${HAS_API_KEY:-false} == true ]] \
  || skip "no Anthropic API key available to this run (e.g. a Dependabot PR)"

# --- resolve the base ------------------------------------------------------

base_branch=${BASE_BRANCH:-}
[[ -n $base_branch ]] || fail "no base branch given"

base_ref=""
for candidate in "origin/$base_branch" "$base_branch"; do
  if git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
    base_ref=$candidate
    break
  fi
done
[[ -n $base_ref ]] \
  || fail "base branch '$base_branch' not found in this checkout; use actions/checkout with fetch-depth: 0"

git merge-base "$base_ref" HEAD >/dev/null 2>&1 \
  || fail "no merge base between '$base_ref' and HEAD; use actions/checkout with fetch-depth: 0"

out base_ref "$base_ref"

# --- what changed ----------------------------------------------------------

mapfile -t files < <(git -c core.quotePath=false diff --name-only "$base_ref...HEAD")
out changed_files "${#files[@]}"
[[ ${#files[@]} -gt 0 ]] || skip "no changes against $base_ref"

regexes=()
while IFS= read -r glob; do
  glob=${glob#"${glob%%[![:space:]]*}"}   # trim leading whitespace
  glob=${glob%"${glob##*[![:space:]]}"}   # trim trailing whitespace
  [[ -n $glob ]] && regexes+=("$(glob_to_regex "$glob")")
done <<< "${SKIP_PATHS:-}"

if [[ ${#regexes[@]} -gt 0 ]]; then
  all_skippable=true
  for f in "${files[@]}"; do
    matched=false
    for re in "${regexes[@]}"; do
      if [[ $f =~ $re ]]; then matched=true; break; fi
    done
    if [[ $matched == false ]]; then all_skippable=false; break; fi
  done
  [[ $all_skippable == true ]] && skip "only files matching skip_paths changed"
fi

# Changed lines, not counting lockfiles, minified files or binaries.
changed_lines=$(git -c core.quotePath=false diff --numstat "$base_ref...HEAD" | awk -F'\t' '
  {
    n = split($3, parts, "/"); name = parts[n]
    if (name ~ /^(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|poetry\.lock|uv\.lock|Pipfile\.lock|Cargo\.lock|Gemfile\.lock|composer\.lock|go\.sum)$/) next
    if (name ~ /\.min\.(js|css)$/) next
    if ($1 == "-") next
    total += $1 + $2
  }
  END { print total + 0 }')
out changed_lines "$changed_lines"

max=${MAX_CHANGED_LINES:-20000}
[[ $max =~ ^[0-9]+$ ]] || fail "max_changed_lines must be a whole number (got '$max')"

if [[ $max -gt 0 && $changed_lines -gt $max ]]; then
  echo "::notice title=PR Diff Visualizer::Too large: $changed_lines changed lines (limit $max)"
  out run false
  out too_large true
  out reason "$changed_lines changed lines is over the limit of $max"
  exit 0
fi

out run true
out too_large false
out reason ""
