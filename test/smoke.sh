#!/usr/bin/env bash
# End-to-end smoke test for crit-vim (0.2.0+ — crit-server-backed).
#
# Prereqs: crit >= 0.18 on $PATH.
#
# 1. Build a throwaway git repo with one modified file.
# 2. Launch headless nvim with the plugin loaded; let it register its socket.
# 3. `crit-vim review` (which spawns a crit daemon and attaches nvim to it).
# 4. Add a comment via the plugin's public API (which POSTs to /api/file/comments).
# 5. :CritFinish (which POSTs /api/finish and stops the daemon).
# 6. Assert the review output includes the comment.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
BIN="$PLUGIN_ROOT/bin/crit-vim"

for c in nvim git curl python3; do
  command -v "$c" >/dev/null || { echo "missing: $c"; exit 2; }
done
command -v crit >/dev/null || { echo "SKIP: crit not installed"; exit 0; }

WORK=$(mktemp -d -t crit-vim-smoke.XXXXXX)
NVIM_PID=""
REVIEW_PID=""
cleanup() {
  set +e
  [[ -n "$REVIEW_PID" ]] && kill "$REVIEW_PID" 2>/dev/null
  [[ -n "$NVIM_PID"   ]] && kill "$NVIM_PID"   2>/dev/null
  # Stop any daemon we spawned in this repo.
  ( cd "$WORK/repo" 2>/dev/null && crit stop >/dev/null 2>&1 ) || true
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
  printf 'first\nsecond\n' > a.txt
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

for _ in $(seq 1 50); do
  if [[ -S "$SOCK" ]] && nvim --server "$SOCK" --remote-expr '1' >/dev/null 2>&1; then break; fi
  sleep 0.1
done

nvim --server "$SOCK" --remote-expr 'luaeval("require\"crit-vim\".register_socket()")' >/dev/null

# ---------- 3. crit-vim review ----------

OUT="$WORK/review.out"
ERR="$WORK/review.err"
(
  cd "$REPO"
  "$BIN" review --timeout 30 > "$OUT" 2> "$ERR"
) &
REVIEW_PID=$!

# Wait for the daemon session file to appear.
BRANCH=main
REPO_CANON=$(cd "$REPO" && pwd -P)
KEY=$(printf '%s\0%s' "$REPO_CANON" "$BRANCH" | shasum -a 256 | cut -c1-12)
SF="$HOME/.crit/sessions/$KEY.json"
for _ in $(seq 1 100); do
  [[ -f "$SF" ]] && break
  sleep 0.1
done
[[ -f "$SF" ]] || { cat "$ERR"; fail "crit session file never created at $SF"; }

# Wait for the plugin to acknowledge start_review_v2.
ready=0
for _ in $(seq 1 50); do
  ready=$(nvim --server "$SOCK" --remote-expr \
    'luaeval("(require\"crit-vim\".session and 1) or 0")' 2>/dev/null || echo 0)
  [[ "$ready" == "1" ]] && break
  sleep 0.1
done
[[ "$ready" == "1" ]] || { cat "$ERR"; cat "$WORK/nvim.out"; fail "plugin did not attach"; }

# ---------- 4. add a comment via the API-backed helper ----------

nvim --server "$SOCK" --remote-expr \
  "luaeval('require\"crit-vim\"._api_add_comment(\"a.txt\", \"right\", 2, 2, \"needs a trailing newline\", \"second\", function() end)')" \
  >/dev/null

# Give the async POST time to settle.
sleep 1

# ---------- 5. finish ----------

nvim --server "$SOCK" --remote-expr 'luaeval("require\"crit-vim\".finish()")' >/dev/null

# ---------- 6. verify ----------

if ! wait "$REVIEW_PID"; then
  cat "$ERR"; fail "review exited non-zero"
fi
REVIEW_PID=""

grep -F -q "needs a trailing newline" "$OUT" || { cat "$OUT"; fail "comment body missing"; }
grep -F -q "a.txt" "$OUT" || { cat "$OUT"; fail "file key missing"; }

echo "PASS"
