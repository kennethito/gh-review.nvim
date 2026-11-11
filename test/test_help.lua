-- Tests for the `?` help in the files list.

local h = require("test.helpers")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")
local config = require("gh_review.config")
local files = require("gh_review.files")
local help = require("gh_review.help")

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

local function help_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

config.setup({ keymaps = { files = { toggle_stack = "X" }, diff = { preview = false } } })
state.reset()
state.set_repo_info("testowner", "testrepo", "github.com", "origin")
state.set_pr(fixtures.mock_pr_data())
files.open()

h.run_test("The files list header points at the help, with the configured keys", function()
  local header = vim.api.nvim_buf_get_lines(state.get_files_bufnr(), 1, 2, false)[1]
  h.assert_match("^Files changed %(3%)   %? help · X stack view$", header)
end)

h.run_test("? in the files list opens the help in a float", function()
  vim.fn.win_gotoid(vim.fn.bufwinid(state.get_files_bufnr()))
  press("?")
  h.assert_true(help.is_open())
  h.assert_true(vim.api.nvim_win_get_config(0).relative ~= "", "a floating window")
end)

h.run_test("Help lists each surface's configured keys", function()
  local text = help_text()
  h.assert_match("Files list", text)
  h.assert_match("\n  X%s+Toggle stack view", text, "remapped key shown")
  h.assert_match("\n  %?%s+Show keys and commands", text)
  h.assert_match("Diff\n", text)
  h.assert_match("New comment %(also visual%)", text)
  h.assert_false(text:find("Preview thread", 1, true) ~= nil, "a disabled key is left out")
  h.assert_match("Comment buffer", text)
end)

h.run_test("Help lists the commands with their descriptions", function()
  local text = help_text()
  for _, name in ipairs({ "GHReview", "GHReviewScope", "GHReviewSend", "GHReviewCopy", "GHReviewTurn",
    "GHReviewFiles", "GHReviewStart", "GHReviewSubmit", "GHReviewDiscard", "GHReviewClose" }) do
    h.assert_match(":" .. name .. "%s", text, name)
  end
  h.assert_match(":GHReviewSend%s+Send comments to a running coding agent", text)
end)

h.run_test("q closes the help and returns to the files list", function()
  press("q")
  h.assert_false(help.is_open())
  h.assert_equal(state.get_files_bufnr(), vim.api.nvim_get_current_buf())
end)

h.run_test("? toggles the help", function()
  press("?")
  h.assert_true(help.is_open())
  press("?")
  h.assert_false(help.is_open())
end)

h.run_test("The diff and comment buffer map g? to the help", function()
  local text = table.concat(help.lines(), "\n")
  local diff_section = text:match("\nDiff\n(.-)\n\n")
  local thread_section = text:match("\nComment buffer\n(.-)\n\n")
  h.assert_match("g%?%s+Show keys and commands", diff_section)
  h.assert_match("g%?%s+Show keys and commands", thread_section)
  h.assert_match(":GHReviewHelp%s+Show every key and command", text)
end)

h.run_test(":GHReviewHelp opens the help and q returns to the window it came from", function()
  local from = vim.api.nvim_get_current_win()
  vim.cmd("GHReviewHelp")
  h.assert_true(help.is_open())
  press("q")
  h.assert_false(help.is_open())
  h.assert_equal(from, vim.api.nvim_get_current_win())
end)

h.run_test("Help opened from a folding window shows every line", function()
  vim.cmd("new")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "  b", "  c" })
  -- Like LazyVim: indent folding set globally, here with every fold closed.
  vim.o.foldmethod = "indent"
  vim.o.foldlevel = 0
  vim.o.foldenable = true
  vim.o.shiftwidth = 2  -- indent folds count shiftwidths; the entries are indented 2
  help.open()
  -- Headless Neovim computes folds lazily: recompute them now.
  vim.cmd("silent! normal! zx")
  local count = vim.api.nvim_buf_line_count(0)
  local folded = 0
  for lnum = 1, count do
    if vim.fn.foldclosed(lnum) ~= -1 then folded = folded + 1 end
  end
  h.assert_equal(0, folded, "no folded lines")
  h.assert_true(count > 20, "every entry listed")
  help.close()
  vim.cmd("bwipeout!")
  vim.o.foldmethod, vim.o.foldlevel, vim.o.shiftwidth = "manual", 0, 8
end)

h.run_test("The comment buffer opened from a folding window shows every line", function()
  vim.o.foldmethod, vim.o.foldlevel, vim.o.foldenable, vim.o.shiftwidth = "indent", 0, true, 2
  require("gh_review.thread").open_new("src/new_file.ts", 1, 3, "RIGHT", "  indented\n    more")
  vim.cmd("silent! normal! zx")
  local folded = 0
  for lnum = 1, vim.api.nvim_buf_line_count(0) do
    if vim.fn.foldclosed(lnum) ~= -1 then folded = folded + 1 end
  end
  h.assert_equal(0, folded)
  require("gh_review.thread").close_thread_buffer()
  vim.o.foldmethod, vim.o.foldlevel, vim.o.shiftwidth = "manual", 0, 8
end)

h.write_results("/tmp/gh_review_test_help.txt")
