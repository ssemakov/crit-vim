-- crit-vim: nvim-native client for tomasz-tomczyk/crit.
--
-- The plugin no longer owns review-session state; it attaches to a running
-- `crit` daemon and:
--   • reads the review file (~/.crit/reviews/<key>/review.json) for comments
--   • writes comments via /api/* HTTP endpoints
--   • listens on /api/events (SSE) for real-time updates from any client
--     (browser tab, `crit comment` CLI, or another nvim)
--
-- Legacy `M.start_review(session_dir)` is retained (calls into v2 shim) so
-- older CLI wrappers keep working; new invocations use `start_review_v2`.

local http = require("crit-vim.http")
local sse  = require("crit-vim.sse")

local M = {}

M.session = nil          -- see start_review_v2 for shape
M._comment_ctx = {}      -- bufnr -> draft context
M._ns = vim.api.nvim_create_namespace("crit_vim")

-- Highlight groups used for the inline comment overlay. All default-linked
-- so a user colorscheme's explicit definitions win.
--
-- The box body uses NormalFloat (distinct from Normal by design), so the
-- comment reads as a floating card sitting on top of the code, with an
-- explicit border around it.
local function ensure_highlights()
  local hls = {
    CritVimCommentBar     = { link = "DiagnosticInfo" },  -- signcolumn bar
    CritVimCommentRange   = { link = "DiffChange" },      -- background of the commented range
    CritVimCommentBorder  = { link = "FloatBorder" },     -- ╭─╮│╰─╯ around the box
    CritVimCommentBody    = { link = "NormalFloat" },     -- box interior text + padding
    CritVimCommentMeta    = { link = "NonText" },         -- resolved marker etc.
    CritVimCommentReply   = { link = "NormalFloat" },     -- reply body text
    CritVimCommentReplyAuthor = { link = "Special" },     -- ↳ @author prefix
    CritVimCommentResolved = { link = "NonText", strikethrough = true }, -- resolved body
    CritVimCommentDivider = { link = "FloatBorder" },     -- ┈┈┈ between replies
  }
  for name, spec in pairs(hls) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

-- Re-apply defaults after a colorscheme swap (which does `hi clear`).
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("crit_vim_highlights", { clear = true }),
  callback = ensure_highlights,
})

-- ---------- filesystem / json helpers ----------

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, data)
  local f, err = io.open(path, "w")
  if not f then error("crit-vim: cannot write " .. path .. ": " .. tostring(err)) end
  f:write(data)
  f:close()
end

local function read_json(path)
  local s = read_file(path)
  if not s then return nil end
  local ok, data = pcall(vim.json.decode, s)
  if not ok then return nil end
  return data
end

-- Read the crit review file (written atomically by the daemon on every
-- mutation, whether from browser/CLI/our HTTP posts). Returns a normalised
-- {files, review_comments} table; empty tables when the file is absent.
-- Placed high in the file because sidebar/render code calls it before the
-- lifecycle helpers are declared.
local function read_review_file()
  if not M.session or not M.session.review_path then
    return { files = {}, review_comments = {} }
  end
  local data = read_json(M.session.review_path .. "/review.json")
        or { files = {}, review_comments = {} }
  if type(data.files) ~= "table" then data.files = {} end
  if type(data.review_comments) ~= "table" then data.review_comments = {} end
  return data
end

-- Legacy alias kept for internal call sites still using load_comments().
local function load_comments()
  return read_review_file()
end

-- Normalize the wire-format `side` field to our buffer-marker convention
-- ("right" / "left"). tomasz-crit stores right-side as "" (omitempty) and
-- left-side as "old"; older writers may use "right" / "left" literally.
local function norm_side(s)
  if s == "old" or s == "left" then return "left" end
  return "right"
end

-- Blocking GET /api/file/comments?path=X. Returns a list of comments (may
-- be empty) or nil on error. Fetches in-memory session state, so it sees
-- writes that haven't yet been flushed to review.json by the daemon's
-- debounced writer — no post-POST staleness.
local function api_get_file_comments(file)
  if not M.session then return nil end
  local url = string.format("http://%s:%d/api/file/comments?path=%s",
    M.session.host, M.session.port, http.url_encode(file))
  local out = vim.fn.system({ "curl", "-sS", "--max-time", "3", url })
  if vim.v.shell_error ~= 0 then return nil end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then return nil end
  if type(decoded) ~= "table" then return {} end
  return decoded
end

local function write_json(path, data)
  write_file(path, vim.json.encode(data))
end

local function home()
  return vim.fn.expand("~")
end

local function socket_registry_dir()
  return home() .. "/.crit-vim/sockets"
end

local function repo_root(cwd)
  cwd = cwd or vim.fn.getcwd()
  local out = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then return nil end
  return out[1]
end

-- ---------- socket registry ----------

function M.register_socket()
  local root = repo_root()
  if not root or root == "" then return end
  local servername = vim.v.servername
  if not servername or servername == "" then return end
  vim.fn.mkdir(socket_registry_dir(), "p")
  local path = socket_registry_dir() .. "/" .. vim.fn.sha256(root)
  local ok, err = pcall(write_file, path, servername)
  if not ok then
    vim.notify("crit-vim: registry write failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

function M.unregister_socket()
  local root = repo_root()
  if not root or root == "" then return end
  local path = socket_registry_dir() .. "/" .. vim.fn.sha256(root)
  os.remove(path)
end

-- ---------- diff buffers ----------

local function set_review_buffer(buf, file, side, syntax_for)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.b[buf].crit_vim_side = side
  vim.b[buf].crit_vim_file = file
  if syntax_for then
    local ft = vim.filetype.match({ filename = syntax_for })
    if ft then vim.bo[buf].filetype = ft end
  end
end

-- Force the user's preferred line number + a visible signcolumn on a diff
-- window. Without this, distros that hide numbers on `buftype=nofile`
-- (LazyVim does) leave the gutter blank for added/deleted files (modified
-- files survive because `:diffthis` keeps the column).
local function set_diff_window_options(win)
  win = win or 0
  vim.wo[win].number         = vim.go.number
  vim.wo[win].relativenumber = vim.go.relativenumber
  vim.wo[win].signcolumn     = "yes"
end

-- Clear the review markers when a buffer is no longer part of a review.
-- The <Plug> mappings guard on M.session anyway, so this is mainly to keep
-- comment_at_cursor from finding stale side/file on real-file buffers that
-- outlived the review.
local function clear_review_buffer_vars(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(function()
    vim.b[buf].crit_vim_side = nil
    vim.b[buf].crit_vim_file = nil
  end)
end

local function fill_buffer(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  vim.bo[buf].modifiable = false
end

local function git_show(repo, ref, path)
  local lines = vim.fn.systemlist({ "git", "-C", repo, "show", ref .. ":" .. path })
  if vim.v.shell_error ~= 0 then return {} end
  return lines
end

-- Mark a real-file buffer as part of the review (so :CritComment etc. can
-- find it) without making it read-only — the user may want to edit.
local function mark_real_review_buffer(buf, file, side)
  vim.bo[buf].buflisted = false
  vim.b[buf].crit_vim_side = side
  vim.b[buf].crit_vim_file = file
end

local function tabedit_repo_file(repo, path)
  vim.cmd("tabedit " .. vim.fn.fnameescape(repo .. "/" .. path))
end

local function open_file_diff(file_info, base, repo)
  -- Added: just the working-tree file, editable. No left side to diff
  -- against; the user reads top-to-bottom.
  if file_info.status == "added" then
    tabedit_repo_file(repo, file_info.path)
    local buf = vim.api.nvim_get_current_buf()
    mark_real_review_buffer(buf, file_info.path, "right")
    set_diff_window_options(0)
    return { left = buf, right = buf, file = file_info.path,
             tab = vim.api.nvim_get_current_tabpage() }
  end

  -- Deleted: file is gone from the worktree, so no editable side. Show the
  -- base content in a read-only scratch buffer.
  if file_info.status == "deleted" then
    vim.cmd("tabnew")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, file_info.path .. " [deleted]")
    fill_buffer(buf, git_show(repo, base, file_info.old_path or file_info.path))
    set_review_buffer(buf, file_info.path, "left", file_info.path)
    set_diff_window_options(0)
    return { left = buf, right = buf, file = file_info.path,
             tab = vim.api.nvim_get_current_tabpage() }
  end

  -- Modified / renamed: side-by-side diff. Right is the real working-tree
  -- file (editable, :w writes through). Left is a read-only scratch with
  -- the base content from `git show`.
  tabedit_repo_file(repo, file_info.path)
  local right_buf = vim.api.nvim_get_current_buf()
  mark_real_review_buffer(right_buf, file_info.path, "right")
  vim.cmd("diffthis")
  set_diff_window_options(0)

  vim.cmd("leftabove vsplit | enew")
  local left_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(left_buf, file_info.path .. " [" .. base .. "]")
  fill_buffer(left_buf, git_show(repo, base, file_info.old_path or file_info.path))
  set_review_buffer(left_buf, file_info.path, "left", file_info.path)
  vim.cmd("diffthis")
  set_diff_window_options(0)

  -- Land on the right (working-tree) side — that's where review focus is.
  vim.cmd("wincmd l")

  return {
    left = left_buf,
    right = right_buf,
    file = file_info.path,
    tab = vim.api.nvim_get_current_tabpage(),
  }
end

-- ---------- sidebar ----------
-- A persistent file list pinned to the leftmost column of every review tab.
-- One shared buffer rendered in N windows (one per tab). cursorline is
-- window-local, so each tab highlights its own current file independently.

local SIDEBAR_WIDTH = 38
local SIDEBAR_HEADER_ROWS = 2  -- title + blank
local SIDEBAR_FT = "critvim_sidebar"

local function status_glyph(st)
  if st == "modified" then return "M" end
  if st == "added"    then return "A" end
  if st == "deleted"  then return "D" end
  if st == "renamed"  then return "R" end
  if st == "copied"   then return "C" end
  return "?"
end

local function sidebar_lines()
  local data = read_review_file()
  local total = 0
  local rows = { "", "" }  -- header filled in last
  local path_w = SIDEBAR_WIDTH - 10
  for _, fi in ipairs(M.session.files) do
    local fdata = data.files and data.files[fi.path]
    local n = (fdata and #(fdata.comments or {})) or 0
    total = total + n
    local p = fi.path
    if #p > path_w then p = "…" .. p:sub(-(path_w - 1)) end
    local count = n > 0 and string.format("[%d]", n) or ""
    rows[#rows + 1] = string.format(" %s  %-" .. path_w .. "s %s",
      status_glyph(fi.status), p, count)
  end
  rows[1] = string.format("crit-vim — %d file%s · %d comment%s",
    #M.session.files, #M.session.files == 1 and "" or "s",
    total, total == 1 and "" or "s")
  return rows
end

local function ensure_sidebar_buf()
  local existing = M.session and M.session.sidebar_buf
  if existing and vim.api.nvim_buf_is_valid(existing) then return existing end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "critvim://sidebar")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = SIDEBAR_FT
  vim.bo[buf].modifiable = false

  vim.keymap.set("n", "<CR>", function() M._sidebar_jump() end,
    { buffer = buf, desc = "crit-vim: jump to file" })
  vim.keymap.set("n", "<2-LeftMouse>", function() M._sidebar_jump() end,
    { buffer = buf })
  vim.keymap.set("n", "q", function() M.sidebar_toggle() end,
    { buffer = buf, desc = "crit-vim: close sidebar" })
  vim.keymap.set("n", "R", function() M.render_sidebar() end,
    { buffer = buf, desc = "crit-vim: refresh sidebar" })

  M.session.sidebar_buf = buf
  return buf
end

local function file_index_for_tab(tab)
  if not M.session then return nil end
  for i, fi in ipairs(M.session.files) do
    local bufs = M.session.file_bufs[fi.path]
    if bufs and bufs.tab == tab then return i, fi end
  end
  return nil
end

function M._reposition_sidebar_cursor()
  if not M.session then return end
  local tab = vim.api.nvim_get_current_tabpage()
  local idx = file_index_for_tab(tab)
  if not idx then return end
  local row = SIDEBAR_HEADER_ROWS + idx
  for _, bufs in pairs(M.session.file_bufs) do
    if bufs.tab == tab and bufs.sidebar_win
       and vim.api.nvim_win_is_valid(bufs.sidebar_win) then
      pcall(vim.api.nvim_win_set_cursor, bufs.sidebar_win, { row, 0 })
      return
    end
  end
end

function M.render_sidebar()
  if not M.session or not M.session.sidebar_buf then return end
  local buf = M.session.sidebar_buf
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = sidebar_lines()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M._reposition_sidebar_cursor()
end

function M._sidebar_jump()
  if not M.session then return end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local idx = row - SIDEBAR_HEADER_ROWS
  local fi = M.session.files[idx]
  if not fi then return end
  local bufs = M.session.file_bufs[fi.path]
  if not bufs or not bufs.tab or not vim.api.nvim_tabpage_is_valid(bufs.tab) then return end
  vim.api.nvim_set_current_tabpage(bufs.tab)
  -- Land in the rightmost diff window of the target tab.
  local target
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(bufs.tab)) do
    if w ~= bufs.sidebar_win then target = w end  -- last non-sidebar wins
  end
  if target then pcall(vim.api.nvim_set_current_win, target) end
end

local function open_sidebar_in_current_tab()
  if not M.session then return end
  ensure_sidebar_buf()
  local tab = vim.api.nvim_get_current_tabpage()

  -- Skip if a sidebar window already exists for this tab.
  for _, bufs in pairs(M.session.file_bufs) do
    if bufs.tab == tab and bufs.sidebar_win
       and vim.api.nvim_win_is_valid(bufs.sidebar_win) then
      return
    end
  end

  vim.cmd("topleft " .. SIDEBAR_WIDTH .. "vsplit")
  vim.cmd("buffer " .. M.session.sidebar_buf)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].list = false

  -- Record the sidebar window against this tab's file.
  for _, bufs in pairs(M.session.file_bufs) do
    if bufs.tab == tab then bufs.sidebar_win = win end
  end
  -- Focus stays on the sidebar; that's the navigation surface.
end

function M.sidebar_toggle()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local existing
  for _, bufs in pairs(M.session.file_bufs) do
    if bufs.tab == tab and bufs.sidebar_win
       and vim.api.nvim_win_is_valid(bufs.sidebar_win) then
      existing = bufs.sidebar_win
      break
    end
  end
  if existing then
    pcall(vim.api.nvim_win_close, existing, true)
    for _, bufs in pairs(M.session.file_bufs) do
      if bufs.sidebar_win == existing then bufs.sidebar_win = nil end
    end
  else
    open_sidebar_in_current_tab()
    M._reposition_sidebar_cursor()
  end
end

-- ---------- session lifecycle ----------

-- Forward-declared; defined below.
local close_session

-- Convert a SessionInfo `files` entry from /api/session into the file_info
-- shape our open_file_diff expects.
local function session_file_to_file_info(sf)
  local status = sf.status or "modified"
  -- Server returns "untracked" for new-but-unstaged files; treat as added.
  if status == "untracked" then status = "added" end
  return {
    path = sf.path,
    status = status,
    old_path = sf.old_path,
  }
end

-- Entry point for the new CLI: attach to a running crit daemon.
-- args = { port, host, review_path, session_key }
function M.start_review_v2(args)
  if M.session then
    vim.notify("crit-vim: replacing stale review with new attach", vim.log.levels.WARN)
    close_session("replaced")
  end

  local ok, err = pcall(function()
    assert(args and args.port and args.review_path,
      "start_review_v2: port and review_path required")

    ensure_highlights()

    M.session = {
      port         = args.port,
      host         = args.host or "127.0.0.1",
      review_path  = args.review_path,
      session_key  = args.session_key,
      repo         = repo_root() or vim.fn.getcwd(),
      base         = nil,      -- filled by /api/session
      files        = {},       -- filled by /api/session
      file_bufs    = {},
      first_tab    = nil,
      sse          = nil,      -- subscription handle
      show_resolved = true,    -- toggle via :CritToggleResolved
      pending_render = {},     -- de-dupe scheduled per-file refreshes
    }

    -- Fetch the session snapshot synchronously via a blocking curl.
    local base = string.format("http://%s:%d", M.session.host, M.session.port)
    local out = vim.fn.system({ "curl", "-sS", "--max-time", "5",
      base .. "/api/session" })
    assert(vim.v.shell_error == 0, "GET /api/session failed: " .. tostring(out))
    local sess = vim.json.decode(out)
    assert(sess and sess.files, "malformed /api/session response")

    M.session.base = sess.base_ref
    M.session.branch = sess.branch
    M.session.review_round = sess.review_round or 1
    for _, sf in ipairs(sess.files) do
      table.insert(M.session.files, session_file_to_file_info(sf))
    end

    if #M.session.files == 0 then
      vim.notify("crit-vim: no changed files in this session", vim.log.levels.WARN)
    end

    for i, file_info in ipairs(M.session.files) do
      local bufs = open_file_diff(file_info, M.session.base, M.session.repo)
      M.session.file_bufs[file_info.path] = bufs
      if i == 1 then M.session.first_tab = bufs.tab end
      open_sidebar_in_current_tab()
    end

    if M.session.first_tab then
      pcall(vim.api.nvim_set_current_tabpage, M.session.first_tab)
    end

    M.render_all_comments()
    M.render_sidebar()

    -- Subscribe to server-sent events. re-render on any content change;
    -- close the review UI on server shutdown.
    M.session.sse = sse.subscribe({
      base_url = base,
      on_event = function(ev_type, _data)
        if ev_type == "comments-changed"
           or ev_type == "file-changed"
           or ev_type == "base-changed" then
          M.render_all_comments()
          M.render_sidebar()
        elseif ev_type == "server-shutdown" then
          vim.notify("crit-vim: crit daemon shut down", vim.log.levels.INFO)
          close_session("shutdown")
        end
      end,
    })
  end)

  if not ok then
    local msg = tostring(err)
    M.session = nil
    vim.notify("crit-vim: start_review_v2 failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  vim.notify(string.format(
    "crit-vim: %d file(s) · round %d · attached to crit @ port %d — :CritFinish to submit",
    #M.session.files, M.session.review_round or 1, M.session.port), vim.log.levels.INFO)
  return true
end

-- Legacy entry point kept for backwards-compat. If the caller still passes
-- a session_dir (old bash CLI), we bail with a friendly error — the CLI
-- was updated in lockstep.
function M.start_review(session_dir)
  vim.notify("crit-vim: legacy start_review invoked; upgrade `crit-vim` CLI "
    .. "(you're calling the old bash wrapper). Session_dir=" .. tostring(session_dir),
    vim.log.levels.ERROR)
  return false
end

-- Close review tabs without touching real-file buffers. Real-file buffers
-- may belong to the user's pre-existing workspace (they had the file open
-- before crit-vim review, or `:tabedit` reused an existing buffer); we don't
-- own them, so we don't wipe them. Scratch buffers we created (sidebar, base
-- content, deleted-file views) are wiped explicitly.
local function teardown_session_ui()
  if not M.session then return end
  -- Clear the review markers on real-file buffers so comment_at_cursor
  -- doesn't find them after the review ends.
  local seen_bv = {}
  for _, bufs in pairs(M.session.file_bufs) do
    for _, b in ipairs({ bufs.left, bufs.right }) do
      if b and not seen_bv[b] and vim.api.nvim_buf_is_valid(b)
         and vim.bo[b].buftype == "" then
        seen_bv[b] = true
        clear_review_buffer_vars(b)
      end
    end
  end
  local tabs_seen = {}
  for _, bufs in pairs(M.session.file_bufs) do
    if bufs.tab and not tabs_seen[bufs.tab]
       and vim.api.nvim_tabpage_is_valid(bufs.tab) then
      tabs_seen[bufs.tab] = true
      pcall(function()
        local n = vim.api.nvim_tabpage_get_number(bufs.tab)
        vim.cmd(n .. "tabclose")
      end)
    end
  end
  if M.session.sidebar_buf and vim.api.nvim_buf_is_valid(M.session.sidebar_buf) then
    pcall(vim.api.nvim_buf_delete, M.session.sidebar_buf, { force = true })
    M.session.sidebar_buf = nil
  end
  local seen = {}
  for _, bufs in pairs(M.session.file_bufs) do
    for _, b in ipairs({ bufs.left, bufs.right }) do
      if b and not seen[b] and vim.api.nvim_buf_is_valid(b)
         and vim.bo[b].buftype == "nofile" then
        seen[b] = true
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end
end

close_session = function(_result)
  if not M.session then return end
  -- Stop the SSE stream first so no late events fire re-renders on a torn-down UI.
  if M.session.sse and M.session.sse.stop then
    pcall(M.session.sse.stop)
  end
  teardown_session_ui()
  M.session = nil
end

-- Kill the crit daemon for this cwd+branch. Called from :CritCancel; the CLI
-- notices the session file disappear and exits.
local function stop_crit_daemon()
  vim.fn.jobstart({ "crit", "stop" }, { detach = true })
end

local function count_comments(session)
  if not session then return 0 end
  local data = read_review_file()
  if not data or not data.files then return 0 end
  local n = 0
  for _, f in pairs(data.files) do
    n = n + #(f.comments or {})
  end
  return n
end

-- Walk every right-side review buffer and report which are dirty real-file
-- buffers — the ones whose unsaved edits would be invisible to the agent.
local function dirty_review_files()
  local dirty, seen = {}, {}
  if not M.session then return dirty end
  for path, bufs in pairs(M.session.file_bufs) do
    local b = bufs.right
    if b and not seen[b] and vim.api.nvim_buf_is_valid(b)
       and vim.bo[b].buftype == "" and vim.bo[b].modified then
      seen[b] = true
      table.insert(dirty, { buf = b, path = path })
    end
  end
  return dirty
end

local function save_dirty_review_files()
  local saved, failed = 0, 0
  for _, entry in ipairs(dirty_review_files()) do
    local ok = pcall(vim.api.nvim_buf_call, entry.buf, function()
      vim.cmd("silent write")
    end)
    if ok then saved = saved + 1 else failed = failed + 1 end
  end
  return saved, failed
end

function M.finish()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  local saved, failed = save_dirty_review_files()
  if failed > 0 then
    vim.notify(string.format(
      "crit-vim: %d file(s) could not be saved — fix and retry, or :CritCancel to discard",
      failed), vim.log.levels.ERROR)
    return
  end
  local n = count_comments(M.session)

  -- Fire /api/finish (best effort) and stop the daemon so the blocked
  -- `crit --no-open` CLI exits. Do UI teardown + notification synchronously
  -- so the user sees confirmation immediately (not after HTTP round-trips).
  local base = string.format("http://%s:%d", M.session.host, M.session.port)
  http.post(base, "/api/finish", {}, function(_ok, _data, _status) end)
  stop_crit_daemon()

  local extra = saved > 0
    and string.format(" · saved %d edited file%s", saved, saved == 1 and "" or "s")
    or ""
  vim.notify(string.format("crit-vim: submitted review (%d comment%s)%s",
    n, n == 1 and "" or "s", extra), vim.log.levels.INFO)
  close_session("ok")
end

function M.cancel()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  local dirty = dirty_review_files()
  if #dirty > 0 then
    local resp = vim.fn.input(string.format(
      "crit-vim: %d file(s) have unsaved edits — discard? (y/N) ", #dirty))
    if (resp or ""):lower() ~= "y" then
      vim.notify("crit-vim: cancel aborted (use :CritFinish to save & submit)",
        vim.log.levels.INFO)
      return
    end
    for _, e in ipairs(dirty) do
      pcall(vim.api.nvim_buf_call, e.buf, function() vim.cmd("silent edit!") end)
    end
  end
  stop_crit_daemon()
  close_session("cancel")
  vim.notify("crit-vim: review cancelled", vim.log.levels.WARN)
end

-- ---------- comment authoring ----------

local function git_author()
  local email = vim.fn.systemlist({ "git", "config", "user.email" })[1] or ""
  if email == "" then return "unknown" end
  return email
end

local function uuid()
  local out = vim.fn.systemlist({ "uuidgen" })[1]
  if out and out ~= "" then return out:lower() end
  -- fallback: timestamp + randomness
  math.randomseed(os.time() + (os.clock() * 1e6))
  return string.format("%x-%x", os.time(), math.random(0, 2 ^ 30))
end

local function iso8601_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function compute_quote_and_anchor(bufnr, start_line, end_line)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local body = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local before_from = math.max(0, start_line - 1 - 3)
  local before = vim.api.nvim_buf_get_lines(bufnr, before_from, start_line - 1, false)
  local after_to = math.min(total, end_line + 3)
  local after = vim.api.nvim_buf_get_lines(bufnr, end_line, after_to, false)
  return table.concat(body, "\n"), {
    before = before,
    body = body,
    after = after,
    start_line = start_line,
    end_line = end_line,
  }
end

local function review_buffer_info()
  local bufnr = vim.api.nvim_get_current_buf()
  local side = vim.b[bufnr].crit_vim_side
  local file = vim.b[bufnr].crit_vim_file
  if not side or not file then return nil end
  return bufnr, side, file
end

local function open_comment_buffer(ctx)
  local buf = vim.api.nvim_create_buf(false, true)
  -- acwrite + BufWriteCmd so `:w` (and `ZZ`) saves the comment without
  -- needing a real file on disk.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  -- Plain text — no embedded-language detection (markdown was lighting up
  -- as HTML for some users).
  vim.bo[buf].filetype = "text"
  vim.api.nvim_buf_set_name(
    buf,
    string.format("critvim://%s/%d-%d", ctx.file, ctx.start_line, ctx.end_line)
  )

  local width = math.min(80, math.max(40, math.floor(vim.o.columns * 0.6)))
  local height = math.max(6, math.floor(vim.o.lines * 0.25))
  local title = string.format(" comment on %s:%d", ctx.file, ctx.start_line)
  if ctx.end_line ~= ctx.start_line then
    title = title .. "-" .. ctx.end_line
  end
  title = title .. "    <C-s>/:w save · q/:q cancel "

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  -- Soft-wrap long lines without inserting hard breaks.
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true

  ctx.win = win
  M._comment_ctx[buf] = ctx

  -- Prefill body when editing.
  if ctx.edit_body then
    local body_lines = {}
    for line in (ctx.edit_body .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(body_lines, line)
    end
    if body_lines[#body_lines] == "" then table.remove(body_lines) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, body_lines)
  end

  -- Primary save: <C-s> in normal and insert mode. Avoids any <leader>
  -- collision with the user's global maps (e.g. LazyVim's <leader>cs).
  vim.keymap.set({ "n", "i" }, "<C-s>", function() M._save_comment_buffer(buf) end,
    { buffer = buf, desc = "crit-vim: save comment" })

  -- Bare 'q' in normal mode cancels.
  vim.keymap.set("n", "q", function() M._cancel_comment_buffer(buf) end,
    { buffer = buf, desc = "crit-vim: cancel comment" })

  -- `:w` / `ZZ` save through this autocmd; `:q!` / closing the window cancels.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function() M._save_comment_buffer(buf) end,
  })

  -- Cleanup on any close path (including :q!, :bd!, closing the window).
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function() M._comment_ctx[buf] = nil end,
  })

  vim.cmd("startinsert")
end

function M.comment_range(s, e)
  -- Silent no-op when there's no active review or the current buffer isn't
  -- part of one — so users can bind <Plug>(CritComment) globally without
  -- getting warnings every time they press the key elsewhere.
  if not M.session then return end
  local info_buf, side, file = review_buffer_info()
  if not info_buf then return end
  local sl = math.min(s[1], e[1])
  local el = math.max(s[1], e[1])
  -- A motion past EOB can yield 0 for end_line; clamp.
  local total = vim.api.nvim_buf_line_count(info_buf)
  sl = math.max(1, math.min(sl, total))
  el = math.max(1, math.min(el, total))
  local quote, anchor = compute_quote_and_anchor(info_buf, sl, el)
  open_comment_buffer({
    file = file,
    side = side,
    start_line = sl,
    end_line = el,
    quote = quote,
    anchor = anchor,
  })
end

function M.comment_line(line)
  if not M.session then return end
  M.comment_range({ line }, { line })
end

function M._save_comment_buffer(buf)
  local ctx = M._comment_ctx[buf]
  if not ctx then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local body = vim.trim(table.concat(lines, "\n"))
  if body == "" then
    vim.notify("crit-vim: empty comment — press q to cancel", vim.log.levels.WARN)
    return
  end

  local function refresh_after()
    if vim.g.crit_vim_debug then
      vim.notify("[crit-vim.debug] refresh_after fired for " .. tostring(ctx.file),
        vim.log.levels.INFO)
    end
    M._refresh_signs_for_file(ctx.file)
    M.render_sidebar()
    -- Safety net: re-render 250ms later in case the first pass raced the
    -- daemon's write. Cheap (2 HTTP GETs on localhost).
    vim.defer_fn(function()
      if M.session then
        M._refresh_signs_for_file(ctx.file)
        M.render_sidebar()
      end
    end, 250)
  end

  if ctx.reply_to then
    M._api_add_reply(ctx.file, ctx.reply_to, body, function(ok)
      if ok then refresh_after() end
    end)
  elseif ctx.edit_reply_id then
    M._api_update_reply(ctx.file, ctx.edit_comment_id, ctx.edit_reply_id, body,
      function(ok) if ok then refresh_after() end end)
  elseif ctx.edit_id then
    M._api_update_comment(ctx.file, ctx.edit_id, body, function(ok)
      if ok then refresh_after() end
    end)
  else
    M._api_add_comment(ctx.file, ctx.side, ctx.start_line, ctx.end_line,
      body, ctx.quote, function(ok) if ok then refresh_after() end end)
  end
  M._comment_ctx[buf] = nil
  pcall(function() vim.bo[buf].modified = false end)
  vim.schedule(function()
    vim.cmd("stopinsert")
    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
      pcall(vim.api.nvim_win_close, ctx.win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end)
  local kind = ctx.reply_to and "reply"
    or ctx.edit_reply_id and "reply updated"
    or (ctx.edit_id and "updated" or "saved")
  vim.notify(string.format("crit-vim: comment %s (%s:%d)",
    kind, ctx.file, ctx.start_line), vim.log.levels.INFO)
end

function M._cancel_comment_buffer(buf)
  local ctx = M._comment_ctx[buf]
  M._comment_ctx[buf] = nil
  vim.cmd("stopinsert")
  if ctx and ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    pcall(vim.api.nvim_win_close, ctx.win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function file_status_for(file)
  for _, fi in ipairs(M.session.files) do
    if fi.path == file then return fi.status end
  end
  return "modified"
end

-- ---------- HTTP-based comment CRUD ----------

local function api_base_url()
  if not M.session then return nil end
  return string.format("http://%s:%d", M.session.host, M.session.port)
end

local function encode_path(p) return http.url_encode(p) end

-- Post a new line-anchored comment. `on_done(ok, comment)` fires after the
-- HTTP round-trip and after the re-render/notify. The server owns id,
-- created_at, and updated_at.
function M._api_add_comment(file, side, start_line, end_line, body, quote, on_done)
  local base = api_base_url()
  if not base then return end
  http.post(base, "/api/file/comments?path=" .. encode_path(file), {
    start_line = start_line,
    end_line   = end_line,
    side       = side,
    body       = body,
    quote      = quote,
    author     = git_author(),
    scope      = "line",
  }, function(ok, data, status)
    if not ok then
      vim.notify("crit-vim: add-comment failed (" .. tostring(status) .. "): "
        .. vim.inspect(data), vim.log.levels.ERROR)
    end
    if on_done then on_done(ok, data) end
  end)
end

function M._api_update_comment(file, id, body, on_done)
  local base = api_base_url()
  if not base then return end
  http.put(base, "/api/comment/" .. id .. "?path=" .. encode_path(file),
    { body = body }, function(ok, data, status)
      if not ok then
        vim.notify("crit-vim: update-comment failed (" .. tostring(status) .. "): "
          .. vim.inspect(data), vim.log.levels.ERROR)
      end
      if on_done then on_done(ok, data) end
    end)
end

function M._api_delete_comment(file, id, on_done)
  local base = api_base_url()
  if not base then return end
  http.delete(base, "/api/comment/" .. id .. "?path=" .. encode_path(file),
    function(ok, data, status)
      if not ok then
        vim.notify("crit-vim: delete failed (" .. tostring(status) .. "): "
          .. vim.inspect(data), vim.log.levels.ERROR)
      end
      if on_done then on_done(ok, data) end
    end)
end

function M._api_add_reply(file, id, body, on_done)
  local base = api_base_url()
  if not base then return end
  http.post(base, "/api/comment/" .. id .. "/replies?path=" .. encode_path(file),
    { body = body, author = git_author() }, function(ok, data, status)
      if not ok then
        vim.notify("crit-vim: reply failed (" .. tostring(status) .. "): "
          .. vim.inspect(data), vim.log.levels.ERROR)
      end
      if on_done then on_done(ok, data) end
    end)
end

function M._api_update_reply(file, comment_id, reply_id, body, on_done)
  local base = api_base_url()
  if not base then return end
  http.put(base, string.format("/api/comment/%s/replies/%s?path=%s",
      comment_id, reply_id, encode_path(file)),
    { body = body }, function(ok, data, status)
      if not ok then
        vim.notify("crit-vim: update-reply failed (" .. tostring(status) .. "): "
          .. vim.inspect(data), vim.log.levels.ERROR)
      end
      if on_done then on_done(ok, data) end
    end)
end

function M._api_delete_reply(file, comment_id, reply_id, on_done)
  local base = api_base_url()
  if not base then return end
  http.delete(base, string.format("/api/comment/%s/replies/%s?path=%s",
      comment_id, reply_id, encode_path(file)),
    function(ok, data, status)
      if not ok then
        vim.notify("crit-vim: delete-reply failed (" .. tostring(status) .. "): "
          .. vim.inspect(data), vim.log.levels.ERROR)
      end
      if on_done then on_done(ok, data) end
    end)
end

function M._api_set_resolved(file, id, resolved, on_done)
  local base = api_base_url()
  if not base then return end
  http.put(base, "/api/comment/" .. id .. "/resolve?path=" .. encode_path(file),
    { resolved = resolved }, function(ok, data, status)
      if not ok then
        vim.notify("crit-vim: resolve failed (" .. tostring(status) .. "): "
          .. vim.inspect(data), vim.log.levels.ERROR)
      end
      if on_done then on_done(ok, data) end
    end)
end

-- Convenience wrappers used by legacy code paths in this file. They fire
-- HTTP under the hood and re-render on success. Callers used to rely on
-- synchronous file writes; with HTTP + SSE we optimistically update after
-- the server confirms.
function M._append_comment(file, comment)
  M._api_add_comment(file, comment.side, comment.start_line, comment.end_line,
    comment.body, comment.quote, function(ok)
      if ok then
        M._refresh_signs_for_file(file)
        M.render_sidebar()
      end
    end)
end

function M._replace_comment(file, id, new_comment)
  M._api_update_comment(file, id, new_comment.body, function(ok)
    if ok then
      M._refresh_signs_for_file(file)
      M.render_sidebar()
    end
  end)
end

function M._delete_comment(file, id)
  M._api_delete_comment(file, id, function(ok)
    if ok then
      M._refresh_signs_for_file(file)
      M.render_sidebar()
    end
  end)
  -- Legacy contract returns bool synchronously; assume the request was fired.
  return true
end

local function comment_at_cursor()
  if not M.session then return nil end
  local bufnr = vim.api.nvim_get_current_buf()
  local side = vim.b[bufnr].crit_vim_side
  local file = vim.b[bufnr].crit_vim_file
  if not side or not file then return nil end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  -- Fetch live from the daemon; falls back to the review file on error.
  local comments = api_get_file_comments(file)
  if not comments then
    local data = load_comments()
    local fdata = data.files[file]
    if not fdata then return nil end
    comments = fdata.comments or {}
  end
  -- Pick the last (most recent) comment whose anchor covers the cursor line.
  local match
  for _, c in ipairs(comments) do
    if norm_side(c.side) == side
       and (c.start_line or 0) <= line
       and (c.end_line or 0) >= line then
      match = c
    end
  end
  if match then return match, file end
  return nil
end

function M.edit_at_cursor()
  local c, file = comment_at_cursor()
  if not c then
    vim.notify("crit-vim: no comment under cursor", vim.log.levels.WARN)
    return
  end
  open_comment_buffer({
    file = file,
    side = c.side,
    start_line = c.start_line,
    end_line = c.end_line,
    quote = c.quote,
    anchor = c.anchor,
    edit_id = c.id,
    edit_body = c.body,
  })
end

function M.delete_at_cursor()
  local c, file = comment_at_cursor()
  if not c then
    vim.notify("crit-vim: no comment under cursor", vim.log.levels.WARN)
    return
  end
  local preview = (c.body or ""):gsub("\r?\n.*$", "")
  if #preview > 50 then preview = preview:sub(1, 47) .. "..." end
  local resp = vim.fn.input(string.format("delete \"%s\"? (y/N) ", preview))
  if (resp or ""):lower() ~= "y" then
    vim.notify("crit-vim: delete cancelled", vim.log.levels.INFO)
    return
  end
  if M._delete_comment(file, c.id) then
    M._refresh_signs_for_file(file)
    M.render_sidebar()
    vim.notify("crit-vim: comment deleted", vim.log.levels.INFO)
  end
end

-- ---------- replies + resolve ----------

-- Open a floating buffer to compose a reply to the comment under cursor.
function M.reply_at_cursor()
  local c, file = comment_at_cursor()
  if not c then
    vim.notify("crit-vim: no comment under cursor", vim.log.levels.WARN)
    return
  end
  open_comment_buffer({
    file = file,
    side = c.side,
    start_line = c.start_line,
    end_line = c.end_line,
    quote = c.quote,
    anchor = c.anchor,
    reply_to = c.id,
  })
end

-- Set the comment under the cursor to `desired` (true = resolved, false =
-- unresolved). `nil` toggles. No-op if already in the requested state.
function M.set_resolved_at_cursor(desired)
  local c, file = comment_at_cursor()
  if not c then
    vim.notify("crit-vim: no comment under cursor", vim.log.levels.WARN)
    return
  end
  if desired == nil then desired = not c.resolved end
  if desired == (not not c.resolved) then
    vim.notify(string.format("crit-vim: comment already %s",
      desired and "resolved" or "unresolved"), vim.log.levels.INFO)
    return
  end
  M._api_set_resolved(file, c.id, desired, function(ok)
    if ok then
      M._refresh_signs_for_file(file)
      M.render_sidebar()
      vim.notify(string.format("crit-vim: comment %s",
        desired and "resolved" or "unresolved"), vim.log.levels.INFO)
    end
  end)
end

-- Backwards-compat: <Plug>(CritResolve) and older docs treated resolve as a toggle.
function M.toggle_resolved_at_cursor() M.set_resolved_at_cursor(nil) end
function M.resolve_at_cursor()         M.set_resolved_at_cursor(true) end
function M.unresolve_at_cursor()       M.set_resolved_at_cursor(false) end

function M.toggle_show_resolved()
  if not M.session then return end
  M.session.show_resolved = not M.session.show_resolved
  M.render_all_comments()
  M.render_sidebar()
  vim.notify("crit-vim: resolved comments now "
    .. (M.session.show_resolved and "shown" or "hidden"), vim.log.levels.INFO)
end

-- Pick one of the comment's replies with vim.ui.select and call `cb(reply)`.
-- Silent no-op if the comment has no replies.
local function pick_reply(c, prompt, cb)
  local replies = c.replies or {}
  if #replies == 0 then
    vim.notify("crit-vim: this comment has no replies", vim.log.levels.WARN)
    return
  end
  local items = {}
  for i, r in ipairs(replies) do
    local preview = (r.body or ""):gsub("\r?\n.*$", "")
    if #preview > 60 then preview = preview:sub(1, 57) .. "..." end
    items[i] = string.format("%d. @%s — %s", i, r.author or "?", preview)
  end
  vim.ui.select(items, { prompt = prompt }, function(_, idx)
    if idx and replies[idx] then cb(replies[idx]) end
  end)
end

function M.edit_reply_at_cursor()
  local c, file = comment_at_cursor()
  if not c then
    vim.notify("crit-vim: no comment under cursor", vim.log.levels.WARN)
    return
  end
  pick_reply(c, "Edit which reply?", function(reply)
    open_comment_buffer({
      file = file,
      side = c.side,
      start_line = c.start_line,
      end_line = c.end_line,
      quote = c.quote,
      anchor = c.anchor,
      edit_reply_id = reply.id,
      edit_comment_id = c.id,
      edit_body = reply.body,
    })
  end)
end

function M.delete_reply_at_cursor()
  local c, file = comment_at_cursor()
  if not c then
    vim.notify("crit-vim: no comment under cursor", vim.log.levels.WARN)
    return
  end
  pick_reply(c, "Delete which reply?", function(reply)
    local preview = (reply.body or ""):gsub("\r?\n.*$", "")
    if #preview > 50 then preview = preview:sub(1, 47) .. "..." end
    local resp = vim.fn.input(string.format("delete reply \"%s\"? (y/N) ", preview))
    if (resp or ""):lower() ~= "y" then return end
    M._api_delete_reply(file, c.id, reply.id, function(ok)
      if ok then
        M._refresh_signs_for_file(file)
        M.render_sidebar()
        vim.notify("crit-vim: reply deleted", vim.log.levels.INFO)
      end
    end)
  end)
end


function M.reopen()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  -- Tear down stale tabs + scratch buffers; preserve real-file buffers (they
  -- may hold the user's unsaved edits — we don't want to lose those).
  teardown_session_ui()
  M.session.file_bufs = {}
  for i, file_info in ipairs(M.session.files) do
    local bufs = open_file_diff(file_info, M.session.base, M.session.repo)
    M.session.file_bufs[file_info.path] = bufs
    if i == 1 then M.session.first_tab = bufs.tab end
    open_sidebar_in_current_tab()
  end
  if M.session.first_tab then
    pcall(vim.api.nvim_set_current_tabpage, M.session.first_tab)
  end
  M.render_all_comments()
  M.render_sidebar()
end

-- ---------- rendering ----------

-- Word-wrap `text` so no segment exceeds `width` display cells. Falls back
-- to a hard character-boundary split for tokens that are longer than
-- `width` on their own (e.g. a giant URL).
local function wrap_line(text, width)
  if vim.fn.strdisplaywidth(text) <= width then return { text } end

  local out = {}
  local cur = ""
  local function push(s)
    while vim.fn.strdisplaywidth(s) > width do
      local n = 1
      while n <= #s and vim.fn.strdisplaywidth(s:sub(1, n)) <= width do
        n = n + 1
      end
      table.insert(out, s:sub(1, n - 1))
      s = s:sub(n)
    end
    if #s > 0 then table.insert(out, s) end
  end

  for _, w in ipairs(vim.split(text, " ", { plain = true })) do
    if cur == "" then
      cur = w
    elseif vim.fn.strdisplaywidth(cur .. " " .. w) <= width then
      cur = cur .. " " .. w
    else
      push(cur)
      cur = w
    end
  end
  if cur ~= "" then push(cur) end

  return out
end

function M._refresh_signs_for_file(file)
  local bufs = M.session and M.session.file_bufs[file]
  if not bufs then
    if vim.g.crit_vim_debug then
      vim.notify("[crit-vim.debug] refresh: no bufs for " .. tostring(file), vim.log.levels.WARN)
    end
    return
  end

  -- For added/deleted files left==right; dedupe so we don't clear twice.
  local seen = {}
  for _, buf in ipairs({ bufs.left, bufs.right }) do
    if not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
      seen[buf] = true
      vim.api.nvim_buf_clear_namespace(buf, M._ns, 0, -1)
    end
  end

  -- Prefer the live HTTP source (no debounce staleness). Fall back to
  -- reading the review file if the daemon is unreachable.
  local comments = api_get_file_comments(file)
  if not comments then
    local data = read_review_file()
    if not data or not data.files or not data.files[file] then return end
    comments = data.files[file].comments or {}
  end
  if vim.g.crit_vim_debug then
    vim.notify(string.format("[crit-vim.debug] refresh %s: %d comment(s)",
      file, #comments), vim.log.levels.INFO)
  end

  local show_resolved = (M.session and M.session.show_resolved ~= false)
  for _, c in ipairs(comments) do
    if c.resolved and not show_resolved then
      -- Skip rendering entirely when the user has toggled resolved off.
      goto continue
    end
    local buf = norm_side(c.side) == "left" and bufs.left or bufs.right
    if vim.api.nvim_buf_is_valid(buf) then
      local line_count = vim.api.nvim_buf_line_count(buf)
      local start_l = math.max((c.start_line or 1) - 1, 0)
      local end_l   = math.min((c.end_line or c.start_line or 1) - 1, line_count - 1)
      if end_l < start_l then end_l = start_l end

      -- Bar in the sign column + range background on every line of the
      -- comment span. One extmark per line so it survives partial edits.
      for l = start_l, end_l do
        vim.api.nvim_buf_set_extmark(buf, M._ns, l, 0, {
          sign_text = "▎",
          sign_hl_group = "CritVimCommentBar",
          line_hl_group = c.resolved and nil or "CritVimCommentRange",
          priority = 50,
        })
      end

      -- Bordered comment box rendered as virt_lines below the range.
      -- Body word-wrapped at `target_width`. Reply threads render inside
      -- the same box, separated by a divider row.
      local target_width = 76
      local body_hl = c.resolved and "CritVimCommentResolved" or "CritVimCommentBody"

      local resolved_marker = c.resolved and "  ✓ resolved" or ""
      local author_line = "@" .. (c.author or "?") .. resolved_marker

      -- Sections = {section, section, ...} where each section is a list of
      -- {text, hl} rows (with author already prefixed). Sections are joined
      -- with a divider row between them.
      local sections = {}

      local function wrap_body_into(rows, body, hl)
        for _, bl in ipairs(vim.split(body or "", "\r?\n")) do
          local segs = wrap_line(bl, target_width)
          if #segs == 0 then
            table.insert(rows, { "", hl })
          else
            for _, seg in ipairs(segs) do table.insert(rows, { seg, hl }) end
          end
        end
      end

      -- Root section (the comment itself).
      local root_rows = {}
      for _, seg in ipairs(wrap_line(author_line, target_width)) do
        table.insert(root_rows, { seg, "CritVimCommentBody" })
      end
      table.insert(root_rows, { "", body_hl })  -- spacer under header
      wrap_body_into(root_rows, c.body, body_hl)
      table.insert(sections, root_rows)

      -- Reply sections.
      for _, r in ipairs(c.replies or {}) do
        local reply_rows = {}
        local prefix = "↳ @" .. (r.author or "?")
        for _, seg in ipairs(wrap_line(prefix, target_width)) do
          table.insert(reply_rows, { seg, "CritVimCommentReplyAuthor" })
        end
        table.insert(reply_rows, { "", "CritVimCommentReply" })
        wrap_body_into(reply_rows, r.body, "CritVimCommentReply")
        table.insert(sections, reply_rows)
      end

      -- Compute the box's inner width from the widest rendered row.
      local inner_width = 20
      for _, sec in ipairs(sections) do
        for _, row in ipairs(sec) do
          inner_width = math.max(inner_width, vim.fn.strdisplaywidth(row[1]))
        end
      end
      if inner_width > target_width then inner_width = target_width end

      local border_top    = "╭" .. string.rep("─", inner_width + 2) .. "╮"
      local border_bottom = "╰" .. string.rep("─", inner_width + 2) .. "╯"
      local divider       = "├" .. string.rep("┈", inner_width + 2) .. "┤"

      local virt = { { { border_top, "CritVimCommentBorder" } } }

      local function push_row(text, hl)
        local pad = inner_width - vim.fn.strdisplaywidth(text)
        if pad < 0 then pad = 0 end
        table.insert(virt, {
          { "│ ",                        "CritVimCommentBorder" },
          { text,                        hl },
          { string.rep(" ", pad) .. " ", hl },
          { "│",                         "CritVimCommentBorder" },
        })
      end

      for i, sec in ipairs(sections) do
        if i > 1 then
          table.insert(virt, { { divider, "CritVimCommentDivider" } })
        end
        for _, row in ipairs(sec) do push_row(row[1], row[2]) end
      end

      table.insert(virt, { { border_bottom, "CritVimCommentBorder" } })

      -- Nvim clips virt_lines rendered below the last buffer line. Flip
      -- the anchor to above `start_l` when the comment sits on the last
      -- line so the box stays visible.
      local at_last_line = (end_l == line_count - 1)
      local anchor_row   = at_last_line and start_l or end_l
      vim.api.nvim_buf_set_extmark(buf, M._ns, anchor_row, 0, {
        virt_lines = virt,
        virt_lines_above = at_last_line,
        priority = 50,
      })
    end
    ::continue::
  end
end

function M.render_all_comments()
  if not M.session then return end
  local data = read_review_file()
  -- Render every session file (some files may have no comments yet).
  for _, fi in ipairs(M.session.files or {}) do
    M._refresh_signs_for_file(fi.path)
  end
  -- Then anything else that has comments but isn't tracked (defensive).
  for file, _ in pairs(data.files or {}) do
    M._refresh_signs_for_file(file)
  end
end

function M.list()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  local data = read_review_file()
  local items = {}
  for file, fdata in pairs(data.files or {}) do
    for _, c in ipairs(fdata.comments or {}) do
      local first_line = (c.body or ""):gsub("\r?\n.*$", "")
      table.insert(items, {
        filename = M.session.repo .. "/" .. file,
        lnum = c.start_line,
        text = string.format("[%s] %s", c.side or "?", first_line),
      })
    end
  end
  if #items == 0 then
    vim.notify("crit-vim: no comments yet", vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, " ", { title = "crit-vim comments", items = items })
  vim.cmd("copen")
end

-- Locate the plugin's VERSION file by walking up from this init.lua.
local function plugin_version()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then source = source:sub(2) end
  local plugin_dir = source:match("^(.*)/lua/crit%-vim/init%.lua$")
  if not plugin_dir then return "(unknown)" end
  local f = io.open(plugin_dir .. "/VERSION", "r")
  if not f then return "(unknown)" end
  local v = (f:read("*a") or ""):gsub("%s+", "")
  f:close()
  return v ~= "" and v or "(unknown)"
end

-- Print crit-vim plugin version + crit CLI version + (if a review is active)
-- session summary + daemon health.
function M.version()
  local lines = { "crit-vim plugin: " .. plugin_version() }

  local cli = vim.fn.systemlist({ "crit", "--version" })
  if vim.v.shell_error == 0 and cli[1] then
    table.insert(lines, "crit CLI:        " .. cli[1])
  else
    table.insert(lines, "crit CLI:        (not on $PATH)")
  end

  if M.session then
    local base = string.format("http://%s:%d", M.session.host, M.session.port)
    table.insert(lines, "")
    table.insert(lines, string.format("session:         port=%d key=%s",
      M.session.port, M.session.session_key or "?"))
    table.insert(lines, string.format("branch/base:     %s → %s",
      M.session.branch or "?", M.session.base or "?"))
    table.insert(lines, string.format("round:           %d",
      M.session.review_round or 1))
    table.insert(lines, string.format("files:           %d", #(M.session.files or {})))
    local health = vim.fn.system({ "curl", "-sS", "--max-time", "2", base .. "/api/health" })
    if vim.v.shell_error == 0 then
      table.insert(lines, "daemon health:   " .. (health or ""):gsub("%s+$", ""))
    else
      table.insert(lines, "daemon health:   (unreachable)")
    end
  else
    table.insert(lines, "")
    table.insert(lines, "session:         (no active review)")
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- Optional convenience for users who don't want to write their own `keys`
-- block. Call with `{ default_keys = true }` to bind <leader>C{,C} to the
-- <Plug> targets globally.
function M.setup(opts)
  opts = opts or {}
  if opts.default_keys then
    vim.keymap.set({ "n", "x" }, "<leader>C", "<Plug>(CritComment)",
      { desc = "Crit: comment (motion / visual)" })
    vim.keymap.set("n", "<leader>CC", "<Plug>(CritCommentLine)",
      { desc = "Crit: comment current line" })
  end
end

return M
