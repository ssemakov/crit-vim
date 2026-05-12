# crit-vim

Review an agent's diff inside your running Neovim and ship the comments back
as JSON. A vim-native frontend for the agent/human review handshake, with the
JSON shape kept compatible with [tomasz-tomczyk/crit] so we can swap to its
daemon API later without touching the agent side.

[tomasz-tomczyk/crit]: https://github.com/tomasz-tomczyk/crit

This is an intentionally minimal MVP:

- Single review round.
- Line/range comments only (no replies, no resolve toggle, no scopes).
- Diff via `:diffthis` between the working tree and `git show <base>:<path>`.
- Self-contained storage in `$TMPDIR/crit-vim/<session>`. No daemon.

## Install

The plugin is a Neovim runtime directory and a single shell script.

**1. Wire up the plugin.**

LazyVim / lazy.nvim — drop a file in `~/.config/nvim/lua/plugins/crit-vim.lua`:

```lua
return {
  {
    dir = "/path/to/crit-vim",
    name = "crit-vim",
    lazy = false,  -- need VimEnter to register the socket on startup
  },
}
```

Classic vim runtime:

```vim
set runtimepath+=/path/to/crit-vim
```

**2. Put the CLI on `$PATH`.**

```sh
ln -s /path/to/crit-vim/bin/crit-vim ~/bin/crit-vim   # or any $PATH dir
```

**3. Verify.**

Restart nvim, open it in a git repo, then in another tmux pane:

```sh
crit-vim doctor
```

The output should list your nvim's socket under `registry`.

Requires: Neovim 0.10+, `git`, `uuidgen`, `bash`, `jq` _or_ `python3`.

## Usage

You need two things:

1. **Your nvim**, open in the repo of interest, with the plugin loaded. It
   registers its socket on `VimEnter` keyed by repo root.
2. **A shell** where you (or the agent) can run `crit-vim review`. It can be
   anywhere with `$PATH` set: a sibling tmux pane, a separate terminal window,
   an IDE terminal, `:terminal` inside the same nvim, an SSH session sharing
   the socket — anything that resolves to the same `git rev-parse
--show-toplevel` will find the right nvim via the per-repo registry.

In the shell:

```sh
crit-vim review --base HEAD
```

That blocks. In nvim, **one diff tab opens per changed file** (tracked
modifications + untracked-but-present files, treated as added). Navigate
tabs with `gt`/`gT`, or `:CritFiles` for a picker.

### Authoring comments

Pick a range, then drop into a floating comment buffer:

| To comment on...                 | Do this                                                         |
| -------------------------------- | --------------------------------------------------------------- |
| the current line                 | `<leader>cc`                                                    |
| a paragraph                      | `<leader>cap` (operator + text-object)                          |
| this line and the next 4         | `<leader>c4j` (operator + count + motion)                       |
| down to the next blank line      | `<leader>c}`                                                    |
| inside quotes / brackets / a tag | `<leader>ci"` / `<leader>ci(` / `<leader>cit`                   |
| an arbitrary visual selection    | `V` → move → `<leader>c` (linewise) or `v` → move → `<leader>c` |
| an explicit line range           | `:42,55CritComment`                                             |

Anywhere you'd use a vim motion or text-object after `d`/`y`/`c`, you can use
it after `<leader>c`. The saved comment is anchored to the **line range** the
motion covered (upstream's schema is line-based); the exact selected text is
preserved in the comment's `quote` field.

Inside the floating buffer (real vim — operators, registers, clipboard, etc.):

| Keys / Command                      | Behaviour                  |
| ----------------------------------- | -------------------------- |
| `<C-s>` (normal+insert), `:w`, `ZZ` | save the comment and close |
| `q` (normal), `:q!`                 | cancel without saving      |

### Managing comments

| Command       | Behaviour                                 |
| ------------- | ----------------------------------------- |
| `:CritEdit`   | edit comment under cursor                 |
| `:CritDelete` | delete comment under cursor (prompts y/N) |
| `:CritList`   | quickfix list of all comments             |
| `:CritFiles`  | floating picker: jump to a file's tab     |
| `:CritReopen` | rebuild diff tabs after `<C-w>o` etc.     |

### Submitting the review

```vim
:CritFinish
```

Pane B unblocks and prints the JSON to stdout. `:CritCancel` aborts; pane B
exits 1.

We don't bind `<leader>cf`/`<leader>cs` etc. as global shortcuts because they
collide with LazyVim's `<leader>c{letter}` group. Bind your own if you like:

```lua
vim.keymap.set("n", "<leader>cF", "<cmd>CritFinish<cr>")
vim.keymap.set("n", "<leader>cX", "<cmd>CritDelete<cr>")
```

## CLI commands

| Command                        | What it does                                        |
| ------------------------------ | --------------------------------------------------- |
| `crit-vim review [--base REF]` | open a review and block on `:CritFinish`            |
| `crit-vim status`              | print the JSON of the most recently finished review |
| `crit-vim doctor`              | diagnose nvim socket discovery                      |

## Troubleshooting

- **Only one file shows up.** Make sure the agent's new files are either
  staged (`git add`) or present in the worktree as untracked — crit-vim
  picks up both. Ignored files (`.gitignore`) are skipped. If you closed
  diff tabs with `<C-w>o`, run `:CritReopen`.
- **A stale review blocks new ones.** Starting a new `crit-vim review`
  auto-cancels the prior session in nvim. If a bash CLI is stuck in the
  background, kill it; the new review's JSON is what counts.

## Socket discovery

The CLI looks for the user's nvim in this order:

1. `--socket <path>` flag
2. `$CRIT_VIM_SOCKET`
3. `$NVIM` (set by nvim for processes spawned from `:terminal`)
4. `~/.crit-vim/sockets/<sha256(repo_root)>` (registry the plugin maintains)

For nvim-in-tmux-pane-A + agent-in-tmux-pane-B, only the registry helps.
It's written on `VimEnter` and removed on `VimLeavePre`. One nvim per repo:
just works. If you run two nvims in the same repo, last-write wins — set
`$CRIT_VIM_SOCKET` or pass `--socket` to disambiguate.

## Output JSON

Kept shape-compatible with upstream `crit status --code`:

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
          "resolved_round": 0,
          "replies": [],
          "created_at": "2026-05-12T09:14:00Z",
          "author": "you@example.com",
          "quote": "for {",
          "anchor": {
            "before": ["...", "...", "..."],
            "body": ["for {"],
            "after": ["...", "...", "..."],
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

We own this file (in `$TMPDIR/crit-vim/<sid>/comments.json`). When we later
switch to the upstream daemon, we replace two functions in `lua/crit-vim/init.lua`
(`_append_comment` and the reads in `_refresh_signs_for_file`) with calls to
`crit comment --json` / `crit status --json`. The schema stays put.

## Smoke test

`test/smoke.sh` builds a throwaway repo, starts a headless nvim with the
plugin, runs `crit-vim review` against it from a background shell, plants a
comment via RPC, calls `:CritFinish`, and checks the resulting JSON.

```sh
./test/smoke.sh
```

## Roadmap

After this v0 dogfoods:

- Swap storage to upstream `crit` CLI/HTTP — same JSON shape, daemon-owned
  reviews, rounds, GitHub sync for free.
- Resolve / unresolve action.
- Replies (schema already there).
- Bordered comment rendering (`virt_lines`).
- File-scope and review-scope comments.
