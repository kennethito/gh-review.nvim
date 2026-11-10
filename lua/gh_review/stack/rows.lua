-- Flatten a built stack graph into display rows, drawing each subtree once.
--
-- A row: { depth, node, edge (call kind from the parent), ref (already drawn
-- above), group (index, on group header rows), kind = "group"|"frame"|"section" }

local M = {}

local function short_module(module)
  return module or "?"
end

function M.frame_label(node)
  if node.kind ~= "def" then return node.name end
  local arity = node.min_arity == node.max_arity and tostring(node.max_arity)
    or string.format("%d..%d", node.min_arity, node.max_arity)
  return string.format("%s.%s/%s", short_module(node.module), node.name, arity)
end

function M.build(result)
  local rows = {}
  local drawn = {}

  local function walk(key, depth, edge)
    local node = result.nodes[key]
    if drawn[key] then
      rows[#rows + 1] = { kind = "frame", depth = depth, node = node, edge = edge, ref = true }
      return
    end
    drawn[key] = true
    rows[#rows + 1] = { kind = "frame", depth = depth, node = node, edge = edge }
    for _, callee in ipairs(result.callees[key] or {}) do
      walk(callee.key, depth + 1, callee.kind)
    end
  end

  local section = nil
  for gi, group in ipairs(result.groups) do
    local title = nil
    if not group.primary then
      title = group.tests and "Reached only from tests" or "Other entry points into changed code"
    end
    if title ~= section then
      if title then rows[#rows + 1] = { kind = "section", title = title } end
      section = title
    end
    local first = group.roots[1]
    rows[#rows + 1] = { kind = "group", group = gi, roots = group.roots, node = first,
      truncated = group.truncated }
    drawn[first.key] = true
    if #group.roots > 1 then
      -- Grouped roots converge on one frame: draw from there, once.
      walk(group.converge, 1, group.converge_edge)
    else
      for _, callee in ipairs(result.callees[first.key] or {}) do
        walk(callee.key, 1, callee.kind)
      end
    end
  end

  if #(result.unreached or {}) > 0 then
    rows[#rows + 1] = { kind = "section", title = "Changed, not reached from an entry point" }
    for _, key in ipairs(result.unreached) do
      if not drawn[key] then walk(key, 0) end
    end
  end
  if #(result.outside or {}) > 0 then
    rows[#rows + 1] = { kind = "section", title = "Changes outside functions" }
    for _, hunk in ipairs(result.outside) do
      rows[#rows + 1] = { kind = "hunk", depth = 0, hunk = hunk }
    end
  end
  if #result.removed > 0 then
    rows[#rows + 1] = { kind = "section", title = "Removed" }
    for _, node in ipairs(result.removed) do
      rows[#rows + 1] = { kind = "frame", depth = 0, node = node }
    end
  end
  if #(result.tests or {}) > 0 then
    rows[#rows + 1] = { kind = "section", title = "Changed tests" }
    for _, f in ipairs(result.tests) do
      rows[#rows + 1] = { kind = "file", depth = 0, file = f }
    end
  end
  if #result.other > 0 then
    rows[#rows + 1] = { kind = "section", title = "Other changed files" }
    for _, f in ipairs(result.other) do
      rows[#rows + 1] = { kind = "file", depth = 0, file = f }
    end
  end
  return rows
end

local MARK = { new = "+", changed = "!", deleted = "-", context = " " }

-- Plain text with a status marker in column 0 (+ new, ! changed, - deleted,
-- > async hop, @ header), for debugging and the colorizer script.
function M.to_text(result)
  local data_by_node = {}
  for _, e in ipairs(result.data_edges or {}) do
    -- No direction: a key in a multi-line pattern match reads like a write.
    data_by_node[e.from] = data_by_node[e.from] or {}
    data_by_node[e.from]["◆ " .. e.key] = true
    data_by_node[e.to] = data_by_node[e.to] or {}
    data_by_node[e.to]["◆ " .. e.key] = true
  end

  local lines = {}
  for _, row in ipairs(M.build(result)) do
    if row.kind == "section" then
      lines[#lines + 1] = "@ " .. row.title
    elseif row.kind == "group" then
      local node = row.node
      local label = M.frame_label(node)
      if #row.roots > 1 then
        label = string.format("entered from %d: %s, …", #row.roots, label)
      end
      lines[#lines + 1] = string.format("@ %s  %s:%d%s", label, node.path, node.line,
        row.truncated and "  ↑ climb stopped here" or "")
    elseif row.kind == "file" then
      lines[#lines + 1] = string.format("  %s (%s)", row.file.path, row.file.changeType)
    elseif row.kind == "hunk" then
      lines[#lines + 1] = string.format("! %s:%d  %s", row.hunk.path, row.hunk.line, row.hunk.text)
    else
      local node = row.node
      local mark = row.edge == "dynamic" and ">" or MARK[node.status] or " "
      local notes = {}
      if row.edge == "dynamic" then notes[#notes + 1] = "⇢" end
      if node.shared then
        notes[#notes + 1] = string.format("⚠ also entered from %d other entr%s", node.shared,
          node.shared == 1 and "y" or "ies")
      end
      local data = vim.tbl_keys(data_by_node[node.key] or {})
      table.sort(data)
      if #data > 3 then
        data = { data[1], data[2], data[3], string.format("◆ +%d", #data - 3) }
      end
      vim.list_extend(notes, data)
      local text = string.format("%s%s%s%s  %s:%d", mark, string.rep("  ", row.depth),
        row.ref and "↪ " or "", M.frame_label(node), node.path, node.jump_line or node.line)
      if row.ref then text = text .. " (see above)" end
      if node.truncated then text = text .. "  ↑ more callers" end
      if #notes > 0 then text = text .. "  " .. table.concat(notes, " ") end
      lines[#lines + 1] = text
    end
  end
  lines[#lines + 1] = string.format("@ %d changed · %d frames visited · %d files parsed · %d ms%s",
    #result.changed, result.stats.visited, result.stats.files, result.stats.ms,
    result.stats.truncated and " · TRUNCATED" or "")
  return lines
end

return M
