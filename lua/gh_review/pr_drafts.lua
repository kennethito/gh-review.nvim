-- PR drafts: comments and replies on a PR saved locally, not sent to GitHub,
-- until :GHReviewSubmit publishes them as one review.
--
-- Draft threads keep the GitHub thread shape (ids "local_thread_N") and draft
-- replies are appended to their GitHub thread as pending comments, so signs,
-- the thread buffer, navigation, and send-to-agent all see them.

local state = require("gh_review.state")
local config = require("gh_review.config")
local local_store = require("gh_review.local_store")
local api_mod = require("gh_review.api")
local graphql = require("gh_review.graphql")

local M = {}

-- The last threads fetched from GitHub, to re-merge drafts without a fetch.
local github_threads = {}

function M.github_threads()
  return github_threads
end

function M.enabled()
  return config.options.pr_drafts and not state.is_local_mode() and state.get_pr_id() ~= ""
end

function M.is_draft_thread(id)
  return type(id) == "string" and id:find("^local_thread_") ~= nil
end

-- Load the PR's drafts and merge them into the GitHub threads.
function M.attach(thread_nodes)
  github_threads = thread_nodes or {}
  if not config.options.pr_drafts then
    state.set_threads(github_threads)
    return
  end
  local path = local_store.path_for_pr(state.get_host(), state.get_owner(), state.get_name(), state.get_pr_number())
  local_store.load(path)
  M.refresh()
end

