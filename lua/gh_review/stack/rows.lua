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

-- "via Tool": the behaviour a dispatched call reached this function through.
function M.via(node)
  local names = {}
  for _, b in ipairs(node.behaviours or {}) do names[#names + 1] = b:match("[^.]+$") end
  return #names > 0 and ("via " .. table.concat(names, "/")) or "via a module value"
end

-- A module body that references functions with captures (Absinthe's
-- `resolve &Resolver.f/2`, router plugs) wires them up for runtime; one that
-- calls them runs them at compile time.
function M.wires(result, key)
  for _, callee in ipairs(result.callees[key] or {}) do
    if callee.kind == "capture" then return true end
  end
  return false
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

  local function group_row(gi, group, depth)
    rows[#rows + 1] = { kind = "group", group = gi, roots = group.roots, node = group.roots[1],
      truncated = group.truncated, depth = depth or 0 }
  end

  local function draw_group(gi, group)
    local first = group.roots[1]
    group_row(gi, group)
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

  -- Sort the groups into the change itself and the sections after it.
  local main, isolated, bodies, outside_groups, tests = {}, {}, {}, {}, {}
  for gi, group in ipairs(result.groups) do
    local first = group.roots[1]
    if group.tests then
      tests[#tests + 1] = gi
    elseif first.kind == "body" and not M.wires(result, first.key) then
      bodies[#bodies + 1] = gi
    elseif group.primary and #group.roots == 1 and first.status ~= "context"
      and #(result.callees[first.key] or {}) == 0 then
      isolated[#isolated + 1] = gi
    elseif group.primary then
      main[#main + 1] = gi
    else
      outside_groups[#outside_groups + 1] = gi
    end
  end

  for _, gi in ipairs(main) do draw_group(gi, result.groups[gi]) end

  if #isolated > 0 then
    -- Public functions nothing calls statically: called at runtime by name,
    -- from tests only, or not yet.
    rows[#rows + 1] = { kind = "section", title = "Changed, no callers found" }
    for _, gi in ipairs(isolated) do
      local node = result.groups[gi].roots[1]
      drawn[node.key] = true
      rows[#rows + 1] = { kind = "frame", depth = 0, node = node }
    end
  end

  if #outside_groups > 0 then
    -- Existing code reaching the change, summed up where it crosses in: one
    -- row per crossing frame, with the entry points reaching it under it.
    rows[#rows + 1] = { kind = "section", title = "Other entry points into changed code" }
    local by_crossing, order, leftover = {}, {}, {}
    for _, gi in ipairs(outside_groups) do
      local crossed = false
      for key, node in pairs(result.nodes) do
        if node.shared_from and node.shared_from[gi] then
          if not by_crossing[key] then
            by_crossing[key] = {}
            order[#order + 1] = key
          end
          table.insert(by_crossing[key], gi)
          crossed = true
        end
      end
      if not crossed then leftover[#leftover + 1] = gi end
    end
    table.sort(order, function(a, b)
      if #by_crossing[a] ~= #by_crossing[b] then return #by_crossing[a] > #by_crossing[b] end
      return a < b
    end)
    local shown = {}
    for _, key in ipairs(order) do
      rows[#rows + 1] = { kind = "frame", depth = 0, node = result.nodes[key], ref = drawn[key] or nil }
      for _, gi in ipairs(by_crossing[key]) do
        local group = result.groups[gi]
        group_row(gi, group, 1)
        if not shown[gi] then
          -- Its own path down, which may hold changed code only it reaches;
          -- anything already drawn shows as a reference.
          shown[gi] = true
          local first = group.roots[1]
          drawn[first.key] = true
          if #group.roots > 1 then
            walk(group.converge, 2, group.converge_edge)
          else
            for _, callee in ipairs(result.callees[first.key] or {}) do walk(callee.key, 2, callee.kind) end
          end
        end
      end
    end
    for _, gi in ipairs(leftover) do draw_group(gi, result.groups[gi]) end
  end

  if #bodies > 0 then
    rows[#rows + 1] = { kind = "section", title = "Compile time (module bodies)" }
    for _, gi in ipairs(bodies) do draw_group(gi, result.groups[gi]) end
  end

  if #tests > 0 then
    rows[#rows + 1] = { kind = "section", title = "Reached only from tests" }
    for _, gi in ipairs(tests) do draw_group(gi, result.groups[gi]) end
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
      lines[#lines + 1] = string.format("@ %s%s  %s:%d%s", string.rep("  ", row.depth or 0), label, node.path,
        node.line, row.truncated and "  ↑ climb stopped here" or "")
    elseif row.kind == "file" then
      lines[#lines + 1] = string.format("  %s (%s)", row.file.path, row.file.changeType)
    elseif row.kind == "hunk" then
      lines[#lines + 1] = string.format("! %s:%d  %s", row.hunk.path, row.hunk.line, row.hunk.text)
    else
      local node = row.node
      local async = row.edge == "dynamic" or row.edge == "dispatch"
      local mark = async and ">" or MARK[node.status] or " "
      local notes = {}
      if row.edge == "dynamic" then notes[#notes + 1] = "⇢" end
      if row.edge == "dispatch" then notes[#notes + 1] = "⇉ " .. M.via(node) end
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
