-- Tests for the stack view in the files list, against the Lua stack fixture.

local h = require("test.helpers")
local repo = require("test.git_repo")
local state = require("gh_review.state")
local gh_review = require("gh_review")
local files = require("gh_review.files")
local view = require("gh_review.stack.view")
local config = require("gh_review.config")

config.setup({ turn = { watch = false } })
local dir = repo.stack_repo()
vim.cmd.cd(dir)

local function buf_lines()
  return vim.api.nvim_buf_get_lines(state.get_files_bufnr(), 0, -1, false)
end

local function line_matching(pattern)
  for i, text in ipairs(buf_lines()) do
    if text:find(pattern) then return i end
  end
  return nil
end

-- Type keys in the files list, through its mappings.
local function press(keys)
  vim.fn.win_gotoid(vim.fn.bufwinid(state.get_files_bufnr()))
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

local function cursor_on(pattern)
  local lnum = line_matching(pattern)
  if not lnum then error("no line matching " .. pattern, 2) end
  local winid = vim.fn.bufwinid(state.get_files_bufnr())
  vim.fn.win_gotoid(winid)
  vim.api.nvim_win_set_cursor(winid, { lnum, 0 })
  return lnum
end

gh_review.open("branch main")

h.run_test("s switches to the stack view, building in the background", function()
  h.assert_equal("files", files.mode())
  press("s")
  h.assert_equal("stack", files.mode())
  repo.wait_for(function() return view.result() ~= nil end, "the stack build")
  local lines = buf_lines()
  h.assert_match("^Branch", lines[1])
  h.assert_match("^Stacks: %d+ entr.*   %? help · s file list$", lines[2])
  h.assert_match("⚠", lines[3])
  h.assert_true(line_matching("^app%.entry%.start/1") ~= nil)
end)

h.run_test("<Tab> folds an entry group", function()
  local header = cursor_on("^app%.entry%.start/1")
  local winid = vim.fn.bufwinid(state.get_files_bufnr())
  h.assert_equal(-1, vim.fn.foldclosed(header))
  press("<Tab>")
  h.assert_equal(header, vim.fn.foldclosed(header))
  press("<Tab>")
  h.assert_equal(-1, vim.fn.foldclosed(header))
  h.assert_true(winid ~= -1)
end)

h.run_test("<Tab> on any frame folds just the frames below it", function()
  local leaf = cursor_on("^%s+~ app%.core%.leaf/1")
  local extra = line_matching("^%s+%+ app%.core%.extra/1")
  press("<Tab>")
  h.assert_equal(leaf, vim.fn.foldclosed(leaf))
  h.assert_equal(extra, vim.fn.foldclosedend(leaf), "leaf's fold ends with its last callee")
  local start = line_matching("^app%.entry%.start/1")
  h.assert_equal(-1, vim.fn.foldclosed(start), "the entry above stays open")
  press("<Tab>")
  h.assert_equal(-1, vim.fn.foldclosed(leaf))
end)

h.run_test("A folded frame shows ▸ and how many frames it hides", function()
  cursor_on("^%s+~ app%.core%.leaf/1")
  press("<Tab>")
  vim.cmd("redraw!")
  local win = vim.fn.bufwinid(state.get_files_bufnr())
  local row = vim.fn.win_screenpos(win)[1] + vim.fn.winline() - 1
  local function screen_text(width)
    local text = ""
    for col = 1, width do text = text .. vim.fn.screenstring(row, col) end
    return text
  end
  local text = screen_text(vim.api.nvim_win_get_width(win))
  h.assert_match("^▸", text, "closed marker in the fold column")
  h.assert_match("app%.core%.leaf/1", text, "the frame's own text")
  h.assert_match("··· 3 frames", text)
  press("<Tab>")
  vim.cmd("redraw!")
  h.assert_match("^▾", screen_text(2), "open marker once unfolded")
end)

h.run_test("The markers show even with a custom statuscolumn (LazyVim sets one)", function()
  local win = vim.fn.bufwinid(state.get_files_bufnr())
  vim.wo[win].statuscolumn = "%l "
  files.rerender()
  cursor_on("^%s+~ app%.core%.leaf/1")
  press("<Tab>")
  vim.cmd("redraw!")
  local row = vim.fn.win_screenpos(win)[1] + vim.fn.winline() - 1
  h.assert_equal("▸", vim.fn.screenstring(row, 1))
  h.assert_equal("", vim.wo[win].statuscolumn)
  press("<Tab>")
end)

