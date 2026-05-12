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

-- ---------- commands ----------
-- Ex commands are the canonical interface; pick whatever <leader> bindings
-- you like on top of them. They are safe from which-key/global collisions.

vim.api.nvim_create_user_command("CritComment", function(opts)
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

vim.api.nvim_create_user_command("CritFiles", function() crit.files_picker() end,
  { desc = "crit-vim: list review files (Enter to jump)" })

vim.api.nvim_create_user_command("CritReopen", function() crit.reopen() end,
  { desc = "crit-vim: rebuild diff tabs (after <C-w>o etc.)" })

vim.api.nvim_create_user_command("CritList", function() crit.list() end,
  { desc = "crit-vim: show comments in quickfix" })

vim.api.nvim_create_user_command("CritFinish", function() crit.finish() end,
  { desc = "crit-vim: submit review; the blocked agent unblocks with the JSON" })

vim.api.nvim_create_user_command("CritCancel", function() crit.cancel() end,
  { desc = "crit-vim: cancel review; agent exits with code 1" })

-- ---------- keymaps ----------
-- Only two global bindings: the operator and 'comment current line'. Both
-- live under <leader>c but don't collide with LazyVim's <leader>c{letter}
-- bindings because we only consume <leader>cc and <leader>c<motion>.

function _G.crit_vim_op(_motion_type)
  local s = vim.api.nvim_buf_get_mark(0, "[")
  local e = vim.api.nvim_buf_get_mark(0, "]")
  crit.comment_range(s, e)
end

vim.keymap.set("n", "<leader>c", function()
  vim.o.operatorfunc = "v:lua.crit_vim_op"
  return "g@"
end, { expr = true, desc = "crit-vim: comment on motion" })

vim.keymap.set("x", "<leader>c", function()
  vim.o.operatorfunc = "v:lua.crit_vim_op"
  return "g@"
end, { expr = true, desc = "crit-vim: comment on selection" })

vim.keymap.set("n", "<leader>cc", function()
  crit.comment_line(vim.api.nvim_win_get_cursor(0)[1])
end, { desc = "crit-vim: comment on current line" })
