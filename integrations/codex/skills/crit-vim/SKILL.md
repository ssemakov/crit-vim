---
name: crit-vim
description: Review code changes inside the user's running Neovim using crit-vim (nvim-native client for tomasz-tomczyk/crit; supports threaded replies + resolve). Use when the user asks to review your changes "in vim" or "with crit-vim".
---

# Review with crit-vim

Review and revise code changes using `crit-vim` — an nvim-native client for [tomasz-tomczyk/crit](https://github.com/tomasz-tomczyk/crit). The user authors comments (and reply threads) in Neovim; you read them, address them, and reply — all through crit's daemon.

## Ground rule

**Never edit `~/.crit/reviews/*/review.json` directly.** The daemon owns that file with atomic writes; hand-editing races the daemon and breaks live sync. Mutate through:

- `crit` CLI (`crit comment ...`) — covers add / reply / resolve-with-reply / bulk clear.
- Daemon HTTP API (`http://127.0.0.1:<port>/api/*`) — for update / delete / standalone resolve.

`crit comments --json` reads the current state.

## Prerequisites

`crit` and `crit-vim` on `$PATH`; user's Neovim running with the plugin loaded.

```bash
crit-vim doctor
```

If no reachable nvim, ask the user to open one in the repo. **Don't start nvim yourself.**

## Step 1: Launch and block

```bash
crit-vim review
```

Foreground blocking is fine (Codex has no explicit background/foreground). Set a long timeout — reviews take minutes.

Tell the user:

> **"Review is open in your nvim. Drop comments on the diff, then `:CritFinish` when done."**

Exit codes:
- `0` → finished; JSON on stdout.
- `1` → cancelled or `crit` missing.
- `2` → setup error. Read stderr.
- `124` → timeout.

## Step 2: Read the comments

Reprint with `crit comments --json`. Shape:

```json
{
  "files": {
    "path/to/file.go": {
      "status": "modified",
      "comments": [
        {
          "id": "c_1df20f",
          "start_line": 42, "end_line": 42,
          "side": "",  "scope": "line",
          "body": "this should handle EOF",
          "quote": "for {",
          "resolved": false,
          "replies": [
            {"id": "rp_ab12", "body": "acknowledged", "author": "you"}
          ]
        }
      ]
    }
  }
}
```

- Skip anything `resolved:true`.
- Read parent `body` + every `replies[].body`.
- `side: ""` (or `"right"`) → your code. `side: "old"` (or `"left"`) → base.
- Focus edits on `quote` when present.

## Step 3: Address each comment

1. Read the whole thread.
2. Edit the file.
3. Post a reply so the user sees what you did:

    ```bash
    crit comment --reply-to <id> --author 'agent' 'Extracted into helper; see line 88.'
    # append --resolve to close in one call
    crit comment --reply-to <id> --resolve --author 'agent' 'Fixed in this round.'
    ```

Zero unresolved → approved. Stop.

## Step 4: Next round

`crit-vim review` again — same repo+branch → same review; prior rounds' comments + your replies persist alongside the fresh diff.

## API cheat-sheet (for anything `crit comment` can't do)

Get the daemon port:

```bash
port=$(crit status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["daemon"]["port"])')
```

Then:

```bash
# Update a comment body
curl -sS -X PUT -H 'Content-Type: application/json' \
  -d '{"body":"new body"}' \
  "http://127.0.0.1:$port/api/comment/<id>?path=<file>"

# Delete a comment
curl -sS -X DELETE "http://127.0.0.1:$port/api/comment/<id>?path=<file>"

# Resolve / unresolve without replying
curl -sS -X PUT -H 'Content-Type: application/json' \
  -d '{"resolved":true}' \
  "http://127.0.0.1:$port/api/comment/<id>/resolve?path=<file>"

# Edit / delete a reply
curl -sS -X PUT -H 'Content-Type: application/json' \
  -d '{"body":"updated reply"}' \
  "http://127.0.0.1:$port/api/comment/<cid>/replies/<rid>?path=<file>"
curl -sS -X DELETE \
  "http://127.0.0.1:$port/api/comment/<cid>/replies/<rid>?path=<file>"
```

All mutations broadcast SSE `comments-changed` — nvim + browser re-render live.

## Notes

- **Don't modify files while the review is open** — the right pane in nvim is the live working-tree file.
- **`--base`** defaults to auto-detection; override with `--base REF`.
- **Tracked + untracked-but-present files** show up. No `git add` needed.
- **URL-encode the `path` query param** if it has non-`[A-Za-z0-9_.~/-]` characters.

## Reference

```bash
crit-vim review [--base REF] [--timeout SECS] [--socket PATH] [--open-browser]
crit-vim status                                # proxy to `crit status --json`
crit-vim doctor

crit comment <file>:<line>[-end] '<body>'
crit comment --reply-to <id> '<body>'
crit comment --reply-to <id> --resolve '<body>'
crit comments --json
```

Socket discovery order: `--socket` → `$CRIT_VIM_SOCKET` → `$NVIM` → `~/.crit-vim/sockets/<sha256(repo_root)>`.
