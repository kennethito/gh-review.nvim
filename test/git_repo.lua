-- Temporary git repositories for local-scope tests.

local M = {}

function M.git(dir, args)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local obj = vim.system(cmd, { text = true }):wait()
  if obj.code ~= 0 then
    error("git " .. table.concat(args, " ") .. " failed: " .. (obj.stderr or ""), 2)
  end
  return vim.trim(obj.stdout or "")
end

function M.write(dir, path, lines)
  vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. path), "p")
  vim.fn.writefile(lines, dir .. "/" .. path)
end

-- A repo whose `feature` branch, checked out, differs from `main` by:
--   a.txt modified, b.txt deleted, c.txt renamed to d.txt (committed),
--   a.txt edited again and e.txt created untracked (uncommitted).
function M.feature_repo()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  M.git(dir, { "init", "-q", "-b", "main" })
  M.git(dir, { "config", "user.email", "test@example.com" })
  M.git(dir, { "config", "user.name", "Test" })
  M.git(dir, { "config", "commit.gpgsign", "false" })
  M.write(dir, "a.txt", { "one", "two", "three", "four", "five" })
  M.write(dir, "b.txt", { "bee" })
  M.write(dir, "c.txt", { "sea", "shells", "by", "the", "shore" })
  M.git(dir, { "add", "-A" })
  M.git(dir, { "commit", "-q", "-m", "base" })

  M.git(dir, { "checkout", "-q", "-b", "feature" })
  M.write(dir, "a.txt", { "one", "TWO", "three", "four", "five" })
  M.git(dir, { "rm", "-q", "b.txt" })
  M.git(dir, { "mv", "c.txt", "d.txt" })
  M.git(dir, { "add", "-A" })
  M.git(dir, { "commit", "-q", "-m", "feature work" })

  M.write(dir, "a.txt", { "one", "TWO", "three", "FOUR", "five" })
  M.write(dir, "e.txt", { "new file" })
  return dir
end

-- Wait for an async condition (git content fetches) or fail.
function M.wait_for(cond, what)
  if not vim.wait(5000, cond, 20) then
    error("timed out waiting for " .. what, 2)
  end
end

-- A Lua project on `main` plus uncommitted changes, shaped for the stack view:
--   entry.start -> core.middle -> core.leaf (changed) -> core.fresh (new) -> core.recur
--   other.legacy -> core.helper (changed) -> core.fresh   (an existing caller)
--   jobs.tick, jobs2.tick2 ⇢ core.deferred (new, dynamic)   core.old removed   core.lonely uncalled
--   core.ping <-> core.pong (new, only call each other)   M.VERSION = 2 (a change outside functions)
-- Returns the repo dir and the base commit.
function M.stack_repo()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  M.git(dir, { "init", "-q", "-b", "main" })
  M.git(dir, { "config", "user.email", "t@example.com" })
  M.git(dir, { "config", "user.name", "T" })
  M.git(dir, { "config", "commit.gpgsign", "false" })

  M.write(dir, "lua/app/entry.lua", {
    'local core = require("app.core")',
    "local M = {}",
    "function M.start(x)",
    "  return core.middle(x)",
    "end",
    "return M",
  })
  M.write(dir, "lua/app/core.lua", {
    "local M = {}",
    "function M.middle(x)",
    "  return M.leaf(x)",
    "end",
    "function M.leaf(x)",
    "  return x",
    "end",
    "function M.old(x)",
    "  return x",
    "end",
    "function M.helper(x)",
    "  return x",
    "end",
    "return M",
  })
  -- An existing caller of a helper the change refactors (is_big_play? -> big_play_stats).
  M.write(dir, "lua/app/other.lua", {
    'local core = require("app.core")',
    "local M = {}",
    "function M.legacy(x)",
    "  return core.helper(x)",
    "end",
    "return M",
  })
  M.write(dir, "lua/app/jobs.lua", {
    'local core = require("app.core")',
    "local M = {}",
    "function M.tick()",
    '  apply(core, "deferred", { 1 })',
    "end",
    "return M",
  })
  M.write(dir, "lua/app/jobs2.lua", {
    'local core = require("app.core")',
    "local M = {}",
    "function M.tick2()",
    '  apply(core, "deferred", { 2 })',
    "end",
    "return M",
  })
  M.git(dir, { "add", "-A" })
  M.git(dir, { "commit", "-q", "-m", "base" })
  local base = M.git(dir, { "rev-parse", "HEAD" })

  -- The change: leaf changes and gains a new helper, old goes, deferred is new
  -- and only reached dynamically, recur calls itself, lonely has no callers.
  M.write(dir, "lua/app/core.lua", {
    "local M = {}",
    "M.VERSION = 2",
    "function M.middle(x)",
    "  return M.leaf(x)",
    "end",
    "function M.leaf(x)",
    '  x["leaf_total"] = M.fresh(x)',
    "  return M.extra(x)",
    "end",
    "function M.extra(x)",
    "  return x",
    "end",
    "function M.fresh(x)",
    "  return M.recur(x)",
    "end",
    "function M.recur(x)",
    "  return M.recur(x)",
    "end",
    "function M.deferred(n)",
    '  return n["leaf_total"]',
    "end",
    "function M.lonely()",
    "end",
    "function M.helper(x)",
    "  return M.fresh(x)",
    "end",
    "function M.ping(n)",
    "  return M.pong(n)",
    "end",
    "function M.pong(n)",
    "  return M.ping(n)",
    "end",
    "return M",
  })
  return dir, base
end

return M
