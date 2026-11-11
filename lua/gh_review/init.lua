-- Top-level orchestration for gh-review.nvim.

local api_mod = require("gh_review.api")
local graphql = require("gh_review.graphql")
local state = require("gh_review.state")
local files = require("gh_review.files")
local diff = require("gh_review.diff")
local thread = require("gh_review.thread")
local config = require("gh_review.config")
local url = require("gh_review.url")
local remotes = require("gh_review.remotes")
local local_git = require("gh_review.local_git")
local local_store = require("gh_review.local_store")
local turn = require("gh_review.turn")
local agent = require("gh_review.agent")

local M = {}

M.LOCAL_SCOPES = { branch = true, uncommitted = true, turn = true }

local function setup_push_tracking(local_branch)
  local head_owner = state.get_head_repo_owner()
  local head_name = state.get_head_repo_name()
  local head_branch = state.get_head_ref()
  local base_remote = state.get_remote()

  -- Push to the remote that already points at the head repo, if any: the base
  -- remote for a same-repo PR, or (in a clone of a fork) the fork's own remote.
  local remote = remotes.find(remotes.list(), state.get_host(), head_owner, head_name)
  if not remote then
    -- Fork PR -- ensure a remote exists for the fork.
    remote = head_owner
    local obj = vim.system({ "git", "remote", "get-url", remote }, { text = true }):wait()
    if obj.code ~= 0 then
      -- Add a remote at the base remote's URL with the repo swapped for the fork,
      -- so it keeps that URL's protocol, host, port, and SSH user.
      local base_obj = vim.system({ "git", "remote", "get-url", base_remote }, { text = true }):wait()
      local base_url = vim.trim(base_obj.stdout or "")
      local fork_url = url.fork_url(base_url, state.get_owner(), state.get_name(), head_owner, head_name)
      if not fork_url then
        vim.notify(string.format("[gh-review] Could not derive a URL for fork %s from remote %s",
          remote, base_remote), vim.log.levels.WARN)
        return
      end
      local add_obj = vim.system({ "git", "remote", "add", remote, fork_url }, { text = true }):wait()
      if add_obj.code ~= 0 then
        vim.notify(string.format("[gh-review] Could not add remote for fork %s", remote), vim.log.levels.WARN)
        return
      end
    end
  end

  local cfg1 = vim.system({ "git", "config",
    "branch." .. local_branch .. ".remote", remote }, { text = true }):wait()
  if cfg1.code ~= 0 then
    vim.notify("[gh-review] Could not configure push tracking", vim.log.levels.WARN)
    return
  end
  local cfg2 = vim.system({ "git", "config",
    "branch." .. local_branch .. ".merge", "refs/heads/" .. head_branch }, { text = true }):wait()
  if cfg2.code ~= 0 then
    vim.notify("[gh-review] Could not configure push tracking", vim.log.levels.WARN)
  end
end

local function fetch_merge_base(callback)
  local owner = state.get_owner()
  local name = state.get_name()
  local base = state.get_base_ref()
  local head = state.get_head_ref()
  local remote = state.get_remote()

  -- Try local git merge-base first
  local obj = remote ~= "" and vim.system({ "git", "merge-base",
    remote .. "/" .. base, remote .. "/" .. head }, { text = true }):wait()

  if obj and obj.code == 0 and vim.trim(obj.stdout or "") ~= "" then
    state.set_merge_base_oid(vim.trim(obj.stdout))
    callback()
    return
  end

  -- Fall back to REST compare endpoint
  local endpoint = string.format("/repos/%s/%s/compare/%s...%s", owner, name, base, head)
  api_mod.run_async({ "api", endpoint }, function(stdout, stderr)
    if stderr == "" or stderr == nil then
      local ok, parsed = pcall(vim.json.decode, stdout)
      if ok then
        local commit = (parsed or {}).merge_base_commit or {}
        if commit.sha then
          state.set_merge_base_oid(commit.sha)
        end
      end
    end
    -- Use base OID as fallback if merge base is still empty
    if state.get_merge_base_oid() == "" then
      vim.notify("[gh-review] Could not determine merge base; diff may be inaccurate", vim.log.levels.WARN)
      state.set_merge_base_oid(state.get_base_oid())
    end
    callback()
  end)
