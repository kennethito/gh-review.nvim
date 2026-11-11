-- Tests for the unified diff view.

local h = require("test.helpers")
local repo = require("test.git_repo")
local state = require("gh_review.state")
local config = require("gh_review.config")
local unified = require("gh_review.unified")
local gh_review = require("gh_review")
local diff = require("gh_review.diff")
local local_store = require("gh_review.local_store")

-- ------- Line mapping -------

local BASE = { "a", "b", "c", "d", "e", "f" }
-- c changed to C, e removed, g inserted after f.
local HEAD = { "a", "b", "C", "d", "f", "g" }
local hunks = unified.hunks(BASE, HEAD)

h.run_test("Hunks: a change, a removal, an insertion", function()
  h.assert_equal(3, #hunks)
  h.assert_equal(vim.inspect({ 3, 1, 3, 1 }), vim.inspect(hunks[1]))
  h.assert_equal(vim.inspect({ 5, 1, 4, 0 }), vim.inspect(hunks[2]))
  h.assert_equal(vim.inspect({ 6, 0, 6, 1 }), vim.inspect(hunks[3]))
end)

h.run_test("Base lines map to where they show in the head", function()
  h.assert_equal(2, unified.base_to_head(2, hunks, #HEAD), "unchanged before the change")
  h.assert_equal(3, unified.base_to_head(3, hunks, #HEAD), "changed line: its replacement")
  h.assert_equal(4, unified.base_to_head(4, hunks, #HEAD))
  h.assert_equal(5, unified.base_to_head(5, hunks, #HEAD), "removed e hangs above f")
  h.assert_equal(5, unified.base_to_head(6, hunks, #HEAD), "f after the removal")
end)

h.run_test("A removed block is found from the line it hangs above", function()
  h.assert_equal(vim.inspect({ 5, 5 }), vim.inspect(unified.removed_above(5, hunks, #HEAD)))
  h.assert_equal(vim.inspect({ 3, 3 }), vim.inspect(unified.removed_above(3, hunks, #HEAD)))
  h.assert_equal(nil, unified.removed_above(4, hunks, #HEAD))
end)

h.run_test("Unchanged stretches fold, keeping context around each change", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, 30 do lines[i] = "line " .. i end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)
  unified.fold({ { 15, 1, 15, 1 } }, 30, 0)
  h.assert_equal(1, vim.fn.foldclosed(5))
  h.assert_equal(-1, vim.fn.foldclosed(12), "three lines of context")
  h.assert_equal(-1, vim.fn.foldclosed(15))
  h.assert_equal(-1, vim.fn.foldclosed(18))
  h.assert_equal(19, vim.fn.foldclosed(25))
  vim.cmd("tabclose")
end)

-- ------- Changed parts of a line -------

local function changed_ranges(base_line, head_line, mode)
  unified.inline = mode
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { head_line })
  unified.render(buf, { base_line })
  local ranges = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, unified.ns, 0, -1, { details = true })) do
    if m[4].hl_group == "DiffText" then ranges[#ranges + 1] = head_line:sub(m[3] + 1, m[4].end_col) end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  unified.inline = "word"
  return ranges
end

h.run_test("Word mode marks whole changed words", function()
  local ranges = changed_ranges("local count = total + 1", "local amount = total + 2", "word")
  h.assert_equal("amount|2", table.concat(ranges, "|"))
end)

h.run_test("Char mode marks only the changed characters", function()
  local ranges = changed_ranges("local count = 1", "local mount = 1", "char")
  h.assert_equal("m", table.concat(ranges, "|"))
end)

h.run_test("A line emptied or filled in renders without errors", function()
  for _, mode in ipairs({ "word", "char" }) do
    h.assert_equal("local x = 1", table.concat(changed_ranges("", "local x = 1", mode)), mode .. ": filled in, all new")
    h.assert_equal(0, #changed_ranges("local x = 1", "", mode), mode .. ": emptied")
  end
end)

h.run_test("Off marks no part of the line", function()
  h.assert_equal(0, #changed_ranges("local count = 1", "local mount = 1", "off"))
end)

-- ------- The view on a real repo -------

config.setup({ turn = { watch = false }, diff_view = "unified" })
vim.o.diffopt = "internal,filler,closeoff,inline:char"
local user_diffopt = vim.o.diffopt
local dir = repo.feature_repo()
vim.cmd.cd(dir)
gh_review.open("branch main")

local function wait_unified()
  repo.wait_for(function()
    local rbuf = state.get_right_bufnr()
    return rbuf ~= -1 and vim.b[rbuf].gh_review_unified_hunks ~= nil
  end, "the unified view")
end

local function marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, unified.ns, 0, -1, { details = true })
end

h.run_test("Unified: one window on the real head file, nothing in diff mode", function()
  diff.open("a.txt")
  wait_unified()
  local right = state.get_right_bufnr()
  h.assert_equal(dir .. "/a.txt", vim.api.nvim_buf_get_name(right))
  h.assert_equal("", vim.bo[right].buftype, "the real file, so LSP and gd work")
  h.assert_equal(-1, vim.fn.bufwinid(state.get_left_bufnr()), "the base buffer is not shown")
  h.assert_false(vim.wo[vim.fn.bufwinid(right)].diff)
  h.assert_match("unified", vim.wo[vim.fn.bufwinid(right)].winbar)
end)

h.run_test("Unified: added lines are highlighted and removed lines drawn above them", function()
  local right = state.get_right_bufnr()
  local added, removed, changed_chars = {}, {}, 0
  for _, m in ipairs(marks(right)) do
    local d = m[4]
    if d.line_hl_group == "DiffAdd" then added[#added + 1] = m[2] + 1 end
    if d.hl_group == "DiffText" then changed_chars = changed_chars + 1 end
    if d.virt_lines then
      for _, vl in ipairs(d.virt_lines) do
        local text = ""
        for _, chunk in ipairs(vl) do text = text .. chunk[1] end
        removed[#removed + 1] = { m[2] + 1, text }
      end
    end
  end
  table.sort(added)
  h.assert_equal("2,4", table.concat(added, ","), "TWO and FOUR")
  h.assert_equal(2, #removed)
  h.assert_equal("two", removed[1][2])
  h.assert_equal(2, removed[1][1], "above TWO")
  h.assert_true(changed_chars >= 2, "changed characters marked")
end)

h.run_test("Unified: the head window keeps its own folds, not diff folding", function()
  local win = vim.fn.bufwinid(state.get_right_bufnr())
  h.assert_equal("manual", vim.wo[win].foldmethod)
  -- What set off the fold guard: something setting foldmethod on the buffer.
  vim.api.nvim_win_call(win, function() vim.cmd("setlocal foldmethod=manual") end)
  h.assert_equal("manual", vim.wo[win].foldmethod, "the guard leaves a unified window alone")
end)

h.run_test("Unified: the cursor line on an added line has its own colour", function()
  -- tokyonight-moon, where DiffAdd and CursorLine are nearly the same shade.
  vim.api.nvim_set_hl(0, "Normal", { fg = 0xc8d3f5, bg = 0x222436 })
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x2a4556 })
  vim.api.nvim_set_hl(0, "GHReviewUnifiedCursorLine", {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  local hl = vim.api.nvim_get_hl(0, { name = "GHReviewUnifiedCursorLine", link = false })
  h.assert_equal(0x4a6176, hl.bg, "DiffAdd lifted a fifth towards the text colour")

  local right = state.get_right_bufnr()
  local win = vim.fn.bufwinid(right)
  vim.fn.win_gotoid(win)
  vim.wo[win].cursorline = true
  local function cursor_marks()
    local found = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(right, unified.cursor_ns, 0, -1, { details = true })) do
      found[#found + 1] = (m[2] + 1) .. ":" .. tostring(m[4].line_hl_group)
    end
    return table.concat(found, ",")
  end
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = right })
  h.assert_equal("2:GHReviewUnifiedCursorLine", cursor_marks(), "on an added line")
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = right })
  h.assert_equal("", cursor_marks(), "the normal cursor line elsewhere")
end)

h.run_test("A user's own GHReviewUnifiedCursorLine survives a colour scheme change", function()
  vim.api.nvim_set_hl(0, "GHReviewUnifiedCursorLine", { bg = 0x123456 })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  h.assert_equal(0x123456, vim.api.nvim_get_hl(0, { name = "GHReviewUnifiedCursorLine" }).bg)
  vim.api.nvim_set_hl(0, "GHReviewUnifiedCursorLine", {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
end)

h.run_test("Unified: ]c and [c jump between changes", function()
  local win = vim.fn.bufwinid(state.get_right_bufnr())
  vim.fn.win_gotoid(win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.api.nvim_feedkeys("]c", "mx", false)
  h.assert_equal(2, vim.fn.line("."))
  vim.api.nvim_feedkeys("]c", "mx", false)
  h.assert_equal(4, vim.fn.line("."))
  vim.api.nvim_feedkeys("[c", "mx", false)
  h.assert_equal(2, vim.fn.line("."))
end)

h.run_test("Unified: gc above removed lines can comment on the base side", function()
  local original = vim.ui.select
  vim.ui.select = function(items, _, cb) cb(items[2], 2) end
  local win = vim.fn.bufwinid(state.get_right_bufnr())
  vim.fn.win_gotoid(win)
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  vim.api.nvim_feedkeys("gc", "mx", false)
  vim.ui.select = original

  local tbuf = state.get_thread_bufnr()
  h.assert_equal("LEFT", vim.b[tbuf].gh_review_side)
  local reply_start = vim.b[tbuf].gh_review_reply_start
  vim.api.nvim_buf_set_lines(tbuf, reply_start - 1, -1, false, { "Why drop lowercase?" })
  vim.api.nvim_buf_call(tbuf, function() vim.cmd("write") end)

  local t = local_store.unsent()[1]
  h.assert_equal("LEFT", t.diffSide)
  h.assert_equal(2, t.line)
  h.assert_equal("two", t.anchor[1], "quoted from the base")
end)

h.run_test("Unified: a base-side thread shows on the head line it maps to", function()
  local right = state.get_right_bufnr()
  local found = false
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(right, state.ns, 0, -1, { details = true })) do
    for _, chunk in ipairs(m[4].virt_text or {}) do
      if chunk[1]:find("^%(base%) you: Why drop lowercase") and m[2] + 1 == 2 then found = true end
    end
  end
  h.assert_true(found)
end)

h.run_test("gu switches to side by side and back, keeping the line", function()
  local win = vim.fn.bufwinid(state.get_right_bufnr())
  vim.fn.win_gotoid(win)
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  vim.api.nvim_feedkeys("gu", "mx", false)
  repo.wait_for(function() return vim.fn.bufwinid(state.get_left_bufnr()) ~= -1 end, "the split view")
  local right = state.get_right_bufnr()
  h.assert_equal("split", diff.view_mode())
  h.assert_true(vim.wo[vim.fn.bufwinid(right)].diff)
  h.assert_equal(0, #marks(right), "unified drawing cleared")
  h.assert_equal(4, vim.api.nvim_win_get_cursor(vim.fn.bufwinid(right))[1])
  h.assert_match("inline:word", vim.o.diffopt, "side by side marks words")
  h.assert_false(vim.o.diffopt:find("inline:char") ~= nil)

  vim.fn.win_gotoid(vim.fn.bufwinid(right))
  vim.api.nvim_feedkeys("gu", "mx", false)
  wait_unified()
  h.assert_equal("unified", diff.view_mode())
  h.assert_equal(-1, vim.fn.bufwinid(state.get_left_bufnr()))
  h.assert_equal(4, vim.api.nvim_win_get_cursor(vim.fn.bufwinid(state.get_right_bufnr()))[1])
end)

h.run_test("Closing the diff clears the drawing and wipes the hidden base buffer", function()
  local right, left = state.get_right_bufnr(), state.get_left_bufnr()
  diff.close_diff()
  h.assert_equal(0, #marks(right))
  h.assert_equal(0, vim.fn.bufexists(left))
  h.assert_equal(user_diffopt, vim.o.diffopt, "the user's diffopt is back")
end)

h.write_results("/tmp/gh_review_test_unified.txt")
