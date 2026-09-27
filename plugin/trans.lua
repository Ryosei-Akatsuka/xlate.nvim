-- trans-nvim entry point.
--
-- This file only registers commands and the default highlight; all logic
-- lives under lua/trans/ and is loaded lazily on first use.

if vim.g.loaded_trans_nvim then
  return
end
vim.g.loaded_trans_nvim = 1

local function set_default_highlight()
  vim.api.nvim_set_hl(0, "TransTranslated", { default = true, link = "Comment" })
end

set_default_highlight()

local group = vim.api.nvim_create_augroup("trans-nvim-highlight", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = set_default_highlight,
})

vim.api.nvim_create_user_command("Trans", function()
  require("trans").translate()
end, {
  desc = "Translate the buffer and show results as virtual lines",
})

vim.api.nvim_create_user_command("TransClear", function()
  require("trans").clear()
end, {
  desc = "Remove translation virtual lines from the buffer",
})

vim.api.nvim_create_user_command("TransToggle", function()
  require("trans").toggle()
end, {
  desc = "Toggle translation virtual lines",
})
