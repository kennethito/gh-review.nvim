-- Stack view: builds the stacks for the current review in the background,
-- renders them into the files list, and annotates the diff.

local state = require("gh_review.state")
local config = require("gh_review.config")
local build = require("gh_review.stack.build")
local rows_mod = require("gh_review.stack.rows")

local M = {}

M.ns = vim.api.nvim_create_namespace("gh_review_stack")

local current = { key = nil, result = nil, building = false, progress = 0, error = nil, rows = nil }

local function cache_key()
  local paths = {}
  for _, f in ipairs(state.get_changed_files()) do paths[#paths + 1] = f.path end
  return table.concat({ state.get_scope(), state.get_merge_base_oid(), table.concat(paths, ",") }, "|")
end

-- Why the view can't be built here, or nil.
function M.unavailable()
  if not state.is_local_checkout() then
    return "The stack view needs the head checked out: open the PR with a checkout, or use a local scope."
  end
  if state.get_merge_base_oid() == "" then
    return "Nothing to compare against yet."
  end
  return nil
end

function M.invalidate()
  current = { key = nil, result = nil, building = false, progress = 0, error = nil, rows = nil }
end

function M.result()
  return current.result
end

local function root_dir()
  return state.get_local_info().root or vim.fs.root(0, ".git") or vim.fn.getcwd()
end

-- Build in a coroutine, resumed on the event loop, so the UI keeps running.
-- on_update runs after each step and when done.
function M.ensure(on_update)
  local key = cache_key()
  if current.key == key and (current.result or current.building) then return end
  current = { key = key, result = nil, building = true, progress = 0, error = nil, rows = nil }
  local mine = current

  local opts = vim.deepcopy(config.options.stack)
  opts.notes = nil
  local args = {
    root = root_dir(),
    base = state.get_merge_base_oid(),
    files = vim.deepcopy(state.get_changed_files()),
    opts = opts,
    yield = function()
      mine.progress = mine.progress + 1
      coroutine.yield()
    end,
  }
  local co = coroutine.create(function() return build.build(args) end)
  local function step()
    if current ~= mine then return end
    local ok, result = coroutine.resume(co)
    if not ok then
      mine.building = false
      mine.error = tostring(result)
      if on_update then on_update() end
      return
    end
    if coroutine.status(co) == "dead" then
      mine.building = false
      mine.result = result
      mine.rows = rows_mod.build(result)
      if on_update then on_update() end
      require("gh_review.diff").refresh_signs()
      return
    end
    -- Redraw the progress line now and then, not on every file.
    if on_update and mine.progress % 25 == 0 then on_update() end
    vim.schedule(step)
  end
  vim.schedule(step)
end

-- ------- Rendering into the files list -------

local STATUS_MARK = { new = "+", changed = "~", deleted = "-", context = " " }
local STATUS_HL = {
  new = "GHReviewStackNew", changed = "GHReviewStackChanged",
  deleted = "GHReviewStackDeleted", context = "GHReviewStackContext",
}

local function short_path(path, line)
  return string.format("%s:%d", vim.fs.basename(path), line or 0)
end

local function data_keys(result)
  local by_node = {}
  for _, e in ipairs(result.data_edges or {}) do
    by_node[e.from] = by_node[e.from] or {}
    by_node[e.from][e.key] = true
    by_node[e.to] = by_node[e.to] or {}
    by_node[e.to][e.key] = true
  end
  return by_node
end

-- Header line two, the legend, then one line per row.
-- Returns lines, items (one per line, nil for header lines), highlights.
function M.render()
  local lines = {}
  local items = {}
  local hls = {}

  local function add(text, item, hl)
    lines[#lines + 1] = text
    items[#lines] = item
    if hl then hls[#hls + 1] = { #lines - 1, 0, -1, hl } end
  end
  local function mark(col_start, col_end, hl)
    hls[#hls + 1] = { #lines - 1, col_start, col_end, hl }
  end

  local reason = M.unavailable()
  if reason then
    add("Stacks", nil)
    add(reason, nil, "Comment")
    return lines, items, hls
  end
  if current.error then
    add("Stacks: build failed", nil)
    add(current.error, nil, "ErrorMsg")
    return lines, items, hls
  end
  if not current.result then
    add(string.format("Stacks: building… %d files", current.progress), nil)
    add("+ new  ~ changed  - removed  ⇢ async  ⇉ via behaviour  ◆ data  ⚠ also entered elsewhere", nil, "Comment")
    return lines, items, hls
  end

  local result = current.result
  local groups = 0
  for _, g in ipairs(result.groups) do
    if g.primary then groups = groups + 1 end
  end
  add(string.format("Stacks: %d entr%s · %d changed fns · %d ms%s", groups, groups == 1 and "y" or "ies",
    #result.changed, result.stats.ms,
    result.stats.truncated and " · frame limit hit, some callers not walked" or ""), nil)
  add("+ new  ~ changed  - removed  ⇢ async  ⇉ via behaviour  ◆ data  ⚠ also entered elsewhere", nil, "Comment")

  local keys_by_node = data_keys(result)
  local first_row = {}
  for i, row in ipairs(current.rows) do
    local item = { row = row, index = i }
    if row.kind == "section" then
      add("── " .. row.title .. " ──", item, "GHReviewStackSection")
    elseif row.kind == "group" then
      local label = rows_mod.frame_label(row.node)
      if #row.roots > 1 then
        label = string.format("%s  (+%d more entries)", label, #row.roots - 1)
      end
      -- The fold column shows whether the entry is open (▾) or folded (▸).
      local text = string.format("%s%s  %s", string.rep("  ", row.depth or 0), label,
        short_path(row.node.path, row.node.line))
      -- A root where the climb stopped is not a real entry point.
      if row.truncated then text = text .. "  ↑ climb stopped here" end
      add(text, item, "GHReviewStackEntry")
    elseif row.kind == "file" then
      add(string.format("  %s (%s)", row.file.path, row.file.changeType:lower()), item, "GHReviewStackContext")
    elseif row.kind == "hunk" then
      add(string.format("~ %s  %s", short_path(row.hunk.path, row.hunk.line), row.hunk.text), item,
        "GHReviewStackChanged")
    else
      local node = row.node
      local indent = string.rep("  ", row.depth)
      local edge_mark = row.edge == "dynamic" and "⇢" or row.edge == "dispatch" and "⇉" or nil
      local prefix = (edge_mark or STATUS_MARK[node.status] or " ") .. " "
      local text = indent .. prefix .. (row.ref and "↪ " or "") .. rows_mod.frame_label(node)
        .. "  " .. short_path(node.path, node.jump_line or node.line)
      local notes = {}
      if row.edge == "dispatch" then notes[#notes + 1] = { rows_mod.via(node), "GHReviewStackDynamic" } end
      if node.shared then notes[#notes + 1] = { string.format("⚠ %d", node.shared), "GHReviewStackShared" } end
      local keys = vim.tbl_keys(keys_by_node[node.key] or {})
      table.sort(keys)
      if #keys > 0 then
        local shown = table.concat(vim.list_slice(keys, 1, 2), " ")
        if #keys > 2 then shown = shown .. string.format(" +%d", #keys - 2) end
        notes[#notes + 1] = { "◆ " .. shown, "GHReviewStackData" }
      end
      if node.truncated then notes[#notes + 1] = { "↑ more callers", "GHReviewStackContext" } end
      local starts = {}
      for _, note in ipairs(notes) do
        text = text .. "  "
        starts[#starts + 1] = { #text, #text + #note[1], note[2] }
        text = text .. note[1]
      end
      if not row.ref and node.kind == "def" and first_row[node.key] == nil then
        first_row[node.key] = #lines + 1
      end
      item.target = row.ref and first_row[node.key] or nil
      add(text, item, row.ref and "GHReviewStackContext" or STATUS_HL[node.status])
      if edge_mark then mark(#indent, #indent + #edge_mark, "GHReviewStackDynamic") end
      for _, s in ipairs(starts) do mark(s[1], s[2], s[3]) end
    end
  end
  return lines, items, hls
end

-- ------- Stepping through changed frames -------

-- Changed frames in the order the view draws them, each once, then the
-- changes outside functions: { path, jump_line, clauses? }.
function M.changed_order()
  local order, seen = {}, {}
  for _, row in ipairs(current.rows or {}) do
    local node = row.node
    if row.kind == "frame" and node and node.status ~= "context" and node.status ~= "deleted"
      and not seen[node.key] then
      seen[node.key] = true
      order[#order + 1] = node
    elseif row.kind == "hunk" then
      order[#order + 1] = { path = row.hunk.path, jump_line = row.hunk.line, line = row.hunk.line,
        clauses = { { row.hunk.line, row.hunk.line } } }
    end
  end
  return order
end

local position = 0

-- Open the next (dir = 1) or previous (-1) changed frame.
function M.step(dir)
  local order = M.changed_order()
  if #order == 0 then
    print("No stack built yet: open the stack view in the files list")
    return
  end
  -- Start from the frame under the cursor when the diff shows one.
  local path, line = state.get_diff_path(), vim.fn.line(".")
  for i, node in ipairs(order) do
    if node.path == path then
      for _, clause in ipairs(node.clauses or {}) do
        if line >= clause[1] and line <= clause[2] then position = i end
      end
    end
  end
  position = ((position - 1 + dir) % #order) + 1
  local node = order[position]
  require("gh_review.diff").open(node.path, { line = node.jump_line or node.line })
end

-- ------- Frame notes in the diff -------

function M.place_notes(path, bufnr)
  if bufnr == -1 or vim.fn.bufexists(bufnr) ~= 1 then return end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local result = current.result
  if not result or not config.options.stack.notes then return end

  local keys_by_node = data_keys(result)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for key, node in pairs(result.nodes) do
    if node.path == path and node.kind == "def" and node.line <= line_count then
      local parts = {}
      local callers = result.callers[key] or {}
      local dynamic, dispatch, total = {}, {}, 0
      for caller_key, edge in pairs(callers) do
        total = total + 1
        local caller = result.nodes[caller_key]
        local caller_name = caller and caller.name or caller_key
        if edge.kind == "dynamic" then dynamic[#dynamic + 1] = caller_name end
        if edge.kind == "dispatch" then dispatch[#dispatch + 1] = caller_name end
      end
      table.sort(dynamic)
      table.sort(dispatch)
      if #dynamic > 0 then parts[#parts + 1] = { "⇢ async from " .. table.concat(dynamic, ", "), "GHReviewStackDynamic" } end
      if #dispatch > 0 then
        parts[#parts + 1] = { string.format("⇉ %s from %s", rows_mod.via(node), table.concat(dispatch, ", ")),
          "GHReviewStackDynamic" }
      end
      if node.shared then
        parts[#parts + 1] = { string.format("⚠ also entered from %d other entr%s", node.shared,
          node.shared == 1 and "y" or "ies"), "GHReviewStackShared" }
      end
      local keys = vim.tbl_keys(keys_by_node[key] or {})
      if #keys > 0 then
        table.sort(keys)
        parts[#parts + 1] = { "◆ " .. table.concat(keys, " "), "GHReviewStackData" }
      end
      if total > 1 then
        parts[#parts + 1] = { string.format("%d callers", total), "GHReviewStackContext" }
      end
      if #parts > 0 then
        local virt = {}
        for i, p in ipairs(parts) do
          if i > 1 then virt[#virt + 1] = { "  ", "GHReviewStackContext" } end
          virt[#virt + 1] = p
        end
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, node.line - 1, 0, { virt_text = virt, virt_text_pos = "eol" })
      end
    end
  end
end

return M
