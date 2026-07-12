-- crit-vim: review an agent's diff inside the user's running nvim and ship
-- comments back as crit-shape JSON.

local M = {}

M.session = nil          -- {dir, base, repo, files, file_bufs, tab_pages}
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
    CritVimCommentBar    = { link = "DiagnosticInfo" },  -- signcolumn bar
    CritVimCommentRange  = { link = "DiffChange" },      -- background of the commented range
    CritVimCommentBorder = { link = "FloatBorder" },     -- ╭─╮│╰─╯ around the box
    CritVimCommentBody   = { link = "NormalFloat" },     -- box interior text + padding
    CritVimCommentMeta   = { link = "NonText" },         -- resolved marker etc.
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
  local data = read_json(M.session.dir .. "/comments.json") or { files = {} }
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

function M.start_review(session_dir)
  if M.session then
    -- A previous session is stale (user ran <C-w>o, the agent died, etc).
    -- Cancel it so its bash reader unblocks, then start fresh.
    vim.notify("crit-vim: cancelling stale review and starting new", vim.log.levels.WARN)
    close_session("cancel")
  end

  local ok, err = pcall(function()
    local meta = read_json(session_dir .. "/meta.json")
    assert(meta, "cannot read meta.json")
    assert(meta.repo_root and meta.base and meta.files, "meta.json missing fields")

    ensure_highlights()

    M.session = {
      dir = session_dir,
      base = meta.base,
      repo = meta.repo_root,
      files = meta.files,
      file_bufs = {},
      first_tab = nil,
    }

    for i, file_info in ipairs(meta.files) do
      local bufs = open_file_diff(file_info, meta.base, meta.repo_root)
      M.session.file_bufs[file_info.path] = bufs
      if i == 1 then M.session.first_tab = bufs.tab end
      open_sidebar_in_current_tab()
    end

    if M.session.first_tab then
      pcall(vim.api.nvim_set_current_tabpage, M.session.first_tab)
    end

    M.render_all_comments()
    M.render_sidebar()
  end)

  if not ok then
    local msg = tostring(err)
    pcall(write_file, session_dir .. "/error", msg)
    pcall(write_file, session_dir .. "/result", "error")
    -- Best-effort: signal the FIFO so the bash reader unblocks.
    pcall(write_file, session_dir .. "/done", "\n")
    M.session = nil
    vim.notify("crit-vim: start_review failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  vim.notify(string.format(
    "crit-vim: %d file(s) — :CritFiles to list · gt/gT to navigate · :CritFinish to submit",
    #M.session.files), vim.log.levels.INFO)
  return true
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

close_session = function(result)
  if not M.session then return end
  local dir = M.session.dir
  teardown_session_ui()
  pcall(write_file, dir .. "/result", result)
  -- Signal the bash reader. Writing to a FIFO with no reader would block;
  -- the bash side opens the read end before invoking us, so this is safe.
  pcall(write_file, dir .. "/done", result .. "\n")
  M.session = nil
end

local function count_comments(session)
  if not session then return 0 end
  local data = read_json(session.dir .. "/comments.json")
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
  close_session("ok")
  local extra = saved > 0
    and string.format(" · saved %d edited file%s", saved, saved == 1 and "" or "s")
    or ""
  vim.notify(string.format("crit-vim: submitted review (%d comment%s)%s",
    n, n == 1 and "" or "s", extra), vim.log.levels.INFO)
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
    -- Discard unsaved changes by reverting the buffers.
    for _, e in ipairs(dirty) do
      pcall(vim.api.nvim_buf_call, e.buf, function() vim.cmd("silent edit!") end)
    end
  end
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
  local comment = {
    id = uuid(),
    start_line = ctx.start_line,
    end_line = ctx.end_line,
    side = ctx.side,
    scope = "line",
    body = body,
    resolved = false,
    resolved_round = 0,
    replies = {},
    created_at = iso8601_now(),
    author = git_author(),
    quote = ctx.quote,
    anchor = ctx.anchor,
  }
  if ctx.edit_id then
    comment.id = ctx.edit_id
    M._replace_comment(ctx.file, ctx.edit_id, comment)
  else
    M._append_comment(ctx.file, comment)
  end
  M._comment_ctx[buf] = nil
  pcall(function() vim.bo[buf].modified = false end)
  -- Defer cleanup so we're not mutating window/buffer state inside a
  -- BufWriteCmd autocmd. stopinsert ensures the diff buffer we return to
  -- doesn't get keystrokes as insert-mode input.
  vim.schedule(function()
    vim.cmd("stopinsert")
    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
      pcall(vim.api.nvim_win_close, ctx.win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end)
  M._refresh_signs_for_file(ctx.file)
  M.render_sidebar()
  vim.notify(string.format("crit-vim: comment %s (%s:%d)",
    ctx.edit_id and "updated" or "saved", ctx.file, ctx.start_line),
    vim.log.levels.INFO)
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

local function load_comments()
  local path = M.session.dir .. "/comments.json"
  local data = read_json(path) or { files = {}, review_comments = {} }
  if type(data.files) ~= "table" then data.files = {} end
  if type(data.review_comments) ~= "table" then data.review_comments = {} end
  return data, path
end

local function file_status_for(file)
  for _, fi in ipairs(M.session.files) do
    if fi.path == file then return fi.status end
  end
  return "modified"
end

function M._append_comment(file, comment)
  local data, path = load_comments()
  if not data.files[file] then
    data.files[file] = { status = file_status_for(file), comments = {} }
  end
  table.insert(data.files[file].comments, comment)
  write_json(path, data)
end

function M._replace_comment(file, id, new_comment)
  local data, path = load_comments()
  local fdata = data.files[file]
  if not fdata then return end
  for i, c in ipairs(fdata.comments or {}) do
    if c.id == id then
      fdata.comments[i] = new_comment
      write_json(path, data)
      return
    end
  end
end

function M._delete_comment(file, id)
  local data, path = load_comments()
  local fdata = data.files[file]
  if not fdata then return false end
  for i, c in ipairs(fdata.comments or {}) do
    if c.id == id then
      table.remove(fdata.comments, i)
      write_json(path, data)
      return true
    end
  end
  return false
end

local function comment_at_cursor()
  if not M.session then return nil end
  local bufnr = vim.api.nvim_get_current_buf()
  local side = vim.b[bufnr].crit_vim_side
  local file = vim.b[bufnr].crit_vim_file
  if not side or not file then return nil end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local data = load_comments()
  local fdata = data.files[file]
  if not fdata then return nil end
  -- Pick the last (most recent) comment whose anchor covers the cursor line.
  local match
  for _, c in ipairs(fdata.comments or {}) do
    if c.side == side and (c.start_line or 0) <= line and (c.end_line or 0) >= line then
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
  if not bufs then return end

  -- For added/deleted files left==right; dedupe so we don't clear twice.
  local seen = {}
  for _, buf in ipairs({ bufs.left, bufs.right }) do
    if not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
      seen[buf] = true
      vim.api.nvim_buf_clear_namespace(buf, M._ns, 0, -1)
    end
  end

  local data = read_json(M.session.dir .. "/comments.json")
  if not data or not data.files or not data.files[file] then return end

  for _, c in ipairs(data.files[file].comments or {}) do
    local buf = c.side == "left" and bufs.left or bufs.right
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
          line_hl_group = "CritVimCommentRange",
          priority = 50,
        })
      end

      -- Bordered comment box rendered as virt_lines below the range.
      -- Padded to a consistent inner width so the box background reads
      -- as one solid contrasting card. Long lines are word-wrapped at
      -- `target_width` cells so nothing overflows the box.
      local body = c.body or ""
      local body_lines = vim.split(body, "\r?\n")
      local resolved_marker = c.resolved and "  ✓" or ""
      local author_line = "@" .. (c.author or "?") .. resolved_marker

      local target_width = 76

      local wrapped_author = wrap_line(author_line, target_width)
      local wrapped_body = {}
      for _, bl in ipairs(body_lines) do
        local segs = wrap_line(bl, target_width)
        if #segs == 0 then
          table.insert(wrapped_body, "")
        else
          for _, seg in ipairs(segs) do table.insert(wrapped_body, seg) end
        end
      end

      local inner_width = 20  -- min
      for _, s in ipairs(wrapped_author) do
        inner_width = math.max(inner_width, vim.fn.strdisplaywidth(s))
      end
      for _, s in ipairs(wrapped_body) do
        inner_width = math.max(inner_width, vim.fn.strdisplaywidth(s))
      end
      if inner_width > target_width then inner_width = target_width end

      local border_top    = "╭" .. string.rep("─", inner_width + 2) .. "╮"
      local border_bottom = "╰" .. string.rep("─", inner_width + 2) .. "╯"

      local virt = { { { border_top, "CritVimCommentBorder" } } }

      local function push_row(text)
        local pad = inner_width - vim.fn.strdisplaywidth(text)
        if pad < 0 then pad = 0 end
        table.insert(virt, {
          { "│ ",                        "CritVimCommentBorder" },
          { text,                        "CritVimCommentBody" },
          { string.rep(" ", pad) .. " ", "CritVimCommentBody" },
          { "│",                         "CritVimCommentBorder" },
        })
      end

      for _, s in ipairs(wrapped_author) do push_row(s) end
      if #wrapped_body > 0 then push_row("") end   -- spacer under header
      for _, s in ipairs(wrapped_body) do push_row(s) end

      table.insert(virt, { { border_bottom, "CritVimCommentBorder" } })

      vim.api.nvim_buf_set_extmark(buf, M._ns, end_l, 0, {
        virt_lines = virt,
        virt_lines_above = false,
        priority = 50,
      })
    end
  end
end

function M.render_all_comments()
  if not M.session then return end
  local data = read_json(M.session.dir .. "/comments.json") or { files = {} }
  for file, _ in pairs(data.files or {}) do
    M._refresh_signs_for_file(file)
  end
end

function M.list()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  local data = read_json(M.session.dir .. "/comments.json") or { files = {} }
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
