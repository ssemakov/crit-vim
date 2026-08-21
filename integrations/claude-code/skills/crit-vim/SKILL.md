---
name: crit-vim
description: Review code changes inside the user's running Neovim using crit-vim (attaches to a crit daemon; supports threaded replies + resolve). Use when the user asks to review your changes "in vim", "with crit-vim", or whenever you want structured inline feedback via the vim review surface.
allowed-tools: Bash(crit-vim:*), Bash(crit:*), Bash(curl:*), Read, Edit, MultiEdit, Grep, Glob
argument-hint: "[--base REF]"
---

# Review with crit-vim

Review and revise code changes using `crit-vim` — an nvim-native client for [tomasz-tomczyk/crit](https://github.com/tomasz-tomczyk/crit). The user authors comments (and reply threads) in Neovim; you read them, address them, and reply — all through crit's daemon.

## Ground rule

**Never edit `~/.crit/reviews/*/review.json` directly.** The daemon owns that file with atomic writes and SSE notifications; hand-editing it races the daemon, breaks the browser + nvim views, and skips ID generation. Always mutate through:

- The `crit` CLI (`crit comment ...`) — the ergonomic path; covers 90 % of cases.
- The daemon HTTP API (`http://127.0.0.1:<port>/api/*`) — for update / delete / standalone resolve.

`crit comments --json` is the canonical way to READ the review state.

## Prerequisites

Both `crit` (the daemon binary) and `crit-vim` (the nvim client CLI) must be on `$PATH`, and the user's Neovim must be running with the crit-vim plugin loaded. Quick check:

```bash
crit-vim doctor
```

If the doctor reports no reachable nvim, ask the user to open Neovim in the repo of interest. **Do not start nvim yourself** — the whole point of crit-vim is to attach to the user's existing editor.

## Step 1: Launch crit-vim and block until the user finishes

**CRITICAL — you MUST run this step. Do NOT proceed without it.**

Run `crit-vim review` **in the background** using `run_in_background: true`:

```bash
crit-vim review
```

`crit-vim review`:
- spawns a `crit --no-open` daemon for this repo+branch (or attaches if one is already running),
- tells nvim to attach to it, and
- blocks until the user runs `:CritFinish` or `:CritCancel` in nvim (or hits Approve in a browser tab, if they opened one).

Useful flags:
- `--base HEAD` — narrow to the user's uncommitted work (implies `--scope unstaged`).
- `--scope unstaged|staged|branch|all` — narrow explicitly; `unstaged` is usually what "just my current work" means on a feature branch. Without a scope, crit defaults to the whole branch vs its base branch, which on long-lived branches surfaces every committed change.

Tell the user verbatim:

> **"Review is open in your nvim. Drop comments on the diff, then `:CritFinish` when done."**

**Do NOT proceed until the background task completes.** When the task completes, the exit code tells you what happened:

- `0` → user finished the review. JSON is on stdout (via `crit comments --json`).
- `1` → user cancelled (`:CritCancel`), or the crit binary is missing. **No comments are printed.** Do NOT infer intent from any comments already in the review file — the user explicitly rejected this round.
- `2` → setup error (no reachable nvim, daemon didn't come up). Read stderr and relay to the user.
- `124` → `--timeout` elapsed. Treat as cancel.

## Step 2: Read the comments

The completed `crit-vim review` prints the JSON to stdout. If you need to re-read, run `crit comments --json`.

Top-level shape (crit v4 review file):

```json
{
  "branch": "feat/foo",
  "base_ref": "abc123...",
  "review_round": 2,
  "files": {
    "path/to/file.go": {
      "status": "modified",
      "comments": [
        {
          "id": "c_1df20f",
          "start_line": 42, "end_line": 42,
          "side": "",  "scope": "line",
          "body": "this should handle EOF",
          "quote": "for {",  "anchor": "for {",
          "resolved": false,  "resolved_round": 0,
          "replies": [
            {"id": "rp_ab12", "body": "acknowledged, will fix", "author": "you", "created_at": "..."}
          ],
          "created_at": "...", "updated_at": "..."
        }
      ]
    }
  },
  "review_comments": []
}
```

Rules:
- `resolved: true` → the thread is closed. Skip unless the user asks otherwise.
- `resolved: false` → actionable. Read the whole thread — parent `body` PLUS every `replies[].body`. Latest reply usually clarifies the ask.
- `side: ""` (or `"right"`) → comment is on your proposed code.
- `side: "old"` (or `"left"`) → comment is on the base — usually a question about a removal.
- `quote`: verbatim text the user selected — focus edits there.

## Step 3: Reply to every comment BEFORE editing anything

**Reply first. Edit second. This order is not optional.**

A crit comment is a conversation turn, not a work order. Many are questions
("is this temp code?", "do we expect that to be nil?") whose answer is an
explanation, not a diff — and some change requests dissolve once the question
behind them is answered. Editing first turns the review into a fait accompli:
the user gets a pile of changes instead of answers, and cannot redirect before
the work is done.

So, in order:

1. Read every unresolved comment + all its replies.
2. Gather whatever facts the answers need (read the code, trace callers). Do
   not edit files during this step.
3. **Post a reply to every thread** — answer the questions, and for change
   requests state what you intend to do and anything the user should weigh in
   on (a rename's new name, a diff that grows beyond the PR's files).
4. Only then make the edits, and reply again on any thread where what you did
   differs from what you said you would do.

For each unresolved comment:

1. Read the comment + all replies.
2. **Post a reply** answering the question or stating the intended change:

    ```bash
    crit comment --reply-to <comment_id> --author 'Claude' 'Extracted into helper; see line 88.'
    ```

3. Edit the referenced file with `Edit` / `MultiEdit`.

    Never pass `--resolve`. Resolving a thread is the user's call, not yours.

If there are zero unresolved comments left, the user has approved. Stop and inform them.

## Step 4: Next round

After addressing comments, run `crit-vim review` in the background again. Same repo+branch → same session key → the previous round's comments (and your replies) stay visible alongside the fresh diff.

```bash
crit-vim review
```

Tell the user:

> **"Changes applied. `:CritFinish` when ready, or `:CritCancel` if everything looks good."**

Loop back to Step 2.

## API cheat-sheet

The `crit comment` CLI covers add + reply (+ optional resolve on the reply). For anything else — updating a body, deleting, standalone resolve/unresolve — hit the daemon HTTP API. The port comes from `crit status --json`:

```bash
port=$(crit status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["daemon"]["port"])')
```

Then:

```bash
# Update the body of a comment
curl -sS -X PUT -H 'Content-Type: application/json' \
  -d '{"body":"new body"}' \
  "http://127.0.0.1:$port/api/comment/<id>?path=<file>"

# Delete a comment
curl -sS -X DELETE "http://127.0.0.1:$port/api/comment/<id>?path=<file>"

# Resolve (without replying)
curl -sS -X PUT -H 'Content-Type: application/json' \
  -d '{"resolved":true}' \
  "http://127.0.0.1:$port/api/comment/<id>/resolve?path=<file>"

# Unresolve (re-open a thread)
curl -sS -X PUT -H 'Content-Type: application/json' \
  -d '{"resolved":false}' \
  "http://127.0.0.1:$port/api/comment/<id>/resolve?path=<file>"

# Edit or delete an existing reply
curl -sS -X PUT -H 'Content-Type: application/json' \
  -d '{"body":"updated reply"}' \
  "http://127.0.0.1:$port/api/comment/<comment_id>/replies/<reply_id>?path=<file>"
curl -sS -X DELETE \
  "http://127.0.0.1:$port/api/comment/<comment_id>/replies/<reply_id>?path=<file>"

# Add a line comment (equivalent to `crit comment <file>:<line> <body>`)
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"start_line":42,"end_line":42,"body":"...","author":"Claude","scope":"line"}' \
  "http://127.0.0.1:$port/api/file/comments?path=<file>"

# Add a review-level comment (no file, no line — top-level thread)
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"body":"overall this looks good","author":"Claude"}' \
  "http://127.0.0.1:$port/api/comments"
```

All mutations broadcast SSE `comments-changed`, so nvim and any open browser tab refresh live.

## Notes

- **Never modify files while the review is open** — the working tree is what the user is reviewing (the plugin diffs against `base_ref`, but the right side is the live file).
- **`--base`** defaults to auto-detection (crit chooses based on VCS state). Pass `--base REF` to override.
- **Files not yet committed**: tracked modifications + untracked-but-present files (treated as added) both show up. The user does not need to `git add`.
- **Comments authored via `crit comment` or the API appear in nvim live** via SSE — no need to restart the review.
- **URL-encode the `path` query parameter** if it contains characters other than `[A-Za-z0-9_.~/-]`.

---

## Reference

### CLI subcommands

```bash
crit-vim review [--base REF] [--scope NAME] [--timeout SECS] [--socket PATH] [--open-browser]
crit-vim status                                # proxy to `crit status --json`
crit-vim doctor                                # includes plugin freshness check
```

`--scope` values: `unstaged` | `staged` | `branch` | `all`. Corresponds to
`GET /api/session?scope=<name>` and is applied client-side; the daemon's
default focus is broader.

`crit` companion (headless, no daemon required for `comment --clear` / `comment --reply-to`):

```bash
crit comment <file>:<line>[-end] '<body>'       # add a line comment
crit comment --reply-to <id> '<body>'           # reply
crit comment --reply-to <id> --resolve '<body>' # reply + resolve
crit comment --clear                            # remove ALL comments
crit comments [--json]                          # list
crit status  [--json]                           # daemon + review file paths
crit stop                                       # kill the daemon
```

### Comment shape

| Field                         | Notes                                             |
| ----------------------------- | ------------------------------------------------- |
| `id`                          | e.g. `c_1df20f`. Stable across rounds.            |
| `start_line` / `end_line`     | 1-based.                                          |
| `side`                        | `""` (right / new) or `"old"` (left / base).      |
| `scope`                       | `"line"`, `"file"`, or `"review"`.                |
| `body`                        | Markdown allowed.                                 |
| `resolved` / `resolved_round` | Skip if `resolved:true`.                          |
| `replies`                     | Array of `{id, body, author, created_at}`.       |
| `quote`                       | Verbatim selected text — focus edits here.        |
| `anchor`                      | Short snippet for drift detection.                |

### Socket discovery

`crit-vim` finds the user's nvim in this order: `--socket` flag → `$CRIT_VIM_SOCKET` → `$NVIM` → registry at `~/.crit-vim/sockets/<sha256(repo_root)>`. Run `crit-vim doctor` to see which step matched.

### Multi-round

Each `crit-vim review` invocation is a self-contained round. `:CritFinish` stops the daemon; the next `crit-vim review` reattaches to the same review file (per-branch persistence) so previous rounds' comments and replies are still visible alongside the fresh diff.
