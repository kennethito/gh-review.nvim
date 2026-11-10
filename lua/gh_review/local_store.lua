-- Review comments for local scopes, saved per branch under the git directory.
--
-- Threads keep the GitHub GraphQL shape, so signs, the thread buffer, preview,
-- and navigation render them unchanged. A comment's pullRequestReview.state is
-- "PENDING" until it has been sent to an agent, then "COMMENTED".

local local_git = require("gh_review.local_git")

local M = {}

local store_path = nil
local data = nil

local function empty()
  return { version = 1, next_id = 1, threads = {}, viewed = {} }
end

function M.path_for(root, branch)
  local dir = local_git.common_dir(root)
  if not dir then return nil end
  return string.format("%s/gh-review/%s.json", dir, (branch:gsub("[^%w%._-]", "__")))
end

function M.load(path)
  store_path = path
  data = empty()
  local file = io.open(path, "r")
  if file then
    local ok, decoded = pcall(vim.json.decode, file:read("*a"))
    file:close()
    if ok and type(decoded) == "table" and decoded.version == 1 then
      data = vim.tbl_extend("force", empty(), decoded)
    else
      vim.notify("[gh-review] Ignoring unreadable comment store " .. path, vim.log.levels.WARN)
    end
  end
  return data
end

-- Write to a temp file and rename it over the store, so a crash never leaves
-- half a file behind.
function M.save()
  if not store_path then return false end
  vim.fn.mkdir(vim.fs.dirname(store_path), "p")
  local tmp = store_path .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then
    vim.notify("[gh-review] Could not write " .. tmp, vim.log.levels.ERROR)
    return false
  end
  file:write(vim.json.encode(data))
  file:close()
  local ok, err = os.rename(tmp, store_path)
  if not ok then
    vim.notify("[gh-review] Could not save comments: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

local function next_id(prefix)
  local id = string.format("%s_%d", prefix, data.next_id)
  data.next_id = data.next_id + 1
  return id
end

local function new_comment(body)
  return {
    id = next_id("local_comment"),
    body = body,
    author = { login = "you" },
    createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    pullRequestReview = { state = "PENDING" },
  }
end

local function find(id)
  for _, t in ipairs(data.threads) do
    if t.id == id then return t end
  end
  return nil
end

-- Threads a scope shows: right-side comments sit on working-tree lines and show
-- in every scope; left-side ones only against the base they were made on.
function M.threads_for(left_base)
  local result = {}
  for _, t in ipairs(data.threads) do
    if t.diffSide ~= "LEFT" or t.left_base == left_base then
      result[#result + 1] = t
    end
  end
  return result
end

-- fields: path, line, startLine, diffSide, anchor (lines), anchor_total, left_base
function M.add_thread(fields, body)
  local t = vim.tbl_extend("force", fields, {
    id = next_id("local_thread"),
    isResolved = false,
    isOutdated = false,
    comments = { nodes = { new_comment(body) } },
  })
  data.threads[#data.threads + 1] = t
  M.save()
  return t
end

function M.reply(thread_id, body)
  local t = find(thread_id)
  if not t then return nil end
  t.comments.nodes[#t.comments.nodes + 1] = new_comment(body)
  M.save()
  return t
end

function M.set_resolved(thread_id, resolved)
  local t = find(thread_id)
  if not t then return nil end
  t.isResolved = resolved
  M.save()
  return t
end

function M.viewed(scope)
  return data.viewed[scope] or {}
end

function M.set_viewed(scope, path, viewed)
  data.viewed[scope] = data.viewed[scope] or {}
  data.viewed[scope][path] = viewed or nil
  M.save()
end

local function is_unsent(t)
  for _, c in ipairs(t.comments.nodes) do
    if c.pullRequestReview.state == "PENDING" then return true end
  end
  return false
end

-- Unresolved threads with a comment not yet sent to an agent.
function M.unsent()
  local result = {}
  for _, t in ipairs(data.threads) do
    if not t.isResolved and is_unsent(t) then
      result[#result + 1] = t
    end
  end
  return result
end

function M.mark_sent(thread_ids)
  local wanted = {}
  for _, id in ipairs(thread_ids) do wanted[id] = true end
  for _, t in ipairs(data.threads) do
    if wanted[t.id] then
      for _, c in ipairs(t.comments.nodes) do
        c.pullRequestReview.state = "COMMENTED"
      end
    end
  end
  M.save()
end

-- Drop every unsent comment, and threads left with none.
function M.discard_unsent()
  local kept = {}
  for _, t in ipairs(data.threads) do
    local comments = {}
    for _, c in ipairs(t.comments.nodes) do
      if c.pullRequestReview.state ~= "PENDING" then
        comments[#comments + 1] = c
      end
    end
    if #comments > 0 then
      t.comments.nodes = comments
      kept[#kept + 1] = t
    end
  end
  data.threads = kept
  M.save()
end

function M.reset()
  store_path = nil
  data = nil
end

return M
