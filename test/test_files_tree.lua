-- Tests for the files list's folder tree layout.

local h = require("test.helpers")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")
local config = require("gh_review.config")
local files = require("gh_review.files")

local PATHS = {
  { "README.md", 3, 1 },
  { "lua/gh_review/stack/view.lua", 10, 2 },
  { "lua/gh_review/stack/build.lua", 5, 5 },
  { "lua/gh_review/files.lua", 7, 0 },
  { "test/a/b.lua", 1, 1 },
  { "zeta.txt", 2, 2 },
}

local function load(paths)
  local data = fixtures.mock_pr_data()
  local nodes = {}
  for _, p in ipairs(paths) do
    nodes[#nodes + 1] = { path = p[1], additions = p[2], deletions = p[3], changeType = "MODIFIED" }
  end
  data.data.repository.pullRequest.files.nodes = nodes
  state.reset()
  state.set_pr(data)
  state.set_threads({})
  state.set_repo_info("test-owner", "test-repo")
end

local function open_tree()
  config.options.files_view = "tree"
  files.open()
  return state.get_files_bufnr()
end

local function finish()
  files.close()
  config.options.files_view = "flat"
end

local function lines_of(bufnr) return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end

local function row_matching(bufnr, pat)
  for i, l in ipairs(lines_of(bufnr)) do
    if l:find(pat) then return i end
  end
  error("no row matching " .. pat)
end

local function key(bufnr, lhs)
  vim.fn.win_gotoid(vim.fn.bufwinid(bufnr))
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if (m.lhs == lhs or (lhs == "<Space>" and m.lhs == " ")) and m.callback then return m.callback() end
  end
  error("no mapping " .. lhs)
end

h.run_test("Tree: build_tree sorts folders before files and collapses chains", function()
  load(PATHS)
  local rows = files.build_tree(state.get_changed_files())
  local got = {}
  for _, r in ipairs(rows) do got[#got + 1] = r.depth .. ":" .. r.kind .. ":" .. r.name end
  h.assert_equal(table.concat({
    "0:dir:lua/gh_review", "1:dir:stack", "2:file:build.lua", "2:file:view.lua", "1:file:files.lua",
    "0:dir:test/a", "1:file:b.lua", "0:file:README.md", "0:file:zeta.txt",
  }, ","), table.concat(got, ","))
  h.assert_equal("lua/gh_review", rows[1].path)
  h.assert_equal("lua/gh_review/stack", rows[2].path)
end)

h.run_test("Tree: folder rows sum files and +/-", function()
  load(PATHS)
  local rows = files.build_tree(state.get_changed_files())
  h.assert_equal(3, rows[1].count)
  h.assert_equal(22, rows[1].additions)
  h.assert_equal(7, rows[1].deletions)
  h.assert_equal(2, rows[2].count)
  h.assert_equal(15, rows[2].additions)
end)

h.run_test("Tree: buffer rows, headers and indentation", function()
  load(PATHS)
  local bufnr = open_tree()
  local lines = lines_of(bufnr)
  h.assert_match("Files changed %(6%)", lines[2])
  h.assert_match("^%[ %] %+22   %-7 +lua/gh_review/  %(3 files%)", lines[4])
  h.assert_match("^%[ %] %+15   %-7 +  stack/  %(2 files%)", lines[5])
  h.assert_match("^%[ %] %+5    %-5    M      build%.lua", lines[6])
  h.assert_match("M  README%.md$", lines[#lines - 1])
  finish()
end)

h.run_test("Tree: T toggles layout and back, <Tab> map exists", function()
  load(PATHS)
  config.options.files_view = "flat"
  files.open()
  local bufnr = state.get_files_bufnr()
  h.assert_match("lua/gh_review/stack/view%.lua", lines_of(bufnr)[5] .. lines_of(bufnr)[4] .. lines_of(bufnr)[6])
  key(bufnr, "T")
  h.assert_equal("tree", config.options.files_view)
  h.assert_equal("tree", files.view())
  row_matching(bufnr, "lua/gh_review/  %(3 files%)")
  key(bufnr, "T")
  h.assert_equal("flat", config.options.files_view)
  h.assert_match("lua/gh_review/stack/view%.lua", lines_of(bufnr)[5])
  finish()
end)

h.run_test("Tree: layout survives a trip through the stack view", function()
  load(PATHS)
  local bufnr = open_tree()
  files.toggle_stack()
  h.assert_equal("stack", files.mode())
  files.toggle_stack()
  h.assert_equal("files", files.mode())
  h.assert_equal("tree", config.options.files_view)
  row_matching(bufnr, "lua/gh_review/  %(3 files%)")
  finish()
end)

h.run_test("Tree: <CR> on a file row opens that file", function()
  load(PATHS)
  local bufnr = open_tree()
  local diff = require("gh_review.diff")
  local opened
  local original = diff.open
  diff.open = function(path) opened = path end
  vim.api.nvim_win_set_cursor(vim.fn.bufwinid(bufnr), { row_matching(bufnr, "view%.lua"), 0 })
  key(bufnr, "<CR>")
  diff.open = original
  h.assert_equal("lua/gh_review/stack/view.lua", opened)
  finish()
end)

h.run_test("Tree: <Space> on a folder marks every file under it, then unmarks", function()
  load(PATHS)
  local bufnr = open_tree()
  local api = require("gh_review.api")
  local original = api.graphql
  local sent = {}
  api.graphql = function(_, vars, cb)
    sent[#sent + 1] = vars.path
    cb({ data = { markFileAsViewed = { pullRequest = { id = "x" } }, unmarkFileAsViewed = { pullRequest = { id = "x" } } } })
  end
  state.set_file_checked("lua/gh_review/files.lua", true)
  vim.api.nvim_win_set_cursor(vim.fn.bufwinid(bufnr), { row_matching(bufnr, "lua/gh_review/  %(3"), 0 })
  key(bufnr, "<Space>")
  h.assert_true(state.is_file_checked("lua/gh_review/stack/view.lua"))
  h.assert_true(state.is_file_checked("lua/gh_review/stack/build.lua"))
  h.assert_true(state.is_file_checked("lua/gh_review/files.lua"))
  h.assert_false(state.is_file_checked("README.md"))
  h.assert_equal(2, #sent, "only the unviewed files are sent")
  h.assert_match("^%[x%]", lines_of(bufnr)[row_matching(bufnr, "lua/gh_review/  %(3")])
  sent = {}
  vim.api.nvim_win_set_cursor(vim.fn.bufwinid(bufnr), { row_matching(bufnr, "lua/gh_review/  %(3"), 0 })
  key(bufnr, "<Space>")
  api.graphql = original
  h.assert_equal(3, #sent)
  h.assert_false(state.is_file_checked("lua/gh_review/stack/view.lua"))
  h.assert_false(state.is_file_checked("lua/gh_review/files.lua"))
  finish()
end)

h.run_test("Tree: <Tab> and <CR> fold a folder; folds survive a re-render", function()
  load(PATHS)
  local bufnr = open_tree()
  local win = vim.fn.bufwinid(bufnr)
  local stack = row_matching(bufnr, "  stack/")
  h.assert_equal(-1, vim.fn.foldclosed(stack), "starts open")
  vim.api.nvim_win_set_cursor(win, { stack, 0 })
  key(bufnr, "<Tab>")
  h.assert_equal(stack, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(stack) end))
  files.rerender()
  h.assert_equal(stack, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(stack) end), "kept")
  h.assert_equal(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(row_matching(bufnr, "files%.lua")) end))
  -- Closed folder text is its own row, without a frame count.
  local text = vim.api.nvim_win_call(win, function() return vim.fn.foldtextresult(stack) end)
  h.assert_match("stack/", text)
  h.assert_false(text:find("frame"))
  vim.api.nvim_win_set_cursor(win, { stack, 0 })
  key(bufnr, "<CR>")
  h.assert_equal(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(stack) end), "<CR> reopens")
  finish()
end)

h.run_test("Tree: fold_levels from item depths", function()
  local items = {
    [4] = { kind = "dir", depth = 0 }, [5] = { kind = "file", depth = 1 }, [6] = { kind = "file", depth = 0 },
  }
  local levels = files.fold_levels(items, 6)
  h.assert_equal(">1", levels[4])
  h.assert_equal("1", levels[5])
  h.assert_equal("0", levels[6])
  h.assert_equal("0", levels[1])
end)

h.run_test("Tree: files_view validated in setup", function()
  local saved = vim.deepcopy(config.options)
  config.setup({ files_view = "tree" })
  h.assert_equal("tree", config.options.files_view)
  local notified = {}
  local orig = vim.notify
  vim.notify = function(msg) notified[#notified + 1] = msg end
  config.setup({ files_view = "grid" })
  vim.notify = orig
  h.assert_true(#notified > 0, "warned")
  config.options = saved
end)

h.write_results("/tmp/gh_review_test_files_tree.txt")
