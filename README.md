# PR-Diff-Visualizer

A Claude Code skill that shows how your current branch differs from its base
branch as a colour-coded Mermaid flowchart, with a short plain-English summary.

- 🟩 added · 🟨 modified · 🟥 deleted
- Groups changes into modules, classes, endpoints and DB tables, with arrows
  showing how they depend on each other
- Compares committed changes only (`base...HEAD`) and warns if you have
  uncommitted work
- Writes the result to `pr-diff.md` at the repo root (overwritten each run)

## Install

Copy or symlink the skill into your Claude Code skills directory:

```bash
ln -s "$(pwd)/skills/pr-diff-visualizer" ~/.claude/skills/pr-diff-visualizer
```

## Use

In Claude Code, inside any git repo:

- "Visualize my PR"
- "Show what changed on this branch vs develop"

The base branch is resolved in this order: your override → `origin/HEAD` →
`main` → `master`, preferring the remote-tracking branch (e.g. `origin/main`)
over a local one. The base used is printed at the top of the output. Run
`git fetch` first if your remote refs may be stale.

You may want to add `pr-diff.md` to your repo's `.gitignore`. The skill won't
do this for you.

## Layout

```
skills/pr-diff-visualizer/
├── SKILL.md                 # skill instructions
└── scripts/collect_diff.sh  # gathers diff stats as sectioned plain text
tests/                       # evals (coming later)
```
