-- plugin/*.lua is sourced once at startup by nvim; it doesn't re-run on
-- :Lazy reload. Keep this file minimal — do the actual registration in
-- lua/crit-vim/init.lua so `:Lazy reload crit-vim` picks up added commands.
if vim.g.loaded_crit_vim then return end
vim.g.loaded_crit_vim = 1

require("crit-vim")._register()