end

-- Watch agents in this worktree so the last-turn scope has a baseline even
-- before a review is opened.
local function start_turn_watcher(root)
  if not config.options.turn.watch or not root then return end
  turn.start_watcher(root, function()
    if config.options.turn.refresh_on_end and state.get_scope() == "turn"
      and state.get_local_info().root == root then
      M.reload_local()
    end
  end)
end

-- Configure the plugin. Entirely optional -- commands register automatically.
function M.setup(opts)
  config.setup(opts)
  start_turn_watcher(local_git.root())
end

-- A baseline's time: the clock time today, with the date on any other day.
function M.format_time(time)
  if os.date("%Y-%m-%d", time) == os.date("%Y-%m-%d") then
    return os.date("%H:%M", time)
  end
  return os.date("%b %d %H:%M", time)
end

-- The base a local scope diffs against: { oid, label, note } or nil, err.
local function local_base(root, scope, arg)
  if scope == "uncommitted" then
    return { oid = local_git.head(root) or local_git.EMPTY_TREE, label = "HEAD" }
  end
  if scope == "branch" then
    local base = (arg and arg ~= "") and arg or local_git.default_base(root)
    if not base then
      return nil, "No base branch found; pass one, e.g. :GHReview branch main"
    end
    local oid = local_git.merge_base(root, base)
    if not oid then
      return nil, "No merge base between HEAD and " .. base
    end
    return { oid = oid, label = base }
  end
  local baseline = turn.baseline(root)
  if not baseline then
    return { oid = nil, label = "last turn",
      note = "No turn baseline yet: it is taken when an agent starts working, or run :GHReviewTurn." }
  end
  return { oid = baseline.oid, label = "last turn",
    note = string.format("Turn since %s (%s)", M.format_time(baseline.time), baseline.source) }
end

-- The lines a file holds now, read once per call site.
local function file_lines(root, path, cache)
  if cache[path] == nil then
    local ok, lines = pcall(vim.fn.readfile, root .. "/" .. path)
    cache[path] = ok and lines or false
  end
  return cache[path]
end

local function anchor_at(lines, anchor, start)
  for i, text in ipairs(anchor) do
    if lines[start + i - 1] ~= text then return false end
  end
  return true
end

