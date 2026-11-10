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

return M
