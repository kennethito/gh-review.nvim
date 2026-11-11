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

h.write_results("/tmp/gh_review_test_pr_drafts.txt")