-- Move right-side comments with their code: once an agent edits a file, a saved
-- line number points at whatever moved there. Each thread goes to the place
-- nearest its old line where its saved lines still match, or is marked
-- outdated when they are gone. The store keeps the original positions.
function M.reanchor(root, threads)
  local cache = {}
  local result = {}
  for _, t in ipairs(threads) do
    local anchor = t.anchor
    if t.diffSide ~= "LEFT" and type(anchor) == "table" and #anchor > 0 then
      local lines = file_lines(root, t.path, cache)
      local first = t.startLine or t.line
      if lines and not anchor_at(lines, anchor, first) then
        local best = nil
        for start = 1, #lines - #anchor + 1 do
          if anchor_at(lines, anchor, start) and (not best or math.abs(start - first) < math.abs(best - first)) then
            best = start
          end
        end
        t = vim.deepcopy(t)
        if best then
          local shift = best - first
          t.line = t.line + shift
          if t.startLine then t.startLine = t.startLine + shift end
        else
          t.isOutdated = true
        end
      end
    end
    result[#result + 1] = t
  end
  return result
end

-- Build a local scope's state: files from git, threads from the branch's store.
local function load_local(scope, arg)
  local root = local_git.root()
  if not root then
    return nil, "Not in a git repository"
  end
  local base, err = local_base(root, scope, arg)
  if not base then return nil, err end

  local files_list = {}
  if base.oid then
    local snapshot = local_git.snapshot(root)
    if not snapshot then return nil, "Could not snapshot the working tree" end
    files_list = local_git.changed_files(root, base.oid, snapshot)
    if not files_list then return nil, "git diff failed against " .. base.label end
  end

  local branch = local_git.branch(root)
  local store_path = local_store.path_for(root, branch)
  if not store_path then return nil, "Could not find the git directory" end
  local_store.load(store_path)

  state.set_local({
    scope = scope,
    files = files_list,
    base_oid = base.oid or "",
    base_label = base.label,
    branch = branch,
    root = root,
    arg = arg,
    note = base.note,
    viewed = local_store.viewed(scope),
  })
  state.set_threads(M.reanchor(root, local_store.threads_for(base.oid)))
  start_turn_watcher(root)
  return true
end

-- Re-read a local scope's files and comments in place. The diff, the thread
-- buffer, and the cursor stay where they are, so this is safe to run while the
-- user is mid-comment (a turn ending). A moved base needs the diff reopened,
-- which only happens when no comment is being written.
function M.reload_local()
  if not state.is_local_mode() then return end
  require("gh_review.stack.view").invalidate()
  local scope, info = state.get_scope(), state.get_local_info()
  local old_base = state.get_merge_base_oid()
  local files_bufnr, left, right = state.get_files_bufnr(), state.get_left_bufnr(), state.get_right_bufnr()
  local open_path = state.get_diff_path()

  local ok, err = load_local(scope, info.arg)
  if not ok then
    vim.notify("[gh-review] " .. err, vim.log.levels.ERROR)
    return
  end
  state.set_files_bufnr(files_bufnr)
  state.set_left_bufnr(left)
  state.set_right_bufnr(right)
  state.set_diff_path(open_path)

  if open_path ~= "" and state.get_merge_base_oid() ~= old_base and state.get_thread_bufnr() == -1 then
    M.set_scope(scope, info.arg)
    return
  end
  if right ~= -1 and vim.fn.bufexists(right) == 1 then
    pcall(vim.cmd, "checktime " .. right)
  end
  diff.refresh_signs()
  if files.mode() == "stack" then
    local view = require("gh_review.stack.view")
    if not view.unavailable() then view.ensure(function() files.rerender() end) end
  end
  files.rerender()
end

-- Open or switch to a scope: "pr" (optionally with a PR number or url), or a
-- local scope. Switching keeps the open file when the new scope has it.
function M.set_scope(scope, arg)
  if scope == "pr" then
    local reopen = state.is_local_mode() or state.get_pr_id() == ""
    if reopen then
      M.close_silently()
      M.open(arg or "")
    end
    return
  end
  if not M.LOCAL_SCOPES[scope] then
    vim.notify("[gh-review] Unknown scope " .. tostring(scope)
      .. " (expected pr, branch, uncommitted, or turn)", vim.log.levels.ERROR)
    return
  end

  require("gh_review.stack.view").invalidate()
  local open_path = state.get_diff_path()
  if scope == "branch" then
    if arg == nil or arg == "" then
      arg = M.last_branch_base
    else
      M.last_branch_base = arg
    end
  end
  thread.close_thread_buffer()
  diff.close_diff()
  if not state.is_local_mode() then
    -- Leaving a PR: drop its GitHub state so nothing posts there by mistake.
    local files_bufnr = state.get_files_bufnr()
    state.reset()
    state.set_files_bufnr(files_bufnr)
  end

  local ok, err = load_local(scope, arg)
  if not ok then
    vim.notify("[gh-review] " .. err, vim.log.levels.ERROR)
    return
  end
  files.open()
  if files.mode() == "stack" then
    -- Rebuild for the new scope; the view redraws as the build progresses.
    local view = require("gh_review.stack.view")
    if not view.unavailable() then view.ensure(function() files.rerender() end) end
  end
  for _, f in ipairs(state.get_changed_files()) do
    if f.path == open_path then
      diff.open(open_path)
      break
    end
  end
end

-- Open a review. A PR number or url (or nothing, for the current branch's PR)
-- opens PR scope; "branch [base]", "uncommitted" or "turn" open a local scope.
function M.open(pr_number_str)
  pr_number_str = vim.trim(pr_number_str or "")

  local first, rest = pr_number_str:match("^(%S+)%s*(.*)$")
  if first == "pr" then
    pr_number_str = rest
  elseif first and M.LOCAL_SCOPES[first] then
    M.set_scope(first, rest)
    return
  end

  if vim.fn.executable("gh") ~= 1 then
    vim.notify("[gh-review] `gh` CLI not found. Install it from https://cli.github.com", vim.log.levels.ERROR)
    return
  end

  local pr_number
  local url_owner = ""
  local url_name = ""
  local url_host = ""

  if pr_number_str == "" then
    print("Detecting PR for current branch...")
    local obj = vim.system(
      { "gh", "pr", "view", "--json", "number", "-q", ".number" },
      { text = true }):wait()
    if obj.code ~= 0 or vim.trim(obj.stdout or "") == "" then
      vim.notify("[gh-review] No PR found for the current branch", vim.log.levels.ERROR)
      return
    end
    pr_number = tonumber(vim.trim(obj.stdout))
  else
    -- Accept a PR URL from any host, or a plain number.
    local arg = url.parse_pr_arg(pr_number_str)
    url_host = arg.host
    url_owner = arg.owner
    url_name = arg.name
    pr_number = arg.number
  end

  if not pr_number or pr_number <= 0 then
    vim.notify("[gh-review] Invalid PR number or URL: " .. pr_number_str, vim.log.levels.ERROR)
    return
  end

  -- Determine repo and whether checkout is possible.
  local should_checkout = false
  if url_owner ~= "" then
    local remote = remotes.find(remotes.list(), url_host, url_owner, url_name)
    state.set_repo_info(url_owner, url_name, url_host, remote)
    should_checkout = remote ~= nil
  else
    if not state.get_repo_info() then return end
    should_checkout = true
  end

  state.set_local_checkout(should_checkout)

  print(string.format("Loading PR #%d...", pr_number))

  local owner = state.get_owner()
  local name = state.get_name()

  local vars = {
    owner = owner,
    name = name,
    number = pr_number,
  }
  api_mod.graphql(graphql.QUERY_PR_DETAILS, vars, function(result)
    local pr = (((result or {}).data or {}).repository or {}).pullRequest
    if not pr then
      vim.notify("[gh-review] Failed to load PR details", vim.log.levels.ERROR)
      return
    end

    state.set_pr(result)

    local thread_nodes = ((pr.reviewThreads or {}).nodes or {})
    require("gh_review.pr_drafts").attach(thread_nodes)

    local function load_ui()
      fetch_merge_base(function()
        files.open()
        print(string.format("PR #%d loaded: %s", state.get_pr_number(), state.get_pr_title()))
      end)
    end

    if should_checkout then
      local local_branch = state.get_head_ref()
      local obj = vim.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }):wait()
      local current_branch = vim.trim(obj.stdout or "")
      if current_branch == local_branch then
        load_ui()
        return
      end

      vim.ui.select({ "Yes", "No" }, {
        prompt = string.format("Check out branch %s?", local_branch),
      }, function(choice)
        if choice ~= "Yes" then
          should_checkout = false
          state.set_local_checkout(false)
          load_ui()
          return
        end

        local fetch_ref = string.format("pull/%d/head", pr_number)
        api_mod.run_cmd_async({ "git", "fetch", state.get_remote(), fetch_ref }, function(_, fe, fetch_exit)
          if fetch_exit ~= 0 then
            vim.notify("[gh-review] Could not fetch PR branch: " .. vim.trim(fe), vim.log.levels.WARN)
            state.set_local_checkout(false)
            load_ui()
          else
            api_mod.run_cmd_async({ "git", "checkout", "-B", local_branch, "FETCH_HEAD" }, function(_, ce, co_exit)
              if co_exit == 0 then
                setup_push_tracking(local_branch)
                vim.notify(string.format("[gh-review] Checked out branch %s", local_branch))
              else
                vim.notify("[gh-review] Could not check out PR branch: " .. vim.trim(ce), vim.log.levels.WARN)
                state.set_local_checkout(false)
              end
              load_ui()
            end)
          end
        end)
      end)
    else
      load_ui()
    end
  end)
