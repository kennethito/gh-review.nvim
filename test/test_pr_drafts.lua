-- Tests for PR drafts: comments saved locally until :GHReviewSubmit.

local h = require("test.helpers")
local fixtures = require("test.fixtures")
local state = require("gh_review.state")
local config = require("gh_review.config")
local api = require("gh_review.api")
local graphql = require("gh_review.graphql")
local thread = require("gh_review.thread")
local drafts = require("gh_review.pr_drafts")
local local_store = require("gh_review.local_store")
local gh_review = require("gh_review")

local_store.drafts_dir = vim.fn.tempname()

-- Every GraphQL call is recorded; `respond` decides each answer.
local calls = {}
local respond = function() return nil, "not stubbed" end
api.graphql = function(query, vars, cb)
  calls[#calls + 1] = { query = query, vars = vars }
  local result, err = respond(query, vars)
  cb(result, err)
end

local function name_of(query)
  for name, q in pairs(graphql) do
    if q == query then return name end
  end
  return "QUERY?"
end

local function call_names()
  local names = {}
  for _, c in ipairs(calls) do names[#names + 1] = name_of(c.query) end
  return table.concat(names, " ")
end

local function load_pr(opts)
  config.reset()
  if opts then config.setup(opts) end
  state.reset()
  local_store.reset()
  state.set_repo_info("testowner", "testrepo", "github.com", "origin")
  local data = fixtures.mock_pr_data()
  data.data.repository.pullRequest.reviews.nodes = {}
  state.set_pr(data)
  drafts.attach(fixtures.mock_thread_nodes())
  calls = {}
end

local function write_comment(open, body)
  open()
  local bufnr = state.get_thread_bufnr()
  local reply_start = vim.b[bufnr].gh_review_reply_start
  vim.api.nvim_buf_set_lines(bufnr, reply_start - 1, -1, false, { body })
  vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
end

load_pr()

h.run_test(":w on a new PR comment saves a draft and sends nothing", function()
  write_comment(function() thread.open_new("src/new_file.ts", 12, 12, "RIGHT") end, "Rename this")
  h.assert_equal(0, #calls, "no GitHub calls")
  h.assert_equal(1, drafts.count())
  local found
  for _, t in pairs(state.get_threads()) do
    if drafts.is_draft_thread(t.id) then found = t end
  end
  h.assert_equal("src/new_file.ts", found.path)
  h.assert_equal(12, found.line)
  h.assert_equal("PENDING", found.comments.nodes[1].pullRequestReview.state)
end)

h.run_test(":w on a reply to a GitHub thread saves a draft reply on that thread", function()
  write_comment(function() thread.open("thread_1") end, "Agreed, but one nit")
  h.assert_equal(0, #calls)
  h.assert_equal(2, drafts.count())
  local t = state.get_thread("thread_1")
  local last = t.comments.nodes[#t.comments.nodes]
  h.assert_equal("Agreed, but one nit", last.body)
  h.assert_equal("PENDING", last.pullRequestReview.state)
  h.assert_equal("comment_1", local_store.replies()[1].first_comment_id)
end)

h.run_test("Drafts survive a reload and show in the statusline and files note", function()
  local_store.reset()
  drafts.attach(fixtures.mock_thread_nodes())
  h.assert_equal(2, drafts.count())
  h.assert_match("2 drafts", gh_review.statusline())
end)

h.run_test("Publishing creates a review, uploads every draft, then submits it", function()
  respond = function(query, vars)
    if query == graphql.MUTATION_START_REVIEW then
      return { data = { addPullRequestReview = { pullRequestReview = { id = "rev_new", state = "PENDING" } } } }
    elseif query == graphql.MUTATION_ADD_REVIEW_THREAD then
      return { data = { addPullRequestReviewThread = { thread = { id = "t_new",
        comments = { nodes = { { id = "c_new" } } } } } } }
    elseif query == graphql.MUTATION_ADD_REVIEW_COMMENT then
      return { data = { addPullRequestReviewComment = { comment = { id = "c_reply" } } } }
    elseif query == graphql.MUTATION_SUBMIT_REVIEW then
      return { data = { submitPullRequestReview = { pullRequestReview = { id = vars.reviewId } } } }
    elseif query == graphql.QUERY_REVIEW_THREADS then
      return { data = { repository = { pullRequest = { reviewThreads = { nodes = fixtures.mock_thread_nodes() } } } } }
    end
  end
  drafts.publish("COMMENT", "Looks close")
  h.assert_equal("MUTATION_START_REVIEW MUTATION_ADD_REVIEW_THREAD MUTATION_ADD_REVIEW_COMMENT "
    .. "MUTATION_SUBMIT_REVIEW QUERY_REVIEW_THREADS", call_names())
  h.assert_equal("rev_new", calls[2].vars.pullRequestReviewId)
  h.assert_equal("Rename this", calls[2].vars.body)
  h.assert_equal(12, calls[2].vars.line)
  h.assert_equal("comment_1", calls[3].vars.threadId, "reply goes in reply to the thread's first comment")
  h.assert_equal("COMMENT", calls[4].vars.event)
  h.assert_equal("Looks close", calls[4].vars.body)
  h.assert_equal(0, drafts.count(), "drafts cleared once on GitHub")
  h.assert_false(state.is_review_active())
end)

h.run_test("A failure part way keeps the rest as drafts and the review open", function()
  load_pr()
  write_comment(function() thread.open_new("src/new_file.ts", 3, 3, "RIGHT") end, "First")
  write_comment(function() thread.open("thread_2") end, "Second")
  calls = {}
  local errors = {}
  local notify = vim.notify
  vim.notify = function(msg) errors[#errors + 1] = msg end
  respond = function(query)
    if query == graphql.MUTATION_START_REVIEW then
      return { data = { addPullRequestReview = { pullRequestReview = { id = "rev_x", state = "PENDING" } } } }
    elseif query == graphql.MUTATION_ADD_REVIEW_THREAD then
      return { data = { addPullRequestReviewThread = { thread = { id = "t1", comments = { nodes = { { id = "c1" } } } } } } }
    elseif query == graphql.MUTATION_ADD_REVIEW_COMMENT then
      return nil, "boom"
    elseif query == graphql.QUERY_REVIEW_THREADS then
      return { data = { repository = { pullRequest = { reviewThreads = { nodes = fixtures.mock_thread_nodes() } } } } }
    end
  end
  drafts.publish("COMMENT", "")
  vim.notify = notify
  h.assert_equal(1, drafts.count(), "the reply that failed is still a draft")
  h.assert_equal("Second", local_store.replies()[1].body)
  h.assert_equal("rev_x", state.get_pending_review_id(), "pending review stays open for a retry")
  h.assert_match("Publishing stopped after 1 draft", errors[1])
  h.assert_false(call_names():find("SUBMIT") ~= nil, "not submitted")
end)

h.run_test("Upload-only puts drafts in the pending review without submitting", function()
  calls = {}
  respond = function(query)
    if query == graphql.MUTATION_ADD_REVIEW_COMMENT then
      return { data = { addPullRequestReviewComment = { comment = { id = "c2" } } } }
    elseif query == graphql.QUERY_REVIEW_THREADS then
      return { data = { repository = { pullRequest = { reviewThreads = { nodes = fixtures.mock_thread_nodes() } } } } }
    end
  end
  drafts.publish(nil)
  h.assert_equal("MUTATION_ADD_REVIEW_COMMENT QUERY_REVIEW_THREADS", call_names(), "reuses the open review")
  h.assert_equal("rev_x", calls[1].vars.pullRequestReviewId)
  h.assert_equal(0, drafts.count())
  h.assert_equal("rev_x", state.get_pending_review_id())
end)

h.run_test("Discard deletes local drafts and leaves GitHub alone", function()
  load_pr()
  write_comment(function() thread.open_new("src/new_file.ts", 4, 4, "RIGHT") end, "Throwaway")
  calls = {}
  local select = vim.ui.select
  vim.ui.select = function(items, _, cb) cb(items[1], 1) end
  gh_review.discard_review()
  vim.ui.select = select
  h.assert_equal(0, drafts.count())
  h.assert_equal(0, #calls)
end)

h.run_test("With pr_drafts = false, :w posts to GitHub straight away", function()
  load_pr({ pr_drafts = false })
  respond = function()
    return { data = { addPullRequestReviewThread = { thread = { id = "t9", path = "src/new_file.ts", line = 7,
      comments = { nodes = { { id = "c9", body = "Now" } } } } } } }
  end
  write_comment(function() thread.open_new("src/new_file.ts", 7, 7, "RIGHT") end, "Now")
  h.assert_equal("MUTATION_ADD_REVIEW_THREAD", call_names())
  h.assert_equal(0, drafts.count())
end)

-- ------- Agent notes and the send/publish panels -------

local send_panel = require("gh_review.send_panel")

local function press(bufnr, lhs)
  vim.api.nvim_buf_call(bufnr, function()
    vim.fn.maparg(lhs, "n", false, true).callback()
  end)
end

-- Like write_comment, switching the comment to an agent note first.
local function write_note(open, body)
  open()
  local bufnr = state.get_thread_bufnr()
  h.assert_match("→ GitHub draft", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  press(bufnr, "ga")
  h.assert_match("→ agent only, never published", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  local reply_start = vim.b[bufnr].gh_review_reply_start
  vim.api.nvim_buf_set_lines(bufnr, reply_start - 1, -1, false, { body })
  vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
end

h.run_test("Agent notes are saved locally and are not drafts", function()
  load_pr()
  write_comment(function() thread.open_new("src/new_file.ts", 12, 12, "RIGHT") end, "Rename this")
  write_comment(function() thread.open("thread_4") end, "Nit for the PR")
  write_note(function() thread.open_new("src/new_file.ts", 30, 30, "RIGHT") end, "Check the callers too")
  write_note(function() thread.open("thread_2") end, "Bob was wrong here")
  h.assert_equal(0, #calls, "nothing goes to GitHub")
  h.assert_equal(2, drafts.count(), "agent notes are not counted as drafts")
  h.assert_equal(2, local_store.agent_note_count())
end)

h.run_test("The comment switch is locked on your own draft and agent-note threads", function()
  local note
  for _, t in pairs(state.get_threads()) do
    if drafts.is_draft_thread(t.id) and t.agent_only then note = t end
  end
  thread.open(note.id)
  local bufnr = state.get_thread_bufnr()
  h.assert_true(vim.b[bufnr].gh_review_agent_only)
  press(bufnr, "ga")
  h.assert_true(vim.b[bufnr].gh_review_agent_only, "an agent-note thread's replies stay notes")
  h.assert_false(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]:find("to switch", 1, true) ~= nil,
    "no switch hint when locked")
  thread.close_thread_buffer()

  local draft
  for _, t in pairs(state.get_threads()) do
    if drafts.is_draft_thread(t.id) and not t.agent_only then draft = t end
  end
  thread.open(draft.id)
  bufnr = state.get_thread_bufnr()
  press(bufnr, "ga")
  h.assert_false(vim.b[bufnr].gh_review_agent_only, "a reply on your draft is published with it")
  thread.close_thread_buffer()
end)

h.run_test("Agent notes get their own sign and label", function()
  vim.cmd("enew")
  local buf = vim.fn.bufnr("gh-review://RIGHT/src/new_file.ts", true)
  vim.cmd("buffer " .. buf)
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(string.rep("x\n", 49) .. "x", "\n"))
  state.set_right_bufnr(buf)
  state.set_diff_path("src/new_file.ts")
  require("gh_review.diff").refresh_signs()
  local signs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, state.ns, 0, -1, { details = true })) do
    if m[4].sign_text then signs[m[2] + 1] = m[4] end
  end
  h.assert_equal("CA", vim.trim(signs[30].sign_text))
  h.assert_equal("GHReviewThreadAgent", signs[30].sign_hl_group)
  h.assert_match("^%(agent%) you: Check the callers", signs[30].virt_text[1][1])
  h.assert_equal("CA", vim.trim(signs[25].sign_text), "a GitHub thread whose last reply is a note")
  h.assert_equal("CP", vim.trim(signs[12].sign_text), "a draft stays pending")
  state.set_right_bufnr(-1)
  vim.cmd("bwipeout! " .. buf)
end)

h.run_test("Send panel counts each kind and previews exactly what is sent", function()
  state.set_local_checkout(false)
  local counts = {}
  for _, c in ipairs(gh_review.send_categories()) do counts[c.key] = c.count end
  h.assert_equal(3, counts.github, "unresolved GitHub threads")
  h.assert_equal(2, counts.drafts)
  h.assert_equal(2, counts.agent)

  gh_review.send()
  h.assert_true(send_panel.is_open())
  local all = send_panel.preview_text()
  h.assert_match("Rename this", all)
  h.assert_match("Check the callers too", all)
  h.assert_match("Looks good", all)

  send_panel.toggle("github")
  send_panel.toggle("drafts")
  local notes = send_panel.preview_text()
  h.assert_false(notes:find("Rename this", 1, true) ~= nil, "drafts unticked")
  h.assert_false(notes:find("Looks good", 1, true) ~= nil, "GitHub threads unticked")
  h.assert_false(notes:find("Nit for the PR", 1, true) ~= nil)
  h.assert_match("Comment: Fix this\n   Reply %(alice%): Done\n   Reply %(you%): Bob was wrong here", notes,
    "a note on a GitHub thread brings that thread as context")
  local _, items = notes:gsub("\n%d+%. ", "")
  h.assert_equal(2, items)

  local agent = require("gh_review.agent")
  local original = agent.send
  local delivered
  agent.send = function(text, _, cb)
    delivered = text
    cb(true, "stub agent")
  end
  send_panel.act("<CR>")
  agent.send = original
  h.assert_false(send_panel.is_open())
  h.assert_equal(notes, delivered, "what was shown is what was sent")
end)

h.run_test("Panel keys tick the category under the cursor and close", function()
  gh_review.send()
  vim.api.nvim_feedkeys(vim.keycode("j<Space>"), "x", false)
  local selected = send_panel.selected()
  h.assert_true(selected.github)
  h.assert_true(selected.drafts == nil, "the second row was unticked")
  vim.api.nvim_feedkeys("2", "x", false)
  h.assert_true(send_panel.selected().drafts, "number keys tick by position")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  h.assert_false(send_panel.is_open())
end)

h.run_test("Sending with nothing ticked keeps the panel open", function()
  gh_review.send()
  for _, key in ipairs({ "github", "drafts", "agent" }) do send_panel.toggle(key) end
  send_panel.act("<CR>")
  h.assert_true(send_panel.is_open())
  send_panel.close()
end)

h.run_test("Submit previews the drafts it publishes and leaves agent notes out", function()
  local preview = gh_review.publish_preview()
  h.assert_match("^Publishing 2 drafts to the PR %(2 agent notes stay here%):", preview)
  h.assert_match("src/existing.ts:5 · reply to alice: \"Pending note\"\n   Reply: Nit for the PR", preview)
  h.assert_match("src/new_file.ts:12\n   Comment: Rename this", preview)
  h.assert_false(preview:find("callers", 1, true) ~= nil)
  h.assert_false(preview:find("Bob was wrong", 1, true) ~= nil)
end)

h.run_test("Publishing from the submit panel skips agent notes", function()
  calls = {}
  respond = function(query)
    if query == graphql.MUTATION_START_REVIEW then
      return { data = { addPullRequestReview = { pullRequestReview = { id = "rev_p", state = "PENDING" } } } }
    elseif query == graphql.MUTATION_ADD_REVIEW_THREAD then
      return { data = { addPullRequestReviewThread = { thread = { id = "t_p", comments = { nodes = { { id = "c_p" } } } } } } }
    elseif query == graphql.MUTATION_ADD_REVIEW_COMMENT then
      return { data = { addPullRequestReviewComment = { comment = { id = "c_r" } } } }
    elseif query == graphql.QUERY_REVIEW_THREADS then
      return { data = { repository = { pullRequest = { reviewThreads = { nodes = fixtures.mock_thread_nodes() } } } } }
    end
  end
  gh_review.submit_review()
  h.assert_true(send_panel.is_open())
  send_panel.act("u")
  h.assert_equal("MUTATION_START_REVIEW MUTATION_ADD_REVIEW_THREAD MUTATION_ADD_REVIEW_COMMENT QUERY_REVIEW_THREADS",
    call_names())
  h.assert_equal("Rename this", calls[2].vars.body)
  h.assert_equal("Nit for the PR", calls[3].vars.body)
  h.assert_equal(0, drafts.count())
  h.assert_equal(2, local_store.agent_note_count(), "agent notes stay after publishing")
end)

h.run_test("Discard asks which local comments to delete and keeps the rest", function()
  write_comment(function() thread.open_new("src/new_file.ts", 40, 40, "RIGHT") end, "Another")
  local offered
  local select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    offered = items
    cb(items[1], 1)
  end
  gh_review.discard_review()
  h.assert_equal("Drafts (1 draft)", offered[1])
  h.assert_equal("Agent notes (2 notes)", offered[2])
  h.assert_equal("Both", offered[3])
  h.assert_equal(0, drafts.count())
  h.assert_equal(2, local_store.agent_note_count(), "notes kept")

  gh_review.discard_review()
  vim.ui.select = select
  h.assert_equal("Agent notes (2 notes)", offered[1], "notes alone can be deleted")
  h.assert_equal(0, local_store.agent_note_count())
end)

-- ------- Acting on one comment in the panels: dd, e, - -------

local real_select = vim.ui.select
local prompts
local function answer(choice)
  prompts = {}
  vim.ui.select = function(items, opts, cb)
    prompts[#prompts + 1] = opts.prompt
    cb(choice, choice == "Yes" and 1 or 2)
  end
end

-- Type keys as a user would, so a window the mapping opens keeps focus (the
-- mapping callback in nvim_buf_call hands focus back when it returns).
local function keys(lhs)
  vim.api.nvim_feedkeys(vim.keycode(lhs), "x", false)
end

-- Messages the plugin prints.
local function capture_print(fn)
  local printed = {}
  local real = _G.print
  _G.print = function(...) printed[#printed + 1] = table.concat(vim.tbl_map(tostring, { ... }), " ") end
  local ok, err = pcall(fn)
  _G.print = real
  if not ok then error(err, 0) end
  return table.concat(printed, "\n")
end

local function panel_lines()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
end

-- Put the panel's cursor on the first line containing `text`.
local function goto_line(text)
  for i, l in ipairs(panel_lines()) do
    if l:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return i
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

-- A draft thread (with a second comment), a draft reply on a GitHub thread, and
-- two agent notes.
local function load_comments()
  -- Drafts are kept on disk per PR; start from none.
  vim.fn.delete(local_store.drafts_dir, "rf")
  load_pr()
  write_comment(function() thread.open_new("src/new_file.ts", 12, 12, "RIGHT") end, "Rename this")
  local draft
  for _, t in pairs(state.get_threads()) do
    if drafts.is_draft_thread(t.id) then draft = t end
  end
  write_comment(function() thread.open(draft.id) end, "Second thought")
  write_comment(function() thread.open("thread_4") end, "Nit for the PR")
  write_note(function() thread.open_new("src/new_file.ts", 30, 30, "RIGHT") end, "Check the callers too")
  write_note(function() thread.open("thread_2") end, "Bob was wrong here")
  calls = {}
  return draft.id
end

local function category_line(label)
  for _, l in ipairs(panel_lines()) do
    if l:find(label, 1, true) then return l end
  end
end

h.run_test("dd on a draft asks first, then deletes the draft thread and updates the panel", function()
  local draft_id = load_comments()
  gh_review.send()
  h.assert_match("My drafts %(2%)", category_line("My drafts"))
  local win = vim.api.nvim_get_current_win()

  goto_line("Comment: Rename this")
  answer("No")
  press(vim.api.nvim_get_current_buf(), "dd")
  h.assert_equal("Delete this draft thread and its 2 comments?", prompts[1])
  h.assert_true(has_line("Rename this"), "No keeps it")
  h.assert_true(state.get_thread(draft_id) ~= nil)

  answer("Yes")
  press(vim.api.nvim_get_current_buf(), "dd")
  h.assert_false(has_line("Rename this"), "gone from the preview")
  h.assert_false(has_line("Second thought"), "the whole thread went")
  h.assert_match("My drafts %(1%)", category_line("My drafts"))
  h.assert_equal(win, vim.api.nvim_get_current_win(), "the panel stays open")
  h.assert_equal(nil, next(state.get_thread(draft_id)), "signs and files list read the same threads")
  h.assert_equal(1, drafts.count())
  h.assert_equal(0, #calls, "nothing goes to GitHub")
  send_panel.close()
end)

h.run_test("dd on a later comment deletes only that comment", function()
  local draft_id = load_comments()
  gh_review.send()
  goto_line("Reply (you): Second thought")
  answer("Yes")
  press(vim.api.nvim_get_current_buf(), "dd")
  h.assert_equal("Delete this reply from the draft thread?", prompts[1])
  h.assert_true(has_line("Comment: Rename this"))
  h.assert_false(has_line("Second thought"))
  h.assert_equal(1, #state.get_thread(draft_id).comments.nodes)
  h.assert_equal(2, drafts.count(), "the thread is still a draft")
  send_panel.close()
end)

h.run_test("dd on a draft reply to a GitHub thread removes just the reply", function()
  load_comments()
  gh_review.send()
  goto_line("Reply (you): Nit for the PR")
  answer("Yes")
  press(vim.api.nvim_get_current_buf(), "dd")
  h.assert_equal("Delete this draft reply?", prompts[1])
  h.assert_equal(1, #local_store.replies(), "only the agent note reply is left")
  h.assert_equal(1, #state.get_thread("thread_4").comments.nodes)
  h.assert_true(has_line("Comment: Pending note"), "the GitHub comment stays")
  h.assert_false(has_line("Nit for the PR"))
  send_panel.close()
end)

h.run_test("dd on an agent note says so and deletes it", function()
  load_comments()
  gh_review.send()
  goto_line("Check the callers too")
  answer("Yes")
  keys("dd")
  h.assert_equal("Delete this agent note?", prompts[1])
  h.assert_equal(1, local_store.agent_note_count())
  h.assert_match("Agent notes %(1%)", category_line("Agent notes"))
  send_panel.close()
end)

h.run_test("dd and e on a GitHub comment leave it alone", function()
  load_comments()
  gh_review.send()
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local threads_before = vim.tbl_count(state.get_threads())
  for _, key in ipairs({ "dd", "e" }) do
    goto_line("Comment: Looks good")
    answer("Yes")
    local printed = capture_print(function() press(buf, key) end)
    h.assert_match("on GitHub", printed)
    h.assert_equal(0, #prompts, "no question for a GitHub comment")
    h.assert_equal(win, vim.api.nvim_get_current_win(), "no edit float")
  end
  -- A title line acts on its item's first comment: also GitHub's here.
  goto_line("src/new_file.ts:10")
  h.assert_match("on GitHub", capture_print(function() press(buf, "dd") end))
  -- Lines that belong to no comment do nothing.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  h.assert_match("Not on a comment", capture_print(function() press(buf, "dd") end))
  h.assert_equal(threads_before, vim.tbl_count(state.get_threads()))
  send_panel.close()
end)

h.run_test("e edits a comment in a float and :w saves it back", function()
  load_comments()
  gh_review.send()
  local panel_win = vim.api.nvim_get_current_win()
  goto_line("Reply (you): Nit for the PR")
  keys("e")
  h.assert_true(vim.api.nvim_get_current_win() ~= panel_win, "a float opened")
  local float = vim.api.nvim_get_current_buf()
  h.assert_equal("Nit for the PR", vim.api.nvim_buf_get_lines(float, 0, -1, false)[1])
  vim.api.nvim_buf_set_lines(float, 0, -1, false, { "Nit, reworded", "with a second line" })
  vim.cmd("write")
  h.assert_equal(panel_win, vim.api.nvim_get_current_win(), "focus returns to the panel")
  h.assert_false(vim.api.nvim_buf_is_valid(float), "the float is gone")
  h.assert_equal("Nit, reworded\nwith a second line", local_store.replies()[1].body)
  h.assert_true(has_line("Reply (you): Nit, reworded"))
  h.assert_true(has_line("   with a second line"))
  h.assert_match("Nit, reworded", state.get_thread("thread_4").comments.nodes[2].body)
  send_panel.close()
end)

h.run_test("e on the first comment of a draft thread, and q cancels", function()
  local draft_id = load_comments()
  gh_review.send()
  local panel_win = vim.api.nvim_get_current_win()
  goto_line("Comment: Rename this")
  keys("e")
  local float = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(float, 0, -1, false, { "Discarded edit" })
  keys("q")
  h.assert_equal(panel_win, vim.api.nvim_get_current_win())
  h.assert_equal("Rename this", state.get_thread(draft_id).comments.nodes[1].body)

  keys("e")
  vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "Rename that" })
  vim.cmd("write")
  h.assert_equal("Rename that", state.get_thread(draft_id).comments.nodes[1].body)
  h.assert_equal("Rename that", local_store.threads()[1].comments.nodes[1].body, "saved to the store")
  h.assert_true(has_line("Comment: Rename that"))
  send_panel.close()
end)

h.run_test("An empty edit is refused and keeps the float open", function()
  load_comments()
  gh_review.send()
  goto_line("Reply (you): Nit for the PR")
  keys("e")
  local float = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(float, 0, -1, false, { "  " })
  local printed = capture_print(function() vim.cmd("write") end)
  h.assert_match("cannot be empty", printed)
  h.assert_equal(float, vim.api.nvim_get_current_buf())
  h.assert_equal("Nit for the PR", local_store.replies()[1].body)
  keys("q")
  send_panel.close()
end)

-- The panel text around the preview, to compare with what was sent.
local function send_with_stub()
  local agent = require("gh_review.agent")
  local original = agent.send
  local delivered
  agent.send = function(text, _, cb)
    delivered = text
    cb(true, "stub agent")
  end
  send_panel.act("<CR>")
  agent.send = original
  return delivered
end

h.run_test("- leaves an item out of this send only, and the text sent equals the preview", function()
  load_comments()
  gh_review.send()
  local buf = vim.api.nvim_get_current_buf()
  local _, items_before = send_panel.preview_text():gsub("\n%d+%. ", "")

  goto_line("Comment: Looks good")
  press(buf, "-")
  local preview = send_panel.preview_text()
  h.assert_false(preview:find("Looks good", 1, true) ~= nil, "absent from the text")
  local _, items = preview:gsub("\n%d+%. ", "")
  h.assert_equal(items_before - 1, items)
  h.assert_true(has_line("Skipped for this send"), "listed apart so it can come back")
  h.assert_true(has_line("src/new_file.ts:10 · alice: Looks good"))
  h.assert_true(send_panel.skipped().thread_1)

  -- Skipping a thread that holds a draft reply works the same way.
  goto_line("Comment: Pending note")
  press(buf, "-")
  h.assert_false(send_panel.preview_text():find("Nit for the PR", 1, true) ~= nil)

  local shown = send_panel.preview_text()
  local delivered = send_with_stub()
  h.assert_equal(shown, delivered, "what was shown is what was sent")
  h.assert_equal(2, #local_store.replies(), "nothing was deleted")
  h.assert_true(state.get_thread("thread_1") ~= nil)
end)

h.run_test("- on the skipped list brings the item back, in place", function()
  load_comments()
  gh_review.send()
  local buf = vim.api.nvim_get_current_buf()
  local full = send_panel.preview_text()
  goto_line("Comment: Looks good")
  press(buf, "-")
  goto_line("src/new_file.ts:10 · alice: Looks good")
  press(buf, "-")
  h.assert_equal(full, send_panel.preview_text())
  h.assert_false(has_line("Skipped for this send"))
  h.assert_match("^%d+%. src/new_file.ts:10$", panel_lines()[vim.api.nvim_win_get_cursor(0)[1]], "cursor follows the item")
  send_panel.close()
end)

h.run_test("Skips survive ticking, and unticked items drop out of the skipped list", function()
  load_comments()
  gh_review.send()
  goto_line("Comment: Looks good")
  press(vim.api.nvim_get_current_buf(), "-")
  send_panel.toggle("github")
  h.assert_false(has_line("Skipped for this send"), "its category is unticked")
  send_panel.toggle("github")
  h.assert_true(has_line("Skipped for this send"), "still skipped when ticked again")
  send_panel.close()
end)

h.run_test("Skipping everything keeps the panel open and refuses to send", function()
  load_comments()
  gh_review.send()
  local buf = vim.api.nvim_get_current_buf()
  for _, key in ipairs({ "drafts", "agent" }) do send_panel.toggle(key) end
  for _, id in ipairs({ "Comment: Looks good", "Comment: General comment", "Comment: Pending note" }) do
    goto_line(id)
    press(buf, "-")
  end
  h.assert_equal("Everything is skipped.", send_panel.preview_text())
  local printed = capture_print(function() send_panel.act("<CR>") end)
  h.assert_match("Nothing to send", printed)
  h.assert_true(send_panel.is_open())
  send_panel.close()
end)

h.run_test("Deleting the last comment closes the panel", function()
  vim.fn.delete(local_store.drafts_dir, "rf")
  load_pr()
  write_comment(function() thread.open_new("src/new_file.ts", 12, 12, "RIGHT") end, "Only one")
  state.set_threads(drafts.merged())
  gh_review.send()
  for _, key in ipairs({ "github", "agent" }) do send_panel.toggle(key) end
  goto_line("Comment: Only one")
  answer("Yes")
  -- Unresolved GitHub threads still count, so the panel stays.
  press(vim.api.nvim_get_current_buf(), "dd")
  h.assert_true(send_panel.is_open())
  send_panel.close()

  state.set_threads({})
  drafts.attach({})
  write_comment(function() thread.open_new("src/new_file.ts", 12, 12, "RIGHT") end, "Last one")
  gh_review.submit_review()
  h.assert_true(send_panel.is_open())
  goto_line("Comment: Last one")
  local printed = capture_print(function() press(vim.api.nvim_get_current_buf(), "dd") end)
  h.assert_false(send_panel.is_open(), "nothing left to publish")
  h.assert_match("No drafts left", printed)
  h.assert_equal(0, drafts.count())
end)

h.run_test("The submit panel deletes and edits drafts, with no skip key", function()
  load_comments()
  gh_review.submit_review()
  h.assert_true(send_panel.is_open())
  local buf = vim.api.nvim_get_current_buf()
  h.assert_equal(0, vim.api.nvim_buf_call(buf, function() return vim.fn.maparg("-", "n", false, true).buffer end),
    "no skip when publishing")
  h.assert_match("dd delete · e edit", panel_lines()[2])

  -- Every line of a comment, and its title, maps to that comment.
  goto_line("Reply: Nit for the PR")
  answer("Yes")
  keys("e")
  local float = vim.api.nvim_get_current_buf()
  h.assert_equal("Nit for the PR", vim.api.nvim_buf_get_lines(float, 0, -1, false)[1])
  vim.api.nvim_buf_set_lines(float, 0, -1, false, { "Nit, final" })
  vim.cmd("write")
  h.assert_true(has_line("Reply: Nit, final"))
  h.assert_match("Nit, final", gh_review.publish_preview())

  goto_line("src/existing.ts:5 · reply to alice")
  press(buf, "dd")
  h.assert_equal("Delete this draft reply?", prompts[1])
  h.assert_false(has_line("Nit, final"))
  h.assert_match("^ *Publishing 1 draft ", panel_lines()[4])

  goto_line("Reply: Second thought")
  press(buf, "dd")
  h.assert_equal("Delete this reply from the draft thread?", prompts[2])
  h.assert_equal(1, drafts.count())
  send_panel.close()
end)

h.run_test("Preview spans map every line to the comment it came from", function()
  load_comments()
  local text, spans = gh_review.publish_preview()
  local lines = vim.split(text, "\n", { plain = true })
  h.assert_equal(2, #spans)
  for _, item in ipairs(spans) do
    h.assert_match("^%d+%. ", lines[item.first_line])
    for _, c in ipairs(item.comments) do
      h.assert_match("^   %a+: ", lines[c.first_line])
      h.assert_true(local_store.is_local_comment(c.comment_id))
    end
  end
  h.assert_equal(2, #spans[2].comments, "the draft thread has its second comment")
  h.assert_equal("Second thought", local_store.locate_comment(spans[2].comments[2].comment_id).comment.body)
end)

vim.ui.select = real_select

h.write_results("/tmp/gh_review_test_pr_drafts.txt")
