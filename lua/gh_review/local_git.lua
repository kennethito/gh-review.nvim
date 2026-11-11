-- Git queries for local review scopes (branch, uncommitted, last turn).

local M = {}

-- Git's empty tree: the base when a repository has no commits yet.
M.EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

-- Run git in `root`. Returns ok, stdout, stderr; stdout keeps NUL separators.
function M.git(root, args, env)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local obj = vim.system(cmd, { text = true, env = env }):wait()
  return obj.code == 0, obj.stdout or "", obj.stderr or ""
end

local function line(root, args)
  local ok, out = M.git(root, args)
  if not ok then return nil end
  local value = vim.trim(out)
  return value ~= "" and value or nil
end

function M.root(dir)
  return line(dir or vim.fn.getcwd(), { "rev-parse", "--show-toplevel" })
end

-- The checked-out branch, or the short HEAD sha when detached.
function M.branch(root)
  local name = line(root, { "rev-parse", "--abbrev-ref", "HEAD" })
  if name and name ~= "HEAD" then return name end
  return line(root, { "rev-parse", "--short", "HEAD" }) or "HEAD"
end

function M.rev_parse(root, ref)
  return line(root, { "rev-parse", "--verify", "--quiet", ref .. "^{object}" })
end

function M.head(root)
  return M.rev_parse(root, "HEAD")
end

-- The branch scope's default base: origin's default branch, else main or master.
function M.default_base(root)
  local origin_head = line(root, { "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" })
  if origin_head then return origin_head end
  for _, candidate in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if M.rev_parse(root, candidate) then return candidate end
  end
  return nil
end

function M.merge_base(root, base)
  return line(root, { "merge-base", base, "HEAD" })
end

-- A path git keeps under its own directory (index, refs), made absolute.
function M.git_path(root, name)
  local path = line(root, { "rev-parse", "--git-path", name })
  if not path then return nil end
  if path:sub(1, 1) ~= "/" then path = root .. "/" .. path end
  return path
end

function M.common_dir(root)
  local dir = line(root, { "rev-parse", "--git-common-dir" })
  if not dir then return nil end
  if dir:sub(1, 1) ~= "/" then dir = root .. "/" .. dir end
  return dir
end

-- The worktree, untracked files included, as a tree object. Stages into a
-- private copy of the index so the real index is never touched.
function M.snapshot(root)
  local index = vim.fn.tempname()
  local real_index = M.git_path(root, "index")
  local stat = real_index and vim.uv.fs_stat(real_index)
  if stat then
    vim.uv.fs_copyfile(real_index, index)
    -- Keep the index's own timestamp: git trusts cached file stats only for
    -- files older than the index, and a fresh copy would make a same-second,
    -- same-size edit look unchanged.
    vim.uv.fs_utime(index, stat.atime.sec + stat.atime.nsec / 1e9, stat.mtime.sec + stat.mtime.nsec / 1e9)
  end
  local env = { GIT_INDEX_FILE = index }
  local added = M.git(root, { "add", "-A" }, env)
  local ok, tree = false, nil
  if added then
    ok, tree = M.git(root, { "write-tree" }, env)
  end
  os.remove(index)
  if not ok then return nil end
  return vim.trim(tree)
end

-- Commit `tree` on top of HEAD, so the baseline records when it was taken.
function M.commit_tree(root, tree, message)
  local args = { "commit-tree", tree, "-m", message }
  local head = M.head(root)
  if head then
    vim.list_extend(args, { "-p", head })
  end
  return line(root, args)
end

local CHANGE_TYPES = {
  A = "ADDED",
  M = "MODIFIED",
  T = "MODIFIED",
  D = "DELETED",
  R = "RENAMED",
  C = "COPIED",
}

-- Files changed from `base` to `head`, shaped like the PR files GraphQL returns:
-- { path, previousPath?, additions, deletions, changeType }.
function M.changed_files(root, base, head)
  local ok, status_out = M.git(root, { "diff", "-z", "-M", "--name-status", base, head })
  if not ok then return nil end
  local numstat_ok, numstat_out = M.git(root, { "diff", "-z", "-M", "--numstat", base, head })
  if not numstat_ok then return nil end

  local counts = {}
  local fields = vim.split(numstat_out, "\0", { plain = true })
  local i = 1
  while i <= #fields do
    local added, deleted, path = fields[i]:match("^(%S+)\t(%S+)\t(.*)$")
    if not added then break end
    if path == "" then
      -- A rename: the old and new paths follow as their own fields.
      path = fields[i + 2]
      i = i + 3
    else
      i = i + 1
    end
    counts[path] = { tonumber(added) or 0, tonumber(deleted) or 0 }
  end

  local files = {}
  local tokens = vim.split(status_out, "\0", { plain = true })
  i = 1
  while i <= #tokens and tokens[i] ~= "" do
    local letter = tokens[i]:sub(1, 1)
    local file
    if letter == "R" or letter == "C" then
      file = { previousPath = tokens[i + 1], path = tokens[i + 2] }
      i = i + 3
    else
      file = { path = tokens[i + 1] }
      i = i + 2
    end
    local count = counts[file.path] or { 0, 0 }
    file.additions = count[1]
    file.deletions = count[2]
    file.changeType = CHANGE_TYPES[letter] or "MODIFIED"
    files[#files + 1] = file
  end
  return files
end

-- Loose ref file modification time, or the commit time when packed.
function M.ref_time(root, ref)
  local path = M.git_path(root, ref)
  local stat = path and vim.uv.fs_stat(path)
  if stat then return stat.mtime.sec end
  return tonumber(line(root, { "log", "-1", "--format=%ct", ref }) or "")
end

return M