h.run_test("Folds survive a redraw of the view", function()
  local leaf = cursor_on("^%s+~ app%.core%.leaf/1")
  press("<Tab>")
  files.rerender()
  h.assert_equal(leaf, vim.fn.foldclosed(leaf))
  press("<Tab>")
end)

h.run_test("zM folds every stack to its entry line, zr opens a level at a time", function()
  local start = cursor_on("^app%.entry%.start/1")
  local middle = line_matching("^%s+app%.core%.middle/1")
  local leaf = line_matching("^%s+~ app%.core%.leaf/1")
  press("zM")
  h.assert_equal(start, vim.fn.foldclosed(middle))
  press("zr")
  h.assert_equal(-1, vim.fn.foldclosed(start))
  h.assert_equal(middle, vim.fn.foldclosed(leaf), "one level open")
  press("zR")
  h.assert_equal(-1, vim.fn.foldclosed(leaf))
end)

h.run_test("<CR> on a frame opens its diff at the function", function()
  cursor_on("^%s+%+ app%.core%.fresh/1")
  press("<CR>")
  repo.wait_for(function()
    return state.get_diff_path() == "lua/app/core.lua" and state.get_left_bufnr() ~= -1
  end, "the diff")
  local right = vim.fn.bufwinid(state.get_right_bufnr())
  h.assert_equal(13, vim.api.nvim_win_get_cursor(right)[1], "fresh starts on line 13")
end)

