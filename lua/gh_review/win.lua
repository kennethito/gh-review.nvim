-- Window helpers shared by the files list, diff, and thread buffers.

local M = {}

-- Close the current window, or empty it when it is the last one.
--
-- `:close` raises E444 on the last window. An error there aborts whatever
-- teardown was running: for `M.close()` that means never reaching the buffer
-- wipe or `state.reset()`, leaving the plugin half-open with the files list
-- still on screen. Sitting in a review with the files list as the only window
-- is an ordinary thing to do, so this is reachable in normal use.
--
-- Emptying the window keeps teardown going, and keeps `q` in a review buffer
-- from being a way to quit Neovim. Whichever review buffer the window held is
-- then undisplayed, so the caller can wipe it.
function M.close_current()
  if not pcall(vim.cmd, "close") then
    vim.cmd("enew")
  end
end

-- Turn folding off in a window that shows the plugin's own text (help, thread
-- preview, comment buffer). A new window inherits folding from the one it
-- opened from: a code window's indent or expr folding (LazyVim sets indent
-- folding globally) would fold every indented line away. Switching to manual
-- keeps the folds already made, so they are deleted as well.
function M.no_folds(winid)
  vim.wo[winid].foldmethod = "manual"
  vim.api.nvim_win_call(winid, function() vim.cmd("silent! normal! zE") end)
  vim.wo[winid].foldenable = false
end

return M