end

-- Toggle the files list.
function M.toggle_files()
  files.toggle()
end

-- Start a pending review.
function M.start_review()
  if state.is_local_mode() then
    print("Local comments are saved as you write them; no review to start")
    return
  end
  if state.is_review_active() then
    print("A pending review is already active")
    return
  end

  if state.get_pr_id() == "" then
    vim.notify("[gh-review] No PR loaded. Use :GHReview {number|url} first.", vim.log.levels.ERROR)
    return
  end

  print("Starting review...")
  local start_vars = { pullRequestId = state.get_pr_id() }
  api_mod.graphql(graphql.MUTATION_START_REVIEW, start_vars, function(result)
    local review = ((((result or {}).data or {}).addPullRequestReview or {}).pullRequestReview or {})
    if review and review.id then
      state.set_pending_review_id(review.id)
      print("Review started. Comments will be held as pending until you submit.")
    else
      vim.notify("[gh-review] Failed to start review", vim.log.levels.ERROR)
    end
  end)
end

-- Submit a review. In a local scope this sends the comments to the agent.
-- With PR drafts, it publishes them all as one review, or uploads them to a
-- pending review without publishing.
function M.submit_review()
  if state.is_local_mode() then
    M.send()
    return
  end
  if state.get_pr_id() == "" then
    vim.notify("[gh-review] No PR loaded. Use :GHReview {number|url} first.", vim.log.levels.ERROR)
    return
  end
  local drafts = require("gh_review.pr_drafts")
  local count = drafts.count()
  if count > 0 then
    local choices = { "Comment", "Approve", "Request changes", "Upload to GitHub as a pending review (not published)" }
    local events = { "COMMENT", "APPROVE", "REQUEST_CHANGES", false }
    vim.ui.select(choices, {
      prompt = string.format("Publish %d draft%s as:", count, count == 1 and "" or "s"),
    }, function(choice, idx)
      if not choice then return end
      local event = events[idx]
      if event == false then
        drafts.publish(nil)
      elseif event == "APPROVE" then
        drafts.publish(event, "")
      else
        vim.ui.input({ prompt = "Review body (optional): " }, function(body)
          drafts.publish(event, body or "")
        end)
      end
    end)
    return
  end

  local event_map = { Comment = "COMMENT", Approve = "APPROVE", ["Request changes"] = "REQUEST_CHANGES" }
  vim.ui.select({ "Comment", "Approve", "Request changes" }, {
    prompt = "Submit review as:",
  }, function(choice)
    if not choice then return end
    local event = event_map[choice]

    local function do_submit(body)
      body = body or ""
      print("Submitting review...")

      if state.is_review_active() then
        local vars = {
          reviewId = state.get_pending_review_id(),
          event = event,
        }
        if body ~= "" then vars.body = body end

        api_mod.graphql(graphql.MUTATION_SUBMIT_REVIEW, vars, function(result)
          local review = ((((result or {}).data or {}).submitPullRequestReview or {}).pullRequestReview or {})
          if review and review.id then
            state.set_pending_review_id("")
            print("Review submitted as " .. event)
            M.refresh_threads()
          else
            vim.notify("[gh-review] Failed to submit review", vim.log.levels.ERROR)
          end
        end)
      else
        local vars = {
          pullRequestId = state.get_pr_id(),
          event = event,
        }
        if body ~= "" then vars.body = body end

        api_mod.graphql(graphql.MUTATION_CREATE_AND_SUBMIT_REVIEW, vars, function(result)
          local review = ((((result or {}).data or {}).addPullRequestReview or {}).pullRequestReview or {})
          if review and review.id then
            print("Review submitted as " .. event)
            M.refresh_threads()
          else
            vim.notify("[gh-review] Failed to submit review", vim.log.levels.ERROR)
          end
        end)
      end
    end

    if event == "COMMENT" or event == "REQUEST_CHANGES" then
      vim.ui.input({ prompt = "Review body (optional): " }, function(body)
        do_submit(body or "")
      end)
    else
      do_submit("")
    end
  end)
