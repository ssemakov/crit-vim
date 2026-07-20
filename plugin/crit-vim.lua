if vim.g.loaded_crit_vim then return end
vim.g.loaded_crit_vim = 1

local crit = require("crit-vim")

-- Maintain a per-repo socket registry so the CLI can find this nvim from a
-- sibling tmux pane (where $NVIM is not set).
local group = vim.api.nvim_create_augroup("crit-vim", { clear = true })

vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  callback = function() crit.register_socket() end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function() crit.unregister_socket() end,
})
vim.api.nvim_create_autocmd("DirChanged", {
  group = group,
  callback = function() crit.register_socket() end,
})

-- Highlight the current tab's file in the sidebar whenever the user
-- switches tabs.
vim.api.nvim_create_autocmd("TabEnter", {
  group = group,
  callback = function() crit._reposition_sidebar_cursor() end,
})


-- ---------- commands ----------
-- Ex commands are the canonical interface; pick whatever <leader> bindings
-- you like on top of them. They are safe from which-key/global collisions.

vim.api.nvim_create_user_command("CritComment", function(opts)
  if not crit.session then
    vim.notify("crit-vim: no active review", vim.log.levels.WARN)
    return
  end
  if opts.range == 2 then
    crit.comment_range({ opts.line1 }, { opts.line2 })
  else
    crit.comment_line(vim.api.nvim_win_get_cursor(0)[1])
  end
end, { range = true, desc = "crit-vim: comment on line / range" })

vim.api.nvim_create_user_command("CritEdit", function() crit.edit_at_cursor() end,
  { desc = "crit-vim: edit comment under cursor" })

vim.api.nvim_create_user_command("CritDelete", function() crit.delete_at_cursor() end,
  { desc = "crit-vim: delete comment under cursor" })

vim.api.nvim_create_user_command("CritReopen", function() crit.reopen() end,
  { desc = "crit-vim: rebuild diff tabs (after <C-w>o etc.)" })

vim.api.nvim_create_user_command("CritSidebar", function() crit.sidebar_toggle() end,
  { desc = "crit-vim: toggle file sidebar in current tab" })

vim.api.nvim_create_user_command("CritList", function() crit.list() end,
  { desc = "crit-vim: show comments in quickfix" })

vim.api.nvim_create_user_command("CritFinish", function() crit.finish() end,
  { desc = "crit-vim: submit review; the blocked agent unblocks with the JSON" })

vim.api.nvim_create_user_command("CritCancel", function() crit.cancel() end,
  { desc = "crit-vim: cancel review; agent exits with code 1" })

vim.api.nvim_create_user_command("CritReply", function() crit.reply_at_cursor() end,
  { desc = "crit-vim: reply to the comment under cursor" })

vim.api.nvim_create_user_command("CritEditReply", function() crit.edit_reply_at_cursor() end,
  { desc = "crit-vim: edit one of the replies on the comment under cursor" })

vim.api.nvim_create_user_command("CritDeleteReply", function() crit.delete_reply_at_cursor() end,
  { desc = "crit-vim: delete one of the replies on the comment under cursor" })

vim.api.nvim_create_user_command("CritResolve", function() crit.resolve_at_cursor() end,
  { desc = "crit-vim: mark the comment under cursor as resolved" })

vim.api.nvim_create_user_command("CritUnresolve", function() crit.unresolve_at_cursor() end,
  { desc = "crit-vim: mark the comment under cursor as unresolved" })

vim.api.nvim_create_user_command("CritToggleResolved", function() crit.toggle_show_resolved() end,
  { desc = "crit-vim: show or hide resolved comments" })

vim.api.nvim_create_user_command("CritVersion", function() crit.version() end,
  { desc = "crit-vim: show plugin + CLI + session versions" })

-- ---------- <Plug> mappings ----------
-- These are the plugin's public keymap API. Users bind them to whatever
-- keys they like (see README). <Plug> targets can't be typed directly so
-- they never collide with Comment.nvim, LSP codelens, or anything else.
-- Silent no-op outside an active review — safe to bind globally.

function _G.crit_vim_op(_motion_type)
  local s = vim.api.nvim_buf_get_mark(0, "[")
  local e = vim.api.nvim_buf_get_mark(0, "]")
  crit.comment_range(s, e)
end

vim.keymap.set("n", "<Plug>(CritComment)", function()
  vim.o.operatorfunc = "v:lua.crit_vim_op"
  return "g@"
end, { expr = true, desc = "crit-vim: comment on motion" })

vim.keymap.set("x", "<Plug>(CritComment)", function()
  vim.o.operatorfunc = "v:lua.crit_vim_op"
  return "g@"
end, { expr = true, desc = "crit-vim: comment on selection" })

vim.keymap.set("n", "<Plug>(CritCommentLine)", function()
  crit.comment_line(vim.api.nvim_win_get_cursor(0)[1])
end, { desc = "crit-vim: comment on current line" })

vim.keymap.set("n", "<Plug>(CritReply)", function()
  crit.reply_at_cursor()
end, { desc = "crit-vim: reply to comment under cursor" })

vim.keymap.set("n", "<Plug>(CritResolve)", function()
  crit.toggle_resolved_at_cursor()
end, { desc = "crit-vim: toggle resolved on comment under cursor" })
