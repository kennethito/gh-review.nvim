-- The "last turn" baseline: the worktree as it was when a coding agent last
-- started working in it.
--
-- Inside herdr, a watcher polls `herdr agent list` and snapshots the worktree
-- when its agents go from resting (idle/done) to working, as herdr-reviewr does.
-- herdr only subscribes status events per pane, so following agents as they
-- come and go would need resubscribing; a one-second poll keeps this simple at
-- about the precision herdr-reviewr itself has. Without herdr, the baseline
-- falls back to the newest of herdr-reviewr's or reviewr.nvim's refs, or a
-- manual :GHReviewTurn mark.

local local_git = require("gh_review.local_git")

local M = {}

M.REF = "refs/worktree/gh-review/turn-base"
M.POLL_MS = 1000

-- Snapshot the worktree now as the turn baseline.
function M.mark(root)
  local tree = local_git.snapshot(root)
  if not tree then return nil end
  local commit = local_git.commit_tree(root, tree, "gh-review turn baseline")
  if not commit then return nil end
  local ok = local_git.git(root, { "update-ref", M.REF, commit })
  return ok and commit or nil
end

local function reviewr_slug(root)
  return (root:gsub("[^%w%._-]", "_"))
end

-- The newest baseline any source left: { oid, source, time } or nil.
function M.baseline(root)
  local candidates = {
    { ref = M.REF, source = "gh-review" },
    { ref = "refs/worktree/reviewr/turn-base", source = "herdr-reviewr" },
  }
  local _, out = local_git.git(root,
    { "for-each-ref", "--format=%(refname)", "refs/reviewr/" .. reviewr_slug(root) .. "/" })
  for _, ref in ipairs(vim.split(out, "\n", { trimempty = true })) do
    candidates[#candidates + 1] = { ref = ref, source = "reviewr.nvim" }
  end

  local best = nil
  for _, c in ipairs(candidates) do
    local oid = local_git.rev_parse(root, c.ref)
    if oid then
      local time = local_git.ref_time(root, c.ref) or 0
      if not best or time > best.time then
        best = { oid = oid, source = c.source, time = time }
      end
    end
  end
  return best
end

-- ------- herdr watcher -------

-- Fold agent statuses into the worktree's state: any working agent means
-- working; all idle/done means resting; blocked or unknown holds the last state.
function M.fold(statuses)
  local held = false
  for _, status in ipairs(statuses) do
    if status == "working" then return "working" end
    if status ~= "idle" and status ~= "done" then held = true end
  end
  return held and "neither" or "resting"
end

-- Turn edges from successive folded states. The first sample starts nothing,
-- since we did not see what came before it.
function M.new_tracker()
  local tracker = { prev_resting = false, worked = false }
  function tracker.observe(worktree_state)
    local started = worktree_state == "working" and tracker.prev_resting
    local ended = tracker.worked and worktree_state == "resting"
    tracker.prev_resting = worktree_state == "resting"
    if worktree_state == "working" then
      tracker.worked = true
    elseif worktree_state == "resting" then
      tracker.worked = false
    end
    return started, ended
  end
  return tracker
end

local watcher = nil

-- Run a command asynchronously; tests replace this.
function M.run(cmd, callback)
  vim.system(cmd, { text = true }, function(obj)
    vim.schedule(function() callback(obj.code, obj.stdout or "") end)
  end)
end

-- The git top level of each agent cwd, resolved once.
local toplevels = {}
local function toplevel(cwd)
  if toplevels[cwd] == nil then
    toplevels[cwd] = local_git.root(cwd) or false
  end
  return toplevels[cwd]
end

-- Statuses of the agents working in `root`, from `herdr agent list` output.
function M.member_statuses(json_text, root)
  local ok, decoded = pcall(vim.json.decode, json_text)
  if not ok or type(decoded) ~= "table" then return nil end
  local agents = ((decoded.result or {}).agents) or {}
  local statuses = {}
  for _, agent in ipairs(agents) do
    local cwd = agent.cwd
    if type(agent.agent) == "string" and type(cwd) == "string" and cwd:sub(1, 1) == "/"
      and toplevel(cwd) == root then
      statuses[#statuses + 1] = agent.agent_status
    end
  end
  return statuses
end

local function poll()
  if not watcher or watcher.polling then return end
  watcher.polling = true
  local current = watcher
  M.run({ "herdr", "agent", "list" }, function(code, stdout)
    current.polling = false
    if watcher ~= current then return end
    local statuses = code == 0 and M.member_statuses(stdout, watcher.root) or nil
    if not statuses then
      -- herdr unreachable: nobody saw the gap, so the next status starts nothing.
      watcher.tracker.prev_resting = false
      return
    end
    local started, ended = watcher.tracker.observe(M.fold(statuses))
    if started then
      M.mark(watcher.root)
    end
    if ended and watcher.on_turn_end then
      watcher.on_turn_end()
    end
  end)
end

-- Exposed so tests can drive polls by hand.
M.poll = poll

function M.herdr_available()
  return (vim.env.HERDR_SOCKET_PATH or "") ~= "" and vim.fn.executable("herdr") == 1
end

-- Watch agents in `root` while Neovim runs. Restarting for another root
-- replaces the previous watcher.
function M.start_watcher(root, on_turn_end)
  if not M.herdr_available() then return false end
  if watcher and watcher.root == root then
    watcher.on_turn_end = on_turn_end
    return true
  end
  M.stop_watcher()
  local timer = vim.uv.new_timer()
  watcher = { root = root, timer = timer, tracker = M.new_tracker(), on_turn_end = on_turn_end }
  timer:start(M.POLL_MS, M.POLL_MS, vim.schedule_wrap(poll))
  return true
end

function M.stop_watcher()
  if watcher then
    watcher.timer:stop()
    watcher.timer:close()
    watcher = nil
  end
end

function M.watching()
  return watcher and watcher.root or nil
end

return M