end

-- Discard the pending review.
function M.discard_review()
  local drafts = require("gh_review.pr_drafts")
  if not state.is_local_mode() and drafts.count() > 0 then
    vim.ui.select({ "Yes", "No" }, {
      prompt = string.format("Delete %d local draft%s? (Nothing on GitHub changes.)", drafts.count(),
        drafts.count() == 1 and "" or "s"),
    }, function(choice)
      if choice ~= "Yes" then return end
      require("gh_review.local_store").clear_drafts()
      drafts.refresh()
      print("Drafts deleted")
    end)
    return
  end
  if state.is_local_mode() then
    vim.ui.select({ "Yes", "No" }, {
      prompt = "Delete every comment not yet sent to the agent?",
    }, function(choice)
      if choice ~= "Yes" then return end
      local_store.discard_unsent()
      M.refresh_threads()
    end)
    return
  end
  if not state.is_review_active() then
    vim.notify("[gh-review] No pending review to discard.", vim.log.levels.ERROR)
    return
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = "Discard pending review and all its comments?",
  }, function(choice)
    if choice ~= "Yes" then return end

    print("Discarding review...")
    local vars = { pullRequestReviewId = state.get_pending_review_id() }
    api_mod.graphql(graphql.MUTATION_DELETE_REVIEW, vars, function(result)
      local review = ((((result or {}).data or {}).deletePullRequestReview or {}).pullRequestReview or {})
      if review and review.id then
        state.set_pending_review_id("")
        M.refresh_threads()
        print("Pending review discarded")
      else
        vim.notify("[gh-review] Failed to discard review", vim.log.levels.ERROR)
      end
    end)
  end)
