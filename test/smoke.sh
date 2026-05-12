#!/usr/bin/env bash
# End-to-end smoke test for crit-vim.
#
# 1. Build a throwaway git repo with one modified file.
# 2. Launch headless nvim with the plugin loaded; let it register its socket.
# 3. Run `crit-vim review --wait` in the background pointing at that nvim.
# 4. Inject a comment via the plugin's lua API.
# 5. Call :CritFinish via RPC.
# 6. Verify the review process exits 0 and emits a comment with the right shape.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
BIN="$PLUGIN_ROOT/bin/crit-vim"

for c in nvim git uuidgen; do
  command -v "$c" >/dev/null || { echo "missing: $c"; exit 2; }
done

WORK=$(mktemp -d -t crit-vim-smoke.XXXXXX)
NVIM_PID=""
REVIEW_PID=""
cleanup() {
  set +e
  [[ -n "$REVIEW_PID" ]] && kill "$REVIEW_PID" 2>/dev/null
  [[ -n "$NVIM_PID"   ]] && kill "$NVIM_PID"   2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------- 1. repo ----------

REPO="$WORK/repo"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q -b main
  git config user.email tester@example.com
  git config user.name  tester
  printf 'first\n' > a.txt
  git add a.txt
  git commit -q -m "first"
  # diff-against-HEAD change to a tracked file
  printf 'first\nsecond\n' > a.txt
  # untracked file the "agent" added; should appear in the review without
  # needing `git add`.
  printf 'brand new\n' > new.txt
)

# ---------- 2. nvim ----------

SOCK="$WORK/nvim.sock"
INIT="$WORK/init.lua"
cat > "$INIT" <<LUA
vim.opt.runtimepath:append("$PLUGIN_ROOT")
vim.cmd("runtime! plugin/crit-vim.lua")
LUA

(
  cd "$REPO"
  nvim --headless --listen "$SOCK" -u "$INIT" \
       --cmd 'set noswapfile' \
       > "$WORK/nvim.out" 2>&1 &
  echo $! > "$WORK/nvim.pid"
)
NVIM_PID=$(cat "$WORK/nvim.pid")

# Wait for nvim to accept connections.
for _ in $(seq 1 50); do
  if [[ -S "$SOCK" ]] && nvim --server "$SOCK" --remote-expr '1' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
nvim --server "$SOCK" --remote-expr '1' >/dev/null 2>&1 \
  || { cat "$WORK/nvim.out"; fail "nvim never came up"; }

# Force socket registration (VimEnter may have already fired; this is idempotent).
nvim --server "$SOCK" --remote-expr 'luaeval("require\"crit-vim\".register_socket()")' \
  >/dev/null

REPO_REAL=$(git -C "$REPO" rev-parse --show-toplevel)
REPO_SHA=$(printf '%s' "$REPO_REAL" | shasum -a 256 | cut -d' ' -f1)
REG="$HOME/.crit-vim/sockets/$REPO_SHA"
[[ -f "$REG" ]] || fail "registry not written: $REG"
[[ "$(cat "$REG")" == "$SOCK" ]] || fail "registry has wrong socket: $(cat "$REG") vs $SOCK"

# ---------- 3. review in background ----------

OUT="$WORK/review.out"
ERR="$WORK/review.err"
(
  cd "$REPO"
  # Scope the session dir under $WORK so we don't see leftovers from prior runs.
  TMPDIR="$WORK" "$BIN" review --base HEAD --wait --timeout 30 > "$OUT" 2> "$ERR"
) &
REVIEW_PID=$!

# Wait for the session dir to materialize.
SDIR=""
TMPROOT="$WORK/crit-vim"
for _ in $(seq 1 50); do
  if [[ -d "$TMPROOT" ]]; then
    newest=$(ls -t "$TMPROOT" 2>/dev/null | head -1 || true)
    if [[ -n "$newest" ]]; then
      cand="$TMPROOT/$newest"
      if [[ -f "$cand/meta.json" ]]; then SDIR="$cand"; break; fi
    fi
  fi
  sleep 0.1
done
[[ -n "$SDIR" ]] || { cat "$ERR"; fail "session dir never created"; }

# Verify both tracked and untracked files made it into meta.json.
grep -q '"path":"a.txt"'   "$SDIR/meta.json" || { cat "$SDIR/meta.json"; fail "a.txt missing from meta"; }
grep -q '"path":"new.txt"' "$SDIR/meta.json" || { cat "$SDIR/meta.json"; fail "untracked new.txt missing from meta"; }
grep -q '"new.txt".*"status":"added"' "$SDIR/meta.json" \
  || grep -q '"path":"new.txt","status":"added"' "$SDIR/meta.json" \
  || { cat "$SDIR/meta.json"; fail "new.txt not marked added"; }

# Wait for the plugin to acknowledge start_review.
for _ in $(seq 1 50); do
  ready=$(nvim --server "$SOCK" --remote-expr \
    'luaeval("(require\"crit-vim\".session and 1) or 0")' 2>/dev/null || echo 0)
  [[ "$ready" == "1" ]] && break
  sleep 0.1
done
[[ "$ready" == "1" ]] || { cat "$ERR"; cat "$WORK/nvim.out"; fail "plugin did not start review"; }

# ---------- 4. inject a comment ----------

cat > "$WORK/inject.lua" <<'LUA'
local M = require("crit-vim")
M._append_comment("a.txt", {
  id = "test-id-1",
  start_line = 2, end_line = 2,
  side = "right", scope = "line",
  body = "needs a trailing newline",
  resolved = false, resolved_round = 0, replies = {},
  created_at = "2026-05-12T00:00:00Z",
  author = "tester@example.com",
  quote = "second",
  anchor = {
    before = { "first" },
    body   = { "second" },
    after  = {},
    start_line = 2, end_line = 2,
  },
})
M._refresh_signs_for_file("a.txt")
LUA

nvim --server "$SOCK" --remote-expr "execute('luafile $WORK/inject.lua')" >/dev/null

# ---------- 5. finish ----------

nvim --server "$SOCK" --remote-expr 'luaeval("require\"crit-vim\".finish()")' >/dev/null

# ---------- 6. verify ----------

if ! wait "$REVIEW_PID"; then
  cat "$ERR"
  fail "review exited non-zero"
fi
REVIEW_PID=""

# Assert key fields. We use grep on the raw JSON (the test doesn't care
# about pretty-printing, just the substrings).
grep -q '"body":"needs a trailing newline"' "$OUT" || { cat "$OUT"; fail "comment body missing"; }
grep -q '"side":"right"'                    "$OUT" || { cat "$OUT"; fail "side missing"; }
grep -q '"start_line":2'                    "$OUT" || { cat "$OUT"; fail "start_line missing"; }
grep -q '"a.txt"'                            "$OUT" || { cat "$OUT"; fail "file key missing"; }
grep -q '"status":"modified"'               "$OUT" || { cat "$OUT"; fail "file status missing"; }
grep -q '"quote":"second"'                  "$OUT" || { cat "$OUT"; fail "quote missing"; }
grep -q '"author":"tester@example.com"'     "$OUT" || { cat "$OUT"; fail "author missing"; }

# `crit-vim status` should return the same JSON.
status_out=$("$BIN" status)
echo "$status_out" | grep -q '"body":"needs a trailing newline"' \
  || fail "status output missing comment"

echo "PASS"
