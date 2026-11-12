-- Tests for local review scopes: branch, uncommitted, last turn.

local h = require("test.helpers")
local repo = require("test.git_repo")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")
local gh_review = require("gh_review")
local local_store = require("gh_review.local_store")
local thread = require("gh_review.thread")
local diff = require("gh_review.diff")

local function files_by_path()
  local result = {}
  for _, f in ipairs(state.get_changed_files()) do
    result[f.path] = f
  end
  return result
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- The real herdr watcher must not run against the temp repo.
require("gh_review.config").setup({ turn = { watch = false } })

local dir = repo.feature_repo()
vim.cmd.cd(dir)

h.run_test("Branch scope lists committed and uncommitted changes against the merge base", function()
  gh_review.open("branch main")

  h.assert_equal("branch", state.get_scope())
  h.assert_true(state.is_local_mode())
  local files = files_by_path()
  h.assert_equal(4, count(files))
  h.assert_equal("MODIFIED", files["a.txt"].changeType)
  h.assert_equal(2, files["a.txt"].additions)
  h.assert_equal("DELETED", files["b.txt"].changeType)
  h.assert_equal("RENAMED", files["d.txt"].changeType)
  h.assert_equal("c.txt", files["d.txt"].previousPath)
  h.assert_equal("ADDED", files["e.txt"].changeType, "untracked files are included")
  h.assert_equal(repo.git(dir, { "merge-base", "main", "HEAD" }), state.get_merge_base_oid())
end)

h.run_test("Files list header names the scope and base", function()
  local lines = vim.api.nvim_buf_get_lines(state.get_files_bufnr(), 0, 3, false)
  h.assert_match("^Branch · feature vs main %(%x+%)$", lines[1])
  h.assert_equal("Files changed (4)   ? help · s stack view", lines[2])
end)

h.run_test("Snapshots leave the real index untouched", function()
  h.assert_equal("", repo.git(dir, { "diff", "--cached", "--name-only" }))
  h.assert_match("%?%? e.txt", repo.git(dir, { "status", "--porcelain" }))
end)

h.run_test("Uncommitted scope lists only working-tree changes", function()
  gh_review.set_scope("uncommitted")

  local files = files_by_path()
  h.assert_equal(2, count(files))
  h.assert_equal("MODIFIED", files["a.txt"].changeType)
  h.assert_equal(1, files["a.txt"].additions)
  h.assert_equal("ADDED", files["e.txt"].changeType)
  h.assert_equal(repo.git(dir, { "rev-parse", "HEAD" }), state.get_merge_base_oid())
end)

h.run_test("Diff opens the real file on the right and the base on the left", function()
  diff.open("a.txt")
  repo.wait_for(function() return state.get_left_bufnr() ~= -1 end, "the diff to open")

  local right = state.get_right_bufnr()
  h.assert_equal(dir .. "/a.txt", vim.api.nvim_buf_get_name(right))
  h.assert_equal("", vim.bo[right].buftype, "head pane is a real file buffer")
  local left_lines = vim.api.nvim_buf_get_lines(state.get_left_bufnr(), 0, -1, false)
  h.assert_equal("four", left_lines[4], "left shows HEAD's content")
end)

h.run_test("A comment saves to the branch store with the lines it covers", function()
  thread.open_new("a.txt", 4, 4, "RIGHT")
  local bufnr = state.get_thread_bufnr()
  local reply_start = vim.b[bufnr].gh_review_reply_start
  vim.api.nvim_buf_set_lines(bufnr, reply_start - 1, -1, false, { "Why uppercase?" })
  vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)

  local unsent = local_store.unsent()
  h.assert_equal(1, #unsent)
  h.assert_equal("a.txt", unsent[1].path)
  h.assert_equal(4, unsent[1].line)
  h.assert_equal("FOUR", unsent[1].anchor[1])
  h.assert_equal("Why uppercase?", unsent[1].comments.nodes[1].body)
  h.assert_equal(1, count(state.get_threads_for_file("a.txt")))
end)

