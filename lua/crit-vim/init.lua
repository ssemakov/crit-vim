-- crit-vim: review an agent's diff inside the user's running nvim and ship
-- comments back as crit-shape JSON.

local M = {}

M.session = nil          -- {dir, base, repo, files, file_bufs, tab_pages}
M._comment_ctx = {}      -- bufnr -> draft context
M._ns = vim.api.nvim_create_namespace("crit_vim")

local SIGN_GROUP = "crit_vim"
local SIGN_NAME = "CritVimComment"
local sign_defined = false

local function ensure_sign()
  if sign_defined then return end
  vim.fn.sign_define(SIGN_NAME, { text = ">>", texthl = "DiagnosticInfo" })
  sign_defined = true
end

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

local function read_working_file(repo, path)
  local full = repo .. "/" .. path
  local f = io.open(full, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local out = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(out, line)
  end
  -- gmatch above leaves a trailing empty string for files ending in \n; drop it.
  if out[#out] == "" then table.remove(out) end
  return out
end

local function open_file_diff(file_info, base, repo)
  vim.cmd("tabnew")
  local right_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(right_buf, file_info.path .. " [working]")
  if file_info.status ~= "deleted" then
    fill_buffer(right_buf, read_working_file(repo, file_info.path))
  else
    fill_buffer(right_buf, {})
  end
  set_review_buffer(right_buf, file_info.path, "right", file_info.path)
  vim.cmd("diffthis")

  vim.cmd("leftabove vsplit | enew")
  local left_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(left_buf, file_info.path .. " [" .. base .. "]")
  if file_info.status ~= "added" then
    local src_path = file_info.old_path or file_info.path
    fill_buffer(left_buf, git_show(repo, base, src_path))
  else
    fill_buffer(left_buf, {})
  end
  set_review_buffer(left_buf, file_info.path, "left", file_info.path)
  vim.cmd("diffthis")

  return {
    left = left_buf,
    right = right_buf,
    file = file_info.path,
    tab = vim.api.nvim_get_current_tabpage(),
  }
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

    ensure_sign()

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
    end

    if M.session.first_tab then
      pcall(vim.api.nvim_set_current_tabpage, M.session.first_tab)
    end

    M.render_all_comments()
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

close_session = function(result)
  if not M.session then return end
  local dir = M.session.dir
  for _, bufs in pairs(M.session.file_bufs) do
    pcall(vim.api.nvim_buf_delete, bufs.left, { force = true })
    pcall(vim.api.nvim_buf_delete, bufs.right, { force = true })
  end
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

function M.finish()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  local n = count_comments(M.session)
  close_session("ok")
  vim.notify(string.format("crit-vim: submitted review (%d comment%s)",
    n, n == 1 and "" or "s"), vim.log.levels.INFO)
end

function M.cancel()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
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
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  local info_buf, side, file = review_buffer_info()
  if not info_buf then
    vim.notify("crit-vim: not in a review buffer", vim.log.levels.WARN)
    return
  end
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
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
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
    vim.notify("crit-vim: comment deleted", vim.log.levels.INFO)
  end
end

function M.reopen()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  -- Wipe any stale review buffers we know about so we get a clean rebuild.
  for _, bufs in pairs(M.session.file_bufs) do
    if vim.api.nvim_buf_is_valid(bufs.left) then
      pcall(vim.api.nvim_buf_delete, bufs.left, { force = true })
    end
    if vim.api.nvim_buf_is_valid(bufs.right) then
      pcall(vim.api.nvim_buf_delete, bufs.right, { force = true })
    end
  end
  M.session.file_bufs = {}
  for i, file_info in ipairs(M.session.files) do
    local bufs = open_file_diff(file_info, M.session.base, M.session.repo)
    M.session.file_bufs[file_info.path] = bufs
    if i == 1 then M.session.first_tab = bufs.tab end
  end
  if M.session.first_tab then
    pcall(vim.api.nvim_set_current_tabpage, M.session.first_tab)
  end
  M.render_all_comments()
end

function M.files_picker()
  if not M.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  local lines, statuses = {}, {}
  for _, fi in ipairs(M.session.files) do
    table.insert(lines, string.format("  [%-8s] %s", fi.status, fi.path))
    table.insert(statuses, fi)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "critvim_files"

  local width = math.min(100, math.max(50, math.floor(vim.o.columns * 0.6)))
  local height = math.min(#lines + 2, math.max(8, math.floor(vim.o.lines * 0.5)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " crit-vim files — <CR> jump · q close ",
    title_pos = "center",
  })

  local function jump()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local fi = statuses[row]
    pcall(vim.api.nvim_win_close, win, true)
    if not fi then return end
    local bufs = M.session.file_bufs[fi.path]
    if bufs and bufs.tab and vim.api.nvim_tabpage_is_valid(bufs.tab) then
      vim.api.nvim_set_current_tabpage(bufs.tab)
    else
      -- Tab was closed; rebuild then jump.
      M.reopen()
      bufs = M.session.file_bufs[fi.path]
      if bufs and bufs.tab and vim.api.nvim_tabpage_is_valid(bufs.tab) then
        vim.api.nvim_set_current_tabpage(bufs.tab)
      end
    end
  end

  vim.keymap.set("n", "<CR>", jump, { buffer = buf })
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end,
    { buffer = buf })
end

-- ---------- rendering ----------

function M._refresh_signs_for_file(file)
  local bufs = M.session and M.session.file_bufs[file]
  if not bufs then return end

  for _, buf in ipairs({ bufs.left, bufs.right }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.fn.sign_unplace(SIGN_GROUP, { buffer = buf })
      vim.api.nvim_buf_clear_namespace(buf, M._ns, 0, -1)
    end
  end

  local data = read_json(M.session.dir .. "/comments.json")
  if not data or not data.files or not data.files[file] then return end

  for _, c in ipairs(data.files[file].comments or {}) do
    local buf = c.side == "left" and bufs.left or bufs.right
    if vim.api.nvim_buf_is_valid(buf) then
      vim.fn.sign_place(0, SIGN_GROUP, SIGN_NAME, buf,
        { lnum = c.start_line, priority = 50 })
      local first_line = (c.body or ""):gsub("\r?\n.*$", "")
      if #first_line > 60 then first_line = first_line:sub(1, 57) .. "..." end
      local marker = c.resolved and " ✓" or ""
      vim.api.nvim_buf_set_extmark(buf, M._ns, c.start_line - 1, 0, {
        virt_text = {
          { "  " .. first_line, "Comment" },
          { string.format(" @%s%s", c.author or "?", marker), "NonText" },
        },
        virt_text_pos = "eol",
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

return M
