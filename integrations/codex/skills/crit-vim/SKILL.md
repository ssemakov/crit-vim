---
name: crit-vim
description: Review code changes inside the user's running Neovim using crit-vim. Use when the user asks to review your changes "in vim" or "with crit-vim", or whenever you want structured inline feedback through the vim review surface.
---

# Review with crit-vim

Review and revise code changes using `crit-vim` — a vim-native review loop. The user authors comments in their running Neovim; you read the resulting JSON and address each comment by editing files.

## Prerequisites

`crit-vim` must be on `$PATH` and the user's Neovim must already be running with the crit-vim plugin loaded. Quick check:

```bash
crit-vim doctor
```

If the doctor reports no reachable nvim, ask the user to open Neovim in the repo of interest. **Do not start nvim yourself** — the whole point of crit-vim is to attach to the user's existing editor.

## Step 1: Launch crit-vim and block until the user finishes

**CRITICAL — you MUST run this step. Do NOT proceed without it.**

Run `crit-vim review` in the foreground and block until it exits:

```bash
crit-vim review --base HEAD
```

Set a long timeout — reviews can take 10+ minutes. The command blocks until the user runs `:CritFinish` (or `:CritCancel`) in their nvim. While it's blocked, the user is reading your diff: one tab per changed file, plus a sidebar listing files with comment counts.

Tell the user verbatim:

> **"Review is open in your nvim. Drop comments on the diff, then `:CritFinish` when done."**

**Do NOT proceed until `crit-vim review` exits.** Do NOT ask the user to type anything. Do NOT read the output early. The exit code tells you what happened:

- `0` → user ran `:CritFinish`. JSON is on stdout.
- `1` → user ran `:CritCancel`, or the plugin errored. Read stderr; do not assume comments exist.
- `2` → setup error (no reachable nvim, no diff vs base, plugin not loaded). Read stderr and relay to the user.
- `124` → `--timeout` elapsed. Treat as cancel.

## Step 2: Read the comments

`crit-vim review` printed the JSON to stdout when it exited. If you need to re-read it, `crit-vim status` re-prints the most recent finished review.

Top-level shape:

```json
{
  "files": {
    "path/to/file.go": {
      "status": "modified",
      "comments": [
        {
          "id": "8b13a7f4-...",
          "start_line": 42,
          "end_line": 42,
          "side": "right",
          "scope": "line",
          "body": "this should handle EOF",
          "resolved": false,
          "author": "you@example.com",
          "quote": "for {",
          "anchor": {
            "before": ["..."],
            "body":   ["for {"],
            "after":  ["..."],
            "start_line": 42,
            "end_line": 42
          }
        }
      ]
    }
  },
  "review_comments": []
}
```

Treat every comment as actionable unless `resolved: true` (always `false` in this version — resolve is not implemented).

When a comment has these fields:

- `quote`: the verbatim text the reviewer selected. Focus your change on it rather than the whole line range.
- `anchor`: the lines as they existed when the comment was placed (`before`/`body`/`after` for context). If you've already edited the file and line numbers have shifted, find the content by searching for `anchor.body` rather than trusting `start_line`/`end_line`.
- `side: "right"` is your proposed code (working tree); `side: "left"` is the base version (usually a question about why you removed/changed something).

## Step 3: Address each comment

For each unresolved comment:

1. Read the body and `quote`/`anchor` for context.
2. Edit the referenced file.
3. **There are no inline replies in this version.** Acknowledge the comment by changing the code — the user will see the new state in the next round.

If there are zero comments, the user has approved your change. Stop and inform them.

## Step 4: Next round (optional)

After addressing comments, run `crit-vim review` again in the foreground:

```bash
crit-vim review --base HEAD
```

The plugin auto-cancels any stale session and opens a new review showing your latest changes. Tell the user:

> **"Changes applied. `:CritFinish` again when ready, or `:CritCancel` if everything looks good."**

Loop back to Step 2. The review is approved when the user cancels or finishes with no comments.

## Notes

- **Never modify files while the review is open** — the working tree is what the user is reviewing.
- **`--base`** defaults to `HEAD`. Pass a different ref to review changes since an earlier commit.
- **Files not yet committed**: tracked modifications + untracked-but-present files (treated as added) both show up. The user does not need to `git add`.

---

## Reference

### Subcommands

```bash
crit-vim review [--base REF] [--wait|--no-wait] [--timeout SECS] [--socket PATH]
crit-vim status
crit-vim doctor
```

`crit-vim review` flags:

| Flag | Default | Meaning |
|---|---|---|
| `--base REF` | `HEAD` | Git ref to diff against. |
| `--wait` / `--no-wait` | `--wait` | Block on `:CritFinish` (default) or print the session dir and return. |
| `--timeout SECS` | `14400` (4h) | Max time to block. |
| `--socket PATH` | — | Override nvim socket discovery. |
| `--code` / `--json` | — | Accepted for compatibility; output is always crit-shape. |

### Comment fields

| Field | Type | Notes |
|---|---|---|
| `id` | string | UUIDv4. Stable across rounds. |
| `start_line` / `end_line` | int | 1-based line range. |
| `side` | string | `"right"` (working tree) or `"left"` (base). |
| `scope` | string | Always `"line"` in v0. |
| `body` | string | User-authored. Markdown allowed; default to plain-text reading. |
| `resolved` / `resolved_round` | bool / int | Always `false` / `0` in v0. |
| `replies` | array | Always `[]` in v0. |
| `created_at` | string | ISO-8601 UTC. |
| `author` | string | `git config user.email` of the reviewer. |
| `quote` | string | Verbatim text the user selected. |
| `anchor` | object | `{before, body, after, start_line, end_line}` for drift recovery. |

The top-level `review_comments` array is always empty in v0.

### Socket discovery

`crit-vim` finds the user's nvim in this order: `--socket` flag → `$CRIT_VIM_SOCKET` → `$NVIM` → registry at `~/.crit-vim/sockets/<sha256(repo_root)>`. Run `crit-vim doctor` to see which step matched.

### Not supported in v0

Don't try to use these — they're deliberate omissions:

- `crit-vim comment` (no programmatic comment authoring)
- Inline replies, resolve / unresolve
- File-scope or review-scope comments
- GitHub PR sync, share / unpublish, plan-review mode
- Multi-round in one invocation — re-run `crit-vim review` after editing