h.run_test("Switching scope keeps the open file and its comments", function()
  gh_review.set_scope("branch", "main")
  repo.wait_for(function() return state.get_left_bufnr() ~= -1 end, "the diff to reopen")

  h.assert_equal("a.txt", state.get_diff_path())
  h.assert_equal(1, count(state.get_threads_for_file("a.txt")), "right-side comments show in every scope")
end)

h.run_test("Branch scope remembers its base across scope switches", function()
  gh_review.set_scope("uncommitted")
  gh_review.set_scope("branch")
  h.assert_equal("main", state.get_local_info().base_label)
  repo.wait_for(function() return state.get_left_bufnr() ~= -1 end, "the diff to reopen")
end)

h.run_test("Comments follow their lines when the file changes", function()
  repo.write(dir, "a.txt", { "inserted", "also inserted", "one", "TWO", "three", "FOUR", "five" })
  gh_review.refresh_threads()
  local t = state.get_threads_for_file("a.txt")[1]
  h.assert_equal(6, t.line, "moved down two lines with FOUR")
  h.assert_false(t.isOutdated)
  h.assert_equal(4, local_store.unsent()[1].line, "the store keeps the original line")

  repo.write(dir, "a.txt", { "one", "TWO", "three", "five" })
  gh_review.refresh_threads()
  h.assert_true(state.get_threads_for_file("a.txt")[1].isOutdated, "outdated once its lines are gone")

  repo.write(dir, "a.txt", { "one", "TWO", "three", "FOUR", "five" })
  gh_review.refresh_threads()
end)

h.run_test("Refreshing keeps an open comment draft and the diff", function()
  thread.open_new("a.txt", 1, 1, "RIGHT")
  local draft = state.get_thread_bufnr()
  local right = state.get_right_bufnr()
  gh_review.reload_local()
  h.assert_equal(draft, state.get_thread_bufnr())
  h.assert_true(vim.api.nvim_buf_is_valid(draft))
  h.assert_equal(right, state.get_right_bufnr())
  h.assert_equal("a.txt", state.get_diff_path())
  thread.close_thread_buffer()
end)

h.run_test("Jumping from the head pane to another changed file opens it as a diff", function()
  diff.open("a.txt")
  repo.wait_for(function() return state.get_left_bufnr() ~= -1 and state.get_diff_path() == "a.txt" end, "a.txt")
  vim.wait(50)
  local win = vim.fn.bufwinid(state.get_right_bufnr())
  vim.fn.win_gotoid(win)
  -- What gd or gF does: another file in the same window, cursor placed.
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/e.txt"))
  repo.wait_for(function() return state.get_diff_path() == "e.txt" and state.get_left_bufnr() ~= -1 end, "e.txt diff")
  repo.wait_for(function() return vim.api.nvim_buf_get_name(state.get_right_bufnr()):find("e%.txt$") ~= nil end, "head pane")
  h.assert_equal(dir .. "/e.txt", vim.api.nvim_buf_get_name(state.get_right_bufnr()))
  h.assert_true(vim.wo[vim.fn.bufwinid(state.get_right_bufnr())].diff, "in diff mode")

  -- And back again, as <C-o> would.
  vim.fn.win_gotoid(vim.fn.bufwinid(state.get_right_bufnr()))
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
  repo.wait_for(function() return state.get_diff_path() == "a.txt" and state.get_left_bufnr() ~= -1 end, "back to a.txt")
end)

h.run_test("With diff_follow off, a jump leaves the diff alone", function()
  require("gh_review.config").options.diff_follow = false
  vim.fn.win_gotoid(vim.fn.bufwinid(state.get_right_bufnr()))
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/e.txt"))
  vim.wait(200)
  h.assert_equal("a.txt", state.get_diff_path())
  require("gh_review.config").options.diff_follow = true
  vim.cmd("buffer #")
  vim.wait(100)
end)

