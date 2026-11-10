-- `?` help: the configured keys of each surface and the plugin's commands,
-- in a floating window. Built from the same ACTIONS tables that set the
-- keymaps, so it always shows what is actually mapped.

local config = require("gh_review.config")

local M = {}

local SURFACES = {
  { "files", "Files list", "gh_review.files" },
  { "diff", "Diff", "gh_review.diff" },
  { "thread", "Comment buffer", "gh_review.thread" },
}

local MODE_NAMES = { x = "visual", i = "insert" }

-- One section per surface: { key, description } for every mapped action.
local function surface_lines(surface, title, module)
  local actions = require(module).ACTIONS or {}
  local configured = config.options.keymaps[surface]
  local entries = {}
  for action, bindings in pairs(actions) do
    local lhs = configured[action]
    if type(lhs) == "string" then
      local modes, desc = {}, nil
      for _, binding in ipairs(bindings) do
        desc = desc or binding[3]
        if MODE_NAMES[binding[1]] then modes[#modes + 1] = MODE_NAMES[binding[1]] end
      end
      if #modes > 0 then desc = string.format("%s (also %s)", desc, table.concat(modes, ", ")) end
      entries[#entries + 1] = { lhs, desc }
    end
  end
  table.sort(entries, function(a, b) return a[2] < b[2] end)
  local lines = { title }
  for _, e in ipairs(entries) do
    lines[#lines + 1] = string.format("  %-10s %s", e[1], e[2])
  end
  return lines
end

local function command_lines()
  local commands = {}
  for name, cmd in pairs(vim.api.nvim_get_commands({ builtin = false })) do
    -- Lua-callback commands carry their text in `desc`; `definition` is empty.
    if name:find("^GHReview") then
      local desc = (cmd.desc and cmd.desc ~= "") and cmd.desc or cmd.definition or ""
      commands[#commands + 1] = { name, desc }
    end
  end
  table.sort(commands, function(a, b) return a[1] < b[1] end)
  local lines = { "Commands" }
  for _, c in ipairs(commands) do
    lines[#lines + 1] = string.format("  :%-16s %s", c[1], c[2])
  end
  return lines
end

function M.lines()
  local lines = {}
  for _, s in ipairs(SURFACES) do
    vim.list_extend(lines, surface_lines(s[1], s[2], s[3]))
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, command_lines())
  return lines
end

local open_win = nil

function M.close()
  if open_win and vim.api.nvim_win_is_valid(open_win) then
    vim.api.nvim_win_close(open_win, true)
  end
  open_win = nil
end

function M.is_open()
  return open_win ~= nil and vim.api.nvim_win_is_valid(open_win)
end

function M.open()
  if M.is_open() then
    M.close()
    return
  end
  local lines = M.lines()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  open_win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " gh-review help · q to close ",
    title_pos = "center",
  })

  local ns = vim.api.nvim_create_namespace("gh_review_help")
  for i, l in ipairs(lines) do
    if l ~= "" and not l:find("^ ") then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #l, hl_group = "Title" })
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, M.close, { buffer = buf, nowait = true, silent = true })
  end
end

return M
