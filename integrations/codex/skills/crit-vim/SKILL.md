---
name: crit-vim
description: Review code changes inside the user's running Neovim using crit-vim (nvim-native client for tomasz-tomczyk/crit; supports threaded replies + resolve). Use when the user asks to review your changes "in vim" or "with crit-vim".
---

# Review with crit-vim

Review and revise code changes using `crit-vim` — an nvim-native client for [tomasz-tomczyk/crit](https://github.com/tomasz-tomczyk/crit). The user authors comments (and reply threads) in Neovim; you read the resulting JSON and address each comment by editing files.

## Prerequisites

Both `crit` (the daemon binary) and `crit-vim` (the nvim client CLI) must be on `$PATH`, and the user's Neovim must be running with the crit-vim plugin loaded. Quick check:

```bash
crit-vim doctor
```

If the doctor reports no reachable nvim, ask the user to open Neovim in the repo of interest. **Do not start nvim yourself** — the whole point of crit-vim is to attach to the user's existing editor.

## Step 1: Launch crit-vim and block until the user finishes

Run `crit-vim review` in the foreground; it blocks until the user finishes:

```bash
crit-vim review
```

Set a long timeout — reviews can take 10+ minutes. The command:
- spawns a `crit --no-open` daemon for this repo+branch (or attaches if one is already running),
- tells nvim to attach, and
- blocks until the user runs `:CritFinish` or `:CritCancel` in nvim (or hits Approve in a browser tab, if they opened one).

Tell the user:

> **"Review is open in your nvim. Drop comments on the diff, then `:CritFinish` when done."**

Exit codes:
- `0` → user finished. JSON is on stdout.
- `1` → user cancelled, or crit binary missing.
- `2` → setup error. Read stderr and relay to user.
- `124` → timeout.

## Step 2: Read the comments

The command prints crit's review JSON on stdout. `crit comments --json` re-prints it any time.

Shape:

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

- Skip anything with `resolved: true`.
- Read the whole thread: `body` + all `replies[].body`.
- `side: ""` (or `"right"`) → your proposed code. `side: "old"` (or `"left"`) → the base.
- Focus edits on `quote` when present.

## Step 3: Address each comment

1. Read the comment and all replies.
2. Edit the file with `Edit` / `MultiEdit`.
3. Optionally post a reply:

    ```bash
    crit comment --reply-to <id> 'Extracted into helper; see line 88.'
    # append --resolve to mark it resolved
    crit comment --reply-to <id> --resolve 'Fixed in this round.'
    ```

Zero unresolved comments → approved. Stop.

## Step 4: Next round

`crit-vim review` again. The same session key (cwd + branch) means the user sees the previous round's comments + your replies alongside the fresh diff.

## Notes

- **Never modify files while the review is open.** The right pane in nvim is the live working-tree file.
- **`--base`** defaults to auto-detection. Override with `--base REF`.
- **Both tracked modifications and untracked-but-present files** show up — no `git add` needed.
- **Comments authored via `crit comment` (headless)** appear in nvim live via SSE.

## Reference

```bash
crit-vim review [--base REF] [--timeout SECS] [--socket PATH] [--open-browser]
crit-vim status                                # proxy to `crit status --json`
crit-vim doctor

# Headless comment authoring:
crit comment <file>:<line>[-end] '<body>'
crit comment --reply-to <id> '<body>'
crit comment --reply-to <id> --resolve '<body>'
crit comments --json
```

Socket discovery order: `--socket` → `$CRIT_VIM_SOCKET` → `$NVIM` → `~/.crit-vim/sockets/<sha256(repo_root)>`.
