---
name: pr-diff-visualizer
description: Visualize how the current git branch differs from its base branch as a colour-coded Mermaid flowchart of changed modules, classes, endpoints and DB tables, with a short plain-English summary, saved to pr-diff.md. Use when the user asks to visualize, diagram, map or summarize their PR, branch diff, or "what changed vs main".
---

# PR Diff Visualizer

Produce a Mermaid diagram plus a short summary of how `HEAD` differs from its
base branch, and save it to `pr-diff.md` at the repository root.

## Inputs

- **Base branch** (optional): if the user names one ("vs develop", "against
  release/1.2"), pass it to the script. Otherwise pass nothing and let the
  script resolve it.

## Step 1 — Collect the diff

The script ships inside this skill's folder, not in the user's repo. Locate it
relative to **this skill's base directory** (shown as "Base directory for this
skill" when the skill loads; typically `~/.claude/skills/pr-diff-visualizer`
or `<project>/.claude/skills/pr-diff-visualizer`). Never look for
`scripts/collect_diff.sh` in the current working directory.

Run it with the shell's working directory inside the user's repo (any
subdirectory is fine; the script finds the repo root itself):

```bash
bash "<skill-base-dir>/scripts/collect_diff.sh" [base-branch]
```

Invoke it via `bash` as shown so it works even if the executable bit was lost
during install. Quote the path; it may contain spaces.

It prints labelled sections: `BASE`, `HEAD`, `UNCOMMITTED`, `OUTPUT_FILE`,
`COMMITS`, `STAT`, `NAME_STATUS`, `NUMSTAT`, `RESULT`.

- Non-zero exit: report the error message to the user and stop. Don't guess a
  different base unless the user asks.
- `RESULT` is `NO_CHANGES`: tell the user the branch has no committed changes
  vs the base (mention uncommitted changes if listed) and stop; don't write
  `pr-diff.md`.

The script resolves the base in this order: user override → `origin/HEAD` →
`main` → `master`, preferring `origin/<name>` over a local `<name>`. It never
fetches.

## Step 2 — Read the changes that matter

Use `NAME_STATUS` and `NUMSTAT` to pick files, then read their diffs with
`git diff <base_ref>...HEAD -- <path>` (use `base_ref` from the `BASE` section).

- Skip noise: lockfiles, generated/minified files, vendored code, snapshots,
  binary files (`-` in `NUMSTAT`). Count them, but don't diagram them
  individually.
- For large PRs, prioritise by lines changed and by structural significance
  (new/deleted files, public interfaces, routes, migrations).

## Step 3 — Identify components and dependencies

Classify each meaningful change into one of:

| Kind | How to spot it |
|------|----------------|
| **Module** | a file or package/directory with changed code |
| **Class** | added/removed/changed class, struct, interface, type |
| **Endpoint** | route decorators/registrations (`@app.get`, `router.post`, `@GetMapping`, `urls.py`, etc.) — label as `METHOD /path` |
| **DB table** | migrations, `CREATE/ALTER/DROP TABLE`, ORM model definitions |

Status per node:
- **added** — new file or new symbol
- **modified** — existing symbol changed; renames (`R` in `NAME_STATUS`) count
  as modified and are labelled `old → new`
- **deleted** — removed file or symbol

Dependencies: draw an edge `A --> B` when changed code in A imports, calls,
queries or exposes B (e.g. endpoint → service → model → table). Only include
edges you can see evidence for in the diff or the touched files; unchanged
components that are needed to explain an edge may appear as plain
(unstyled) nodes.

## Step 4 — Build the Mermaid flowchart

- Use `flowchart LR`.
- One `subgraph` per module/directory.
- Keep node IDs simple (`n1`, `svc_user`); put readable text in labels and
  quote labels containing special characters: `n1["POST /users"]`.
- Cap at ~30 nodes. Beyond that, collapse small changes into one node per
  directory (e.g. `"utils/ (4 files modified)"`).
- Apply these classes exactly:

```mermaid
classDef added fill:#d4edda,stroke:#28a745,color:#155724
classDef modified fill:#fff3cd,stroke:#d4a017,color:#856404
classDef deleted fill:#f8d7da,stroke:#dc3545,color:#721c24
```

Assign with `class n1,n2 added` etc. Include a small legend subgraph with one
node per status.

## Step 5 — Write the summary

3–5 plain-English lines: what the PR does, the main areas touched, and
anything a reviewer should watch (schema changes, deleted endpoints,
breaking interface changes, missing tests). No jargon beyond what the code uses.

## Step 6 — Save `pr-diff.md`

Write to `<repo_root>/pr-diff.md` (`repo_root` from the `HEAD` section),
overwriting any existing file. **Never edit `.gitignore` or any other file in
the user's repo.** Use this layout:

````markdown
# PR Diff: <branch> vs <base_ref>

**Base:** `<base_ref>` (<base_source>) · **Merge base:** `<merge_base>` · **Head:** `<head_sha>` · **Commits:** <n>

> ⚠️ Uncommitted changes present — not included in this diagram.   ← only if UNCOMMITTED is dirty

## Diagram

```mermaid
flowchart LR
  ...
```

## Summary

- ...

<details>
<summary>Raw diff stat</summary>

```
<STAT section>
```

</details>
````

## Step 7 — Report back

In your reply to the user:
- the base used and where it came from (first line)
- the summary
- the path to `pr-diff.md`
- if uncommitted changes exist, say they were not included
- if `OUTPUT_FILE` says `not ignored`, mention they may want to add
  `pr-diff.md` to `.gitignore` — do not do it yourself
