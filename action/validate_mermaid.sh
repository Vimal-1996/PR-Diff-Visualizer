#!/usr/bin/env bash
# validate_mermaid.sh — render each Mermaid block in a Markdown file. A block
# that fails to parse is replaced by a visible warning plus its source, so a
# broken diagram is never posted as a diagram.
#
# Usage: validate_mermaid.sh <input.md> <output.md>
#
# Set MMDC to override the renderer command (used by the tests).
#
# Writes to $GITHUB_OUTPUT: mermaid = ok | invalid | unvalidated | none
#   invalid      at least one block had a syntax error (replaced by a warning)
#   unvalidated  the renderer itself could not run; diagrams are left as they
#                are, with a note
# Always exits 0 unless the arguments are wrong: validation must not stop the
# comment from being posted.

set -uo pipefail

[[ $# -eq 2 && -f $1 ]] || { echo "usage: validate_mermaid.sh <input.md> <output.md>" >&2; exit 2; }
input=$1
output=$2

read -r -a mmdc <<< "${MMDC:-npx --yes @mermaid-js/mermaid-cli@12.2.0}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Chromium will not start sandboxed on hosted runners.
echo '{"args": ["--no-sandbox", "--disable-setuid-sandbox"]}' > "$tmp/puppeteer.json"

blocks=$(awk -v prefix="$tmp/block" '
  !inblock && /^[[:space:]]*```mermaid[[:space:]]*$/ {
    inblock = 1; k++; out = prefix "-" k ".mmd"; printf "" > out; next
  }
  inblock && /^[[:space:]]*```[[:space:]]*$/ { inblock = 0; close(out); next }
  inblock { print > out }
  END { print k + 0 }
' "$input")

invalid=""       # comma-separated block numbers with syntax errors
unvalidated=""   # comma-separated block numbers we could not check

for ((k = 1; k <= blocks; k++)); do
  src=$tmp/block-$k.mmd
  svg=$tmp/block-$k.svg
  log=$tmp/block-$k.log

  if "${mmdc[@]}" -q -p "$tmp/puppeteer.json" -i "$src" -o "$svg" >"$log" 2>&1; then
    if [[ -s $svg ]] && ! grep -q -e 'Syntax error in text' -e 'aria-roledescription="error"' "$svg"; then
      echo "diagram $k: ok"
    else
      echo "diagram $k: syntax error (renderer produced an error image)"
      invalid+="${invalid:+,}$k"
    fi
  elif grep -q -i -e 'Parse error' -e 'Lexical error' -e 'Syntax error' \
                  -e 'UnknownDiagramError' -e 'No diagram type detected' "$log"; then
    echo "diagram $k: syntax error"
    grep -i -m 3 -A 3 -e 'Parse error' -e 'Lexical error' -e 'Syntax error' "$log" | sed 's/^/  | /'
    invalid+="${invalid:+,}$k"
  else
    echo "diagram $k: could not be checked (renderer failed to run)"
    head -5 "$log" | sed 's/^/  | /'
    unvalidated+="${unvalidated:+,}$k"
  fi
done

awk -v invalid="$invalid" -v unvalidated="$unvalidated" '
  BEGIN {
    n = split(invalid, a, ","); for (i = 1; i <= n; i++) bad[a[i]] = 1
    n = split(unvalidated, b, ","); for (i = 1; i <= n; i++) unchecked[b[i]] = 1
  }
  !inblock && /^[[:space:]]*```mermaid[[:space:]]*$/ {
    inblock = 1; k++
    if (k in bad) {
      print "> ⚠️ **This diagram could not be rendered** (Mermaid reported a syntax error), so its source is shown instead. The summary and tables below are not affected."
      print ""
      print "<details><summary>Diagram source</summary>"
      print ""
      print "```text"
    } else {
      if (k in unchecked) {
        print "> ℹ️ This diagram could not be checked in this run, so it may not render."
        print ""
      }
      print
    }
    next
  }
  inblock && /^[[:space:]]*```[[:space:]]*$/ {
    inblock = 0
    print
    if (k in bad) { print ""; print "</details>" }
    next
  }
  { print }
' "$input" > "$output"

if [[ $blocks -eq 0 ]]; then
  status=none
elif [[ -n $invalid ]]; then
  status=invalid
elif [[ -n $unvalidated ]]; then
  status=unvalidated
else
  status=ok
fi

echo "mermaid=$status" >> "${GITHUB_OUTPUT:-/dev/stdout}"
case $status in
  invalid) echo "::warning title=PR Diff Visualizer::The diagram has a Mermaid syntax error; posting its source with a warning." ;;
  unvalidated) echo "::warning title=PR Diff Visualizer::Mermaid validation could not run; posting the diagram unchecked." ;;
  none) echo "::warning title=PR Diff Visualizer::pr-diff.md contains no Mermaid diagram." ;;
esac
exit 0