h.run_test("Frame notes annotate the head pane", function()
  local marks = vim.api.nvim_buf_get_extmarks(state.get_right_bufnr(), view.ns, 0, -1, { details = true })
  local text = {}
  for _, m in ipairs(marks) do
    for _, chunk in ipairs(m[4].virt_text or {}) do text[#text + 1] = chunk[1] end
  end
  local joined = table.concat(text, " ")
  h.assert_match("⇢ async from tick", joined)
  h.assert_match("⚠ also entered from 1 other entry", joined)
end)

h.run_test("A see-above row jumps to the expanded frame", function()
  local ref = cursor_on("↪ app%.core%.fresh/1")
  press("<CR>")
  local now = vim.fn.line(".")
  h.assert_true(now ~= ref)
  h.assert_match("app%.core%.fresh/1", buf_lines()[now])
  h.assert_false(buf_lines()[now]:find("↪") ~= nil)
end)

h.run_test("]s steps through changed frames in stack order", function()
  local order = view.changed_order()
  h.assert_true(#order >= 4)
  vim.fn.win_gotoid(vim.fn.bufwinid(state.get_right_bufnr()))
  view.step(1)
  repo.wait_for(function() return state.get_left_bufnr() ~= -1 end, "the next frame")
  local right = vim.fn.bufwinid(state.get_right_bufnr())
  local line = vim.api.nvim_win_get_cursor(right)[1]
  local found = false
  for _, node in ipairs(order) do
    if node.path == state.get_diff_path() and node.jump_line == line then found = true end
  end
  h.assert_true(found, "landed on a changed frame")
end)

h.run_test("Only the latest of two quick opens is shown", function()
  local diff = require("gh_review.diff")
  diff.open("lua/app/core.lua", { line = 3 })
  diff.open("lua/app/entry.lua", { line = 4 })
  repo.wait_for(function()
    return state.get_left_bufnr() ~= -1 and vim.api.nvim_buf_get_name(state.get_right_bufnr()):find("entry%.lua$") ~= nil
  end, "the second diff")
  vim.wait(200)
  local right = vim.fn.bufwinid(state.get_right_bufnr())
  h.assert_match("entry%.lua$", vim.api.nvim_buf_get_name(state.get_right_bufnr()))
  h.assert_equal(4, vim.api.nvim_win_get_cursor(right)[1])
end)

h.run_test("P moves the list to the left; diffs open to its right", function()
  cursor_on("app%.core%.leaf/1")
  press("P")
  h.assert_equal("left", config.options.files_position)
  local list = vim.fn.bufwinid(state.get_files_bufnr())
  h.assert_equal(1, vim.fn.win_screenpos(list)[2], "list in the first column")
  h.assert_equal("stack", files.mode(), "mode kept")
  h.assert_match("app%.core%.leaf/1", vim.api.nvim_get_current_line(), "cursor kept")
  press("<CR>")
  repo.wait_for(function() return state.get_left_bufnr() ~= -1 end, "the diff")
  local right = vim.fn.bufwinid(state.get_right_bufnr())
  h.assert_true(vim.fn.win_screenpos(right)[2] > vim.api.nvim_win_get_width(list))
  press("P")
  h.assert_equal("bottom", config.options.files_position)
end)

h.run_test("<CR> on an unchanged function in an unchanged file opens the file itself", function()
  cursor_on("^app%.entry%.start/1")
  press("<CR>")
  local name = vim.api.nvim_buf_get_name(0)
  h.assert_match("lua/app/entry%.lua$", name)
  h.assert_false(vim.wo.diff, "a plain window, not a diff")
  h.assert_equal(3, vim.api.nvim_win_get_cursor(0)[1])
  h.assert_equal(-1, state.get_left_bufnr(), "no diff left open")
end)

h.run_test("<CR> on a removed function shows it on the base side", function()
  cursor_on("%- app%.core%.old/1")
  press("<CR>")
  repo.wait_for(function() return state.get_left_bufnr() ~= -1 end, "the diff")
  h.assert_equal(state.get_left_bufnr(), vim.api.nvim_get_current_buf(), "cursor in the base pane")
  h.assert_equal(8, vim.api.nvim_win_get_cursor(0)[1])
  h.assert_equal("function M.old(x)", vim.api.nvim_get_current_line())
end)

h.run_test("After a plain file, a changed frame still opens as a diff", function()
  cursor_on("^app%.entry%.start/1")
  press("<CR>")
  cursor_on("^%s+%+ app%.core%.fresh/1")
  press("<CR>")
  repo.wait_for(function() return state.get_left_bufnr() ~= -1 end, "the diff")
  h.assert_equal("lua/app/core.lua", state.get_diff_path())
  h.assert_true(vim.wo[vim.fn.bufwinid(state.get_right_bufnr())].diff)
end)

-- Open core.lua's diff with the cursor on `line` of the given side.
local function diff_at(line, side)
  local diff = require("gh_review.diff")
  diff.open("lua/app/core.lua", { line = line, side = side })
  repo.wait_for(function()
    return state.get_left_bufnr() ~= -1 and state.get_diff_path() == "lua/app/core.lua"
  end, "the diff")
  vim.wait(100)
  local win = vim.fn.bufwinid(side == "LEFT" and state.get_left_bufnr() or state.get_right_bufnr())
  vim.fn.win_gotoid(win)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
end

local function in_files_list_on(pattern)
  h.assert_equal(state.get_files_bufnr(), vim.api.nvim_get_current_buf(), "focus moved to the list")
  local text = vim.api.nvim_get_current_line()
  h.assert_match(pattern, text)
  h.assert_false(text:find("↪", 1, true) ~= nil, "the expanded row, not a reference")
end

h.run_test("gS in the diff jumps to the function's row in the stack view", function()
  diff_at(14, "RIGHT")
  vim.api.nvim_feedkeys("gS", "mx", false)
  in_files_list_on("^%s+%+ app%.core%.fresh/1")
end)

h.run_test("gS unfolds whatever hides the row", function()
  vim.cmd("normal! zM")
  diff_at(14, "RIGHT")
  vim.api.nvim_feedkeys("gS", "mx", false)
  in_files_list_on("app%.core%.fresh/1")
  h.assert_equal(-1, vim.fn.foldclosed("."))
  vim.cmd("normal! zR")
end)

h.run_test("gS on a removed function's base lines finds it under Removed", function()
  diff_at(8, "LEFT")
  vim.api.nvim_feedkeys("gS", "mx", false)
  in_files_list_on("%- app%.core%.old/1")
end)

h.run_test("gS between functions stays put and says so", function()
  diff_at(2, "RIGHT")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_feedkeys("gS", "mx", false)
  h.assert_equal(win, vim.api.nvim_get_current_win())
end)

h.run_test("gS before the stack view exists builds it, then jumps", function()
  files.toggle_stack()
  h.assert_equal("files", files.mode())
  view.invalidate()
  diff_at(14, "RIGHT")
  vim.api.nvim_feedkeys("gS", "mx", false)
  repo.wait_for(function() return view.result() ~= nil end, "the build")
  repo.wait_for(function() return vim.api.nvim_get_current_buf() == state.get_files_bufnr() end, "the jump")
  h.assert_equal("stack", files.mode())
  in_files_list_on("^%s+%+ app%.core%.fresh/1")
end)

h.run_test("s goes back to the file list with three header lines", function()
  press("s")
  h.assert_equal("files", files.mode())
  local lines = buf_lines()
  h.assert_match("^Files changed", lines[2])
  h.assert_match("app/core%.lua", table.concat(lines, "\n"))
end)

h.run_test("Without a checkout the stack view says why", function()
  gh_review.close()
  state.set_local_checkout(false)
  state.set_merge_base_oid("abc")
  local lines = view.render()
  h.assert_match("needs the head checked out", lines[2])
end)

h.write_results("/tmp/gh_review_test_stack_view.txt")