h.run_test("The store survives a reload", function()
  local path = local_store.path_for(dir, "feature")
  h.assert_true(vim.uv.fs_stat(path) ~= nil, "store file written")
  h.assert_match("/gh%-review/feature%.json$", path)
  local_store.reset()
  local_store.load(path)
  h.assert_equal(1, #local_store.unsent())
end)

h.run_test("Left-side comments show only against the base they were made on", function()
  local_store.add_thread({ path = "a.txt", line = 2, diffSide = "LEFT", left_base = "base1" }, "old line")
  local shown = {}
  for _, t in ipairs(local_store.threads_for("base1")) do shown[#shown + 1] = t.diffSide end
  h.assert_equal(2, #shown)
  h.assert_equal(1, #local_store.threads_for("base2"))
end)

h.run_test("Viewed state is kept per scope", function()
  local_store.set_viewed("branch", "a.txt", true)
  gh_review.set_scope("branch", "main")
  h.assert_true(state.is_file_checked("a.txt"))
  gh_review.set_scope("uncommitted")
  h.assert_false(state.is_file_checked("a.txt"))
end)

h.run_test("Turn scope explains a missing baseline", function()
  gh_review.set_scope("turn")
  h.assert_equal("turn", state.get_scope())
  h.assert_equal(0, #state.get_changed_files())
  h.assert_match("No turn baseline yet", state.get_local_info().note)
end)

h.run_test("Turn scope shows only changes since the mark", function()
  gh_review.mark_turn()
  repo.write(dir, "e.txt", { "new file", "edited in the turn" })
  gh_review.set_scope("turn")

  local files = files_by_path()
  h.assert_equal(1, count(files))
  h.assert_equal("MODIFIED", files["e.txt"].changeType, "e.txt was in the baseline snapshot")
  h.assert_match("^Turn since %d+:%d+ %(gh%-review%)$", state.get_local_info().note)
end)

h.run_test("Statusline shows the scope and unsent count", function()
  h.assert_match("^turn · 2 unsent", gh_review.statusline())
end)

h.run_test("Send delivers unsent comments and marks them sent", function()
  local agent = require("gh_review.agent")
  local original = agent.send
  local delivered
  agent.send = function(text, root, cb)
    delivered = { text = text, root = root }
    cb(true, "stub agent")
  end
  gh_review.send()
  require("gh_review.send_panel").act("<CR>")
  agent.send = original

  h.assert_equal(dir, delivered.root)
  h.assert_match("1%. a%.txt:2 %(base%)", delivered.text)
  h.assert_match("2%. a%.txt:4\n   > FOUR\n   Comment: Why uppercase%?", delivered.text)
  h.assert_equal(0, #local_store.unsent())
  h.assert_equal("turn · 1 thread", gh_review.statusline())
end)

-- Acting on one comment in the send panel (see also test_pr_drafts.lua).
local send_panel = require("gh_review.send_panel")

local function keys(lhs)
  vim.api.nvim_feedkeys(vim.keycode(lhs), "x", false)
end

local function panel_lines()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
end

local function goto_line(text)
  for i, l in ipairs(panel_lines()) do
    if l:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  error("no panel line containing " .. text)
end

local function has_line(text)
  for _, l in ipairs(panel_lines()) do
    if l:find(text, 1, true) then return true end
  end
  return false
end

local real_select = vim.ui.select
local prompts = {}
local function answer(choice)
  prompts = {}
  vim.ui.select = function(_, opts, cb)
    prompts[#prompts + 1] = opts.prompt
    cb(choice, choice == "Yes" and 1 or 2)
  end
end

local function local_thread_on(path, line, anchor, ...)
  local bodies = { ... }
  local t = local_store.add_thread({ path = path, line = line, diffSide = "RIGHT", anchor = { anchor }, anchor_total = 1 },
    bodies[1])
  for i = 2, #bodies do local_store.reply(t.id, bodies[i]) end
  return t
end

h.run_test("The send panel deletes local comments: a reply alone, a first comment with its thread", function()
  local first = local_thread_on("a.txt", 1, "one", "First", "Second")
  local_thread_on("a.txt", 3, "three", "Third")
  h.assert_equal(2, #local_store.unsent())

  gh_review.send()
  h.assert_false(has_line("Why uppercase?"), "comments already sent are not shown, so not editable")
  h.assert_match("dd delete · e edit · %- skip", panel_lines()[2])

  goto_line("Reply (you): Second")
  answer("Yes")
  keys("dd")
  h.assert_equal("Delete this reply from the comment thread?", prompts[1])
  h.assert_false(has_line("Second"))
  h.assert_true(has_line("Comment: First"), "the thread stays")
  h.assert_equal(2, #local_store.unsent())

  goto_line("Comment: First")
  answer("No")
  keys("dd")
  h.assert_equal("Delete this comment?", prompts[1])
  h.assert_true(has_line("Comment: First"), "No keeps it")
  answer("Yes")
  keys("dd")
  h.assert_false(has_line("Comment: First"))
  h.assert_equal(1, #local_store.unsent())
  h.assert_equal(nil, next(state.get_thread(first.id)), "the signs' threads follow the store")
  h.assert_equal(1, #state.get_thread(local_store.unsent()[1].id).comments.nodes)
  h.assert_true(send_panel.is_open())
  send_panel.close()
end)

h.run_test("e edits a local comment, and - leaves it out of one send without deleting it", function()
  gh_review.send()
  goto_line("Comment: Third")
  keys("e")
  local float = vim.api.nvim_get_current_buf()
  h.assert_equal("Third", vim.api.nvim_buf_get_lines(float, 0, -1, false)[1])
  vim.api.nvim_buf_set_lines(float, 0, -1, false, { "Third, reworded" })
  vim.cmd("write")
  h.assert_true(has_line("Comment: Third, reworded"))
  h.assert_equal("Third, reworded", local_store.unsent()[1].comments.nodes[1].body)
  h.assert_equal("Third, reworded", state.get_thread(local_store.unsent()[1].id).comments.nodes[1].body)

  goto_line("Comment: Third, reworded")
  keys("-")
  h.assert_equal("Everything is skipped.", send_panel.preview_text())
  h.assert_equal(1, #local_store.unsent(), "skipping deletes nothing")
  local original = require("gh_review.agent").send
  local sent = false
  require("gh_review.agent").send = function(_, _, cb) sent = true cb(true, "stub") end
  send_panel.act("<CR>")
  require("gh_review.agent").send = original
  h.assert_false(sent, "nothing to send while everything is skipped")
  goto_line("Third, reworded")
  keys("-")
  h.assert_true(has_line("Comment: Third, reworded"))
  send_panel.close()
end)

h.run_test("Deleting the last unsent comment closes the panel", function()
  gh_review.send()
  goto_line("Comment: Third, reworded")
  answer("Yes")
  keys("dd")
  h.assert_false(send_panel.is_open())
  h.assert_equal(0, #local_store.unsent())
  vim.ui.select = real_select
end)

h.run_test("Turn baselines from another day show the date", function()
  h.assert_match("^%d+:%d+$", gh_review.format_time(os.time()))
  h.assert_match("^%a+ %d+ %d+:%d+$", gh_review.format_time(os.time() - 3 * 86400))
end)

h.run_test("Close resets to PR scope", function()
  gh_review.close()
  h.assert_equal("pr", state.get_scope())
  h.assert_false(state.is_local_mode())
end)

h.run_test("PR scope sends unresolved threads with the PR url and leaves them unmarked", function()
  state.reset()
  state.set_repo_info("testowner", "testrepo", "github.com", "origin")
  state.set_pr(fixtures.mock_pr_data())
  state.set_threads(fixtures.mock_thread_nodes())
  state.set_local_checkout(false)
  -- A file with the same path in the cwd must not be quoted: it is not the PR's head.
  repo.write(dir, "src/new_file.ts", { "unrelated working tree content" })

  local agent = require("gh_review.agent")
  local original = agent.send
  local delivered
  agent.send = function(text, root, cb)
    delivered = text
    cb(true, "stub agent")
  end
  gh_review.send()
  require("gh_review.send_panel").act("<CR>")
  agent.send = original

  h.assert_match("^Code review comments from my editor:\nPR: https://github.com/testowner/testrepo/pull/42\n",
    delivered)
  local _, items = delivered:gsub("\n%d+%. ", "")
  h.assert_equal(3, items, "the resolved thread is left out")
  h.assert_false(delivered:find("unrelated", 1, true) ~= nil, "no quote from a tree that is not the head")
  h.assert_equal("pr", state.get_scope())
  state.reset()
end)

h.write_results("/tmp/gh_review_test_scopes.txt")
