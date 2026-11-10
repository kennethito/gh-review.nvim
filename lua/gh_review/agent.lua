-- Send review comments to a running coding agent.
--
-- The text follows reviewr.nvim's format so agents (and their skills) read both
-- the same way. Delivery tries herdr, then reviewr.nvim's transport (Neovim
-- terminals, tmux, Rex, WezTerm), then the clipboard.

local state = require("gh_review.state")

local M = {}

-- Bracketed-paste markers: the agent takes the whole review as one paste
-- instead of submitting at the first newline.
local PASTE_START = "\27[200~"
local PASTE_END = "\27[201~"

-- herdr passes the text as one argument; stay well under Linux's per-argument limit.
local MAX_HERDR_BYTES = 100 * 1024

-- Run a command synchronously; tests replace this.
function M.run(cmd)
  local obj = vim.system(cmd, { text = true }):wait()
  return obj.code, obj.stdout or "", obj.stderr or ""
end

local function comments_of(t)
  return state.get(state.get(t, "comments", {}), "nodes", {})
end

-- Up to three lines a thread covers, read from the file on disk.
local function quote_from_disk(root, t)
  local line = state.get(t, "line", nil)
  if type(line) ~= "number" or line <= 0 or state.get(t, "diffSide", "RIGHT") == "LEFT" then
    return nil, 0
  end
  local start_line = state.get(t, "startLine", nil) or line
  local file = io.open(root .. "/" .. state.get(t, "path", ""), "r")
  if not file then return nil, 0 end
  local lines, n = {}, 0
  for text in file:lines() do
    n = n + 1
    if n >= start_line and n <= line then
      lines[#lines + 1] = text
    end
    if n > line then break end
  end
  file:close()
  return lines, line - start_line + 1
end

local function dedent(lines)
  local indent = math.huge
  for _, l in ipairs(lines) do
    if l:match("%S") then
      indent = math.min(indent, #l:match("^%s*"))
    end
  end
  if indent == math.huge then indent = 0 end
  local out = {}
  for i, l in ipairs(lines) do out[i] = l:sub(indent + 1) end
  return out
end

local function indent_body(body)
  return (body:gsub("\r", ""):gsub("\n", "\n   "))
end

-- One numbered item per thread, ordered by path then line.
-- opts.root: repo root, for quoting PR threads from disk.
-- opts.header: an extra line under the title (e.g. the PR url).
function M.message(threads, opts)
  opts = opts or {}
  local sorted = vim.list_slice(threads)
  table.sort(sorted, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    return (state.get(a, "line", 0) or 0) < (state.get(b, "line", 0) or 0)
  end)

  local out = { "Code review comments from my editor:" }
  if opts.header then out[#out + 1] = opts.header end
  out[#out + 1] = ""

  for i, t in ipairs(sorted) do
    local line = state.get(t, "line", nil) or state.get(t, "originalLine", 0)
    local start_line = state.get(t, "startLine", nil) or state.get(t, "originalStartLine", nil)
    local range = (start_line and start_line ~= line) and string.format("%d-%d", start_line, line)
      or tostring(line)
    local base = state.get(t, "diffSide", "RIGHT") == "LEFT" and " (base)" or ""
    out[#out + 1] = string.format("%d. %s:%s%s", i, t.path, range, base)

    local quoted, total = t.anchor, t.anchor_total or (t.anchor and #t.anchor) or 0
    if not quoted and opts.root then
      quoted, total = quote_from_disk(opts.root, t)
    end
    if quoted and #quoted > 0 then
      for _, l in ipairs(dedent(vim.list_slice(quoted, 1, 3))) do
        out[#out + 1] = "   > " .. l
      end
      if total > 3 then out[#out + 1] = "   > ..." end
    end

    for j, c in ipairs(comments_of(t)) do
      local body = indent_body(state.get(c, "body", ""))
      if j == 1 then
        out[#out + 1] = "   Comment: " .. body
      else
        local author = state.get(state.get(c, "author", {}), "login", "")
        out[#out + 1] = string.format("   Reply (%s): %s", author, body)
      end
    end
    out[#out + 1] = ""
  end

  out[#out + 1] = "Make the requested changes and answer any questions. Reply per item."
  return table.concat(out, "\n")
end

-- ------- herdr -------

local function inside(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

-- Agents in our herdr workspace other than this pane, best match first.
-- Returns candidates and the number skipped because they sit at a prompt.
function M.herdr_candidates(json_text, root)
  local ok, decoded = pcall(vim.json.decode, json_text)
  if not ok or type(decoded) ~= "table" then return {}, 0 end
  local me = vim.env.HERDR_PANE_ID
  local workspace = vim.env.HERDR_WORKSPACE_ID
  local candidates, blocked = {}, 0
  for _, a in ipairs(((decoded.result or {}).agents) or {}) do
    if type(a.agent) == "string" and a.pane_id ~= me
      and (workspace == nil or workspace == "" or a.workspace_id == workspace) then
      if a.agent_status == "blocked" then
        -- A permission prompt would swallow the paste.
        blocked = blocked + 1
      else
        local here = type(a.cwd) == "string" and inside(a.cwd, root)
        candidates[#candidates + 1] = {
          pane = a.pane_id,
          label = string.format("%s · %s · %s", a.agent,
            a.terminal_title_stripped or a.pane_id, a.agent_status or "?"),
          here = here,
        }
      end
    end
  end
  table.sort(candidates, function(x, y) return x.here and not y.here end)
  return candidates, blocked
end

local function herdr_paste(pane, text)
  local body = text:gsub(vim.pesc(PASTE_END), "")
  local code, _, err = M.run({ "herdr", "pane", "send-text", pane, PASTE_START .. body .. PASTE_END })
  if code ~= 0 then return false, vim.trim(err) end
  M.run({ "herdr", "agent", "focus", pane })
  return true
end

local function send_herdr(text, root, cb)
  local code, stdout = M.run({ "herdr", "agent", "list" })
  if code ~= 0 then return false end
  local candidates, blocked = M.herdr_candidates(stdout, root)
  if #candidates == 0 then
    if blocked > 0 then
      vim.notify("[gh-review] The agent is at a prompt; answer it, then send again. Copied to clipboard.",
        vim.log.levels.WARN)
      M.copy(text)
      cb(false)
      return true
    end
    return false
  end
  if #text > MAX_HERDR_BYTES then return false end

  local function deliver(c)
    local ok, err = herdr_paste(c.pane, text)
    if not ok then
      vim.notify("[gh-review] herdr send failed: " .. (err or ""), vim.log.levels.ERROR)
      cb(false)
      return
    end
    vim.g.gh_review_agent_pane = c.pane
    cb(true, "herdr " .. c.label)
  end

  for _, c in ipairs(candidates) do
    if c.pane == vim.g.gh_review_agent_pane then
      deliver(c)
      return true
    end
  end
  if #candidates == 1 then
    deliver(candidates[1])
    return true
  end
  vim.ui.select(candidates, {
    prompt = "Send review to:",
    format_item = function(c) return c.label end,
  }, function(choice)
    if choice then deliver(choice) else cb(false, "cancelled") end
  end)
  return true
end

-- ------- delivery -------

function M.copy(text)
  -- The + register errors without a clipboard provider (e.g. over SSH); the
  -- unnamed register still holds the text then.
  pcall(vim.fn.setreg, "+", text)
  vim.fn.setreg('"', text)
end

function M.herdr_available()
  return (vim.env.HERDR_SOCKET_PATH or "") ~= "" and vim.fn.executable("herdr") == 1
end

-- Deliver `text`; cb(sent, where) runs once, sent=false when nothing reached an agent.
function M.send(text, root, cb)
  if M.herdr_available() and send_herdr(text, root, cb) then
    return
  end

  -- Only hand over when reviewr sees an agent: with none, it would write an
  -- inbox file into the working tree (.reviewr/inbox/) or copy, and neither
  -- reaches an agent.
  local ok, transport = pcall(require, "reviewr.transport")
  if ok and type(transport.send) == "function" and type(transport.detect) == "function"
    and #transport.detect(root) > 0 then
    transport.send(text, { repo = root, mode = "queue" }, function(via, label)
      local delivered = via ~= nil and via ~= "clipboard" and via ~= "filesystem-inbox"
      cb(delivered, label or via)
    end)
    return
  end

  M.copy(text)
  cb(false, "clipboard")
end

return M