-- GitHub threads plus drafts: draft threads as their own threads, draft
-- replies appended to the GitHub thread they answer.
function M.merged()
  local by_id, result = {}, {}
  for _, t in ipairs(github_threads) do
    local copy = vim.deepcopy(t)
    by_id[t.id] = copy
    result[#result + 1] = copy
  end
  if not local_store.is_loaded() then return result end
  for _, reply in ipairs(local_store.replies()) do
    local t = by_id[reply.thread_id]
    if t then
      t.comments = t.comments or { nodes = {} }
      t.comments.nodes = t.comments.nodes or {}
      table.insert(t.comments.nodes, {
        id = reply.id, body = reply.body, author = reply.author, createdAt = reply.createdAt,
        pullRequestReview = { state = "PENDING" }, draft = true, agent_only = reply.agent_only,
      })
    end
  end
  for _, t in ipairs(local_store.threads()) do
    result[#result + 1] = t
  end
  return result
end

function M.refresh()
  state.set_threads(M.merged())
  require("gh_review.diff").refresh_signs()
  require("gh_review.files").rerender()
end

function M.count()
  if not config.options.pr_drafts or state.is_local_mode() or not local_store.is_loaded() then return 0 end
  return local_store.draft_count()
end

function M.note_count()
  if not config.options.pr_drafts or state.is_local_mode() or not local_store.is_loaded() then return 0 end
  return local_store.agent_note_count()
end

-- ------- Publishing -------

-- Run async steps one after another; stop at the first failure.
local function sequence(steps, done)
  local i = 0
  local function nxt(ok, err)
    if not ok then return done(false, err) end
    i = i + 1
    if i > #steps then return done(true) end
    steps[i](nxt)
  end
  nxt(true)
end

local function graphql_step(query, vars, check)
  return function(next_step)
    api_mod.graphql(query, vars, function(result, err)
      if err then return next_step(false, err) end
      local value = check(result)
      if value == nil then return next_step(false, "unexpected response") end
      next_step(true, value)
    end)
  end
end

-- The review drafts go into: the open pending review, or a new one.
local function ensure_review(next_step)
  if state.is_review_active() then return next_step(true) end
  api_mod.graphql(graphql.MUTATION_START_REVIEW, { pullRequestId = state.get_pr_id() }, function(result, err)
    local review = ((((result or {}).data or {}).addPullRequestReview or {}).pullRequestReview or {})
    if err or not review.id then return next_step(false, err or "could not start a review") end
    state.set_pending_review_id(review.id)
    next_step(true)
  end)
end

-- Upload every draft into a pending review, then submit it as `event`
-- ("COMMENT", "APPROVE", "REQUEST_CHANGES"), or leave it pending when event is
-- nil. Each draft is removed as soon as GitHub has it, so a failure part way
-- leaves only the rest as drafts and the pending review open.
function M.publish(event, body, done)
  done = done or function() end
  local steps = { ensure_review }
  local uploaded = 0

  for _, t in ipairs(vim.deepcopy(local_store.threads())) do
    -- Agent notes stay local: they are for the agent, not the PR.
    if not t.isResolved and not t.agent_only then
      local comments = t.comments.nodes
      local first_comment_id = nil
      steps[#steps + 1] = function(next_step)
        local vars = {
          pullRequestId = state.get_pr_id(),
          pullRequestReviewId = state.get_pending_review_id(),
          body = comments[1].body, path = t.path, line = t.line, side = t.diffSide or "RIGHT",
        }
        if t.startLine and t.startLine ~= vim.NIL then
          vars.startLine = t.startLine
          vars.startSide = vars.side
        end
        api_mod.graphql(graphql.MUTATION_ADD_REVIEW_THREAD, vars, function(result, err)
          local thread = ((((result or {}).data or {}).addPullRequestReviewThread or {}).thread or {})
          local first = ((thread.comments or {}).nodes or {})[1]
          if err or not thread.id or not first then return next_step(false, err or "thread not created") end
          first_comment_id = first.id
          next_step(true)
        end)
      end
      for c = 2, #comments do
        steps[#steps + 1] = function(next_step)
          graphql_step(graphql.MUTATION_ADD_REVIEW_COMMENT, {
            pullRequestReviewId = state.get_pending_review_id(), threadId = first_comment_id, body = comments[c].body,
          }, function(result)
            return ((((result or {}).data or {}).addPullRequestReviewComment or {}).comment or {}).id
          end)(next_step)
        end
      end
      steps[#steps + 1] = function(next_step)
        local_store.remove_thread(t.id)
        uploaded = uploaded + 1
        next_step(true)
      end
    end
  end

  for _, reply in ipairs(vim.deepcopy(local_store.replies())) do
    if not reply.agent_only then
      steps[#steps + 1] = function(next_step)
        graphql_step(graphql.MUTATION_ADD_REVIEW_COMMENT, {
          pullRequestReviewId = state.get_pending_review_id(), threadId = reply.first_comment_id, body = reply.body,
        }, function(result)
          return ((((result or {}).data or {}).addPullRequestReviewComment or {}).comment or {}).id
        end)(function(ok, err)
          if ok then
            local_store.remove_reply(reply.id)
            uploaded = uploaded + 1
          end
          next_step(ok, err)
        end)
      end
    end
  end

  if event then
    steps[#steps + 1] = function(next_step)
      local vars = { reviewId = state.get_pending_review_id(), event = event }
      if body and body ~= "" then vars.body = body end
      api_mod.graphql(graphql.MUTATION_SUBMIT_REVIEW, vars, function(result, err)
        local review = ((((result or {}).data or {}).submitPullRequestReview or {}).pullRequestReview or {})
        if err or not review.id then return next_step(false, err or "review not submitted") end
        state.set_pending_review_id("")
        next_step(true)
      end)
    end
  end

  sequence(steps, function(ok, err)
    if ok then
      print(event and string.format("Published %d draft%s as %s", uploaded, uploaded == 1 and "" or "s", event)
        or string.format("Uploaded %d draft%s to a pending review on GitHub", uploaded, uploaded == 1 and "" or "s"))
    else
      vim.notify(string.format("[gh-review] Publishing stopped after %d draft%s: %s. The rest are still drafts; "
        .. ":GHReviewSubmit retries.", uploaded, uploaded == 1 and "" or "s", tostring(err)), vim.log.levels.ERROR)
    end
    require("gh_review").refresh_threads()
    done(ok)
  end)
end

return M