end

-- Refresh threads from GitHub and update signs/files list. A local scope
-- re-reads its files from git and its comments from the store.
function M.refresh_threads()
  if state.is_local_mode() then
    M.reload_local()
    return
  end
  if state.get_pr_id() == "" then return end

  local refresh_vars = {
    owner = state.get_owner(),
    name = state.get_name(),
    number = state.get_pr_number(),
  }
  api_mod.graphql(graphql.QUERY_REVIEW_THREADS, refresh_vars, function(result, err)
    -- On error, keep the threads we already have; api.graphql has already
    -- notified. Without this guard a failed refresh would set_threads({}) and
    -- print "Threads refreshed", wiping the list on any transient error.
    if err then return end
    local pr = (((result or {}).data or {}).repository or {}).pullRequest
    local thread_nodes = ((pr or {}).reviewThreads or {}).nodes or {}
    require("gh_review.pr_drafts").attach(thread_nodes)
    diff.refresh_signs()
    files.rerender()
    print("Threads refreshed")
  end)
end

-- Threads to send: unsent local comments, or every unresolved PR thread.
local function threads_to_send()
  if state.is_local_mode() then
    return M.reanchor(state.get_local_info().root, local_store.unsent())
  end
  local result = {}
  for _, t in pairs(state.get_threads()) do
    if not state.get(t, "isResolved", false) then
      result[#result + 1] = t
    end
  end
  return result
end

local function send_text(threads)
  local header
  if not state.is_local_mode() then
    header = string.format("PR: https://%s/%s/%s/pull/%d",
      state.get_host(), state.get_owner(), state.get_name(), state.get_pr_number())
  end
  local root = state.get_local_info().root or local_git.root()
  -- PR threads are quoted from the working tree only when it is the PR's head.
  local quote_root = state.is_local_checkout() and root or nil
  return agent.message(threads, { root = quote_root, header = header }), root
end

-- Send comments to the running coding agent. Local comments are marked sent
-- once they reach one; PR threads stay as they are on GitHub.
function M.send()
  local threads = threads_to_send()
  if #threads == 0 then
    print(state.is_local_mode() and "No unsent comments" or "No unresolved threads")
    return
  end
  local text, root = send_text(threads)
  agent.send(text, root, function(sent, where)
    if not sent then
      if where ~= "cancelled" then
        print("No agent found; review copied to the clipboard")
      end
      return
    end
    if state.is_local_mode() then
      local ids = {}
      for _, t in ipairs(threads) do ids[#ids + 1] = t.id end
      local_store.mark_sent(ids)
      state.set_threads(M.reanchor(state.get_local_info().root,
        local_store.threads_for(state.get_merge_base_oid())))
      diff.refresh_signs()
      files.rerender()
    end
    print(string.format("Sent %d comment thread%s to %s", #threads, #threads == 1 and "" or "s", where))
  end)
end

-- Copy the comments M.send would send.
function M.copy()
  local threads = threads_to_send()
  if #threads == 0 then
    print("Nothing to copy")
    return
  end
  agent.copy((send_text(threads)))
  print(string.format("Copied %d comment thread%s", #threads, #threads == 1 and "" or "s"))
end

-- Mark the last-turn baseline now, for agents gh-review can't watch.
function M.mark_turn()
  local root = local_git.root()
  if not root then
    vim.notify("[gh-review] Not in a git repository", vim.log.levels.ERROR)
    return
  end
  if turn.mark(root) then
    print("Turn baseline marked")
    if state.get_scope() == "turn" then M.refresh_threads() end
  else
    vim.notify("[gh-review] Could not snapshot the working tree", vim.log.levels.ERROR)
  end
end

-- Statusline component for integration with statusline plugins.
function M.statusline()
  if state.is_local_mode() then
    local parts = { state.get_scope() }
    local unsent = #local_store.unsent()
    if unsent > 0 then parts[#parts + 1] = string.format("%d unsent", unsent) end
    local count = 0
    for _ in pairs(state.get_threads()) do count = count + 1 end
    if count > 0 then
      parts[#parts + 1] = string.format("%d thread%s", count, count > 1 and "s" or "")
    end
    return table.concat(parts, " · ")
  end
  if state.get_pr_id() == "" then
    return ""
  end
  local parts = { string.format("PR #%d", state.get_pr_number()) }
  local draft_count = require("gh_review.pr_drafts").count()
  if draft_count > 0 then
    parts[#parts + 1] = string.format("%d draft%s", draft_count, draft_count == 1 and "" or "s")
  end
  if state.is_review_active() then
    parts[#parts + 1] = "reviewing"
  end
  local thread_count = 0
  for _ in pairs(state.get_threads()) do
    thread_count = thread_count + 1
  end
  if thread_count > 0 then
    parts[#parts + 1] = string.format("%d thread%s", thread_count, thread_count > 1 and "s" or "")
  end
  return table.concat(parts, " · ")
end

-- Close all review buffers and reset state.
function M.close()
  M.close_silently()
  print("Review closed")
end

function M.close_silently()
  -- Teardown has to reach the buffer wipe and state.reset() even if a step
  -- fails, or the plugin is left half-open with no way back short of
  -- restarting Neovim. Report a failure rather than swallowing it.
  local function step(what, fn)
    local ok, err = pcall(fn)
    if not ok then
      vim.notify(string.format("[gh-review] %s failed while closing: %s", what, err),
        vim.log.levels.WARN)
    end
  end

  step("thread teardown", thread.close_thread_buffer)
  step("diff teardown", diff.close_diff)
  step("files list teardown", files.close)

  -- Wipe any remaining gh-review buffers
  for _, bufinfo in ipairs(vim.fn.getbufinfo()) do
    if bufinfo.name:match("^gh%-review://") then
      vim.cmd("silent! bwipeout! " .. bufinfo.bufnr)
    end
  end

  state.reset()
  local_store.reset()
  files.reset_mode()
  require("gh_review.stack.view").invalidate()
end

return M
