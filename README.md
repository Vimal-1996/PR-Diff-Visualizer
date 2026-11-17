# PR-Diff-Visualizer

A Claude Code skill that shows how your current branch differs from its base
branch as a colour-coded Mermaid flowchart, with a short plain-English summary.

- 🟩 added · 🟨 modified · 🟥 deleted
- Draws a small map (at most 12 nodes): one node per changed component, or one
  per area for large PRs, with arrows showing how they depend on each other
- Lists every changed endpoint, class and table in a "What changed" table
- Compares committed changes only (`base...HEAD`) and warns if you have
  uncommitted work
- Writes the result to `pr-diff.md` at the repo root (overwritten each run)

## Install

Copy or symlink the skill into your Claude Code skills directory:

```bash
ln -s "$(pwd)/skills/pr-diff-visualizer" ~/.claude/skills/pr-diff-visualizer
```

Or load this repo as a plugin, without copying anything:

```bash
claude --plugin-dir /path/to/PR-Diff-Visualizer
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

## GitHub Action

The same skill can run on every pull request and post its result as a
comment. The first run creates the comment; later pushes update it, so there
is only ever one.

### Setup

1. Add your Anthropic API key as a repository secret named
   `ANTHROPIC_API_KEY` (Settings → Secrets and variables → Actions).
2. Copy [examples/pr-diff.yml](examples/pr-diff.yml) to
   `.github/workflows/pr-diff.yml` in your repository.

The workflow needs only `contents: read` and `pull-requests: write`, and
must check out with `fetch-depth: 0` so the base branch is available.

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `anthropic_api_key` | (required) | Anthropic API key, from a secret |
| `base_branch` | the PR's base branch | Branch to compare against |
| `model` | `claude-sonnet-5-5` | Claude model that reads the diff |
| `github_token` | `github.token` | Token used to post the comment |
| `skip_paths` | `docs/**` and `**/*.md` | Do nothing if every changed file matches |
| `max_changed_lines` | `20000` | Above this, post a short "too large" note instead; `0` disables |
| `max_turns` | `40` | Upper limit on the steps Claude may take |

### When it does nothing

The action skips quietly, without failing the check, when the pull request
comes from a fork (forks cannot read the secret), is a draft, has no API key
available (for example Dependabot), or only touches files matching
`skip_paths`.

### What Claude is allowed to do

Claude Code runs headless with a fixed allow-list: the skill's collector
script, `git diff`, `git log`, `git show`, reading files, and writing
`pr-diff.md`. Everything else is denied, including pushes, edits to other
files and web access. The GitHub token is not given to that step, settings
checked into the repository are not loaded, and the action refuses to post
if any file other than `pr-diff.md` changed.

Before posting, the diagram is rendered with mermaid-cli. If it has a syntax
error, the comment is still posted, with a warning and the diagram source in
place of a broken diagram.

The diff is written by whoever opened the pull request and is read by the
model, so treat the comment as a reading aid, not as a review.

## Layout

```
action.yml                   # GitHub Action (composite)
action/                      # the action's helper scripts
examples/pr-diff.yml         # workflow to copy into your repository
.github/workflows/pr-diff.yml  # runs the action on this repo's own PRs
.claude-plugin/plugin.json   # plugin manifest
skills/pr-diff-visualizer/
├── SKILL.md                 # skill instructions
└── scripts/collect_diff.sh  # gathers diff stats as sectioned plain text
tests/test_collect_diff.sh   # tests for the script
tests/test_action_scripts.sh # tests for the action's helper scripts
```

## Test

```bash
bash tests/test_collect_diff.sh
bash tests/test_action_scripts.sh
```

The tests build throwaway git repos in a temp directory and check the
script's base resolution, exit codes and output sections. The action tests
replace `gh` and the Mermaid renderer with small fakes, so they need no
network access and no API key.
