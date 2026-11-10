-- Stack view generator: from a diff to call stacks rooted at entry points.
--
-- 1. Changed functions: parse each changed file at its base and head, and map
--    the diff's hunks onto definitions (new, changed, deleted).
-- 2. Callers: walk upward from every changed function. Candidate files must
--    contain the function name and the module's last segment (`rg`), which keeps
--    the search to a handful of files in a large repo.
-- 3. Roots: frames with no callers. Roots whose callees are identical (five cron
--    workers casting the same job) fold into one group.
-- 4. Annotations: dynamic edges, changed code reached from several root groups
--    (shared), and string keys written in added lines of one changed function
--    and read in added lines of another (data edges).

local M = {}

local ADAPTERS = {
  require("gh_review.stack.lang.elixir"),
  require("gh_review.stack.lang.lua"),
}

local function adapter_for(path)
  local ext = path:match("%.([%w]+)$")
  for _, adapter in ipairs(ADAPTERS) do
    if ext and adapter.extensions[ext] then return adapter end
  end
  return nil
end

M.timing = { run_ms = 0, parse_ms = 0, runs = 0, parses = 0 }

local function run(cmd, cwd)
  local t = vim.uv.hrtime()
  local obj = vim.system(cmd, { text = true, cwd = cwd }):wait()
  M.timing.run_ms = M.timing.run_ms + (vim.uv.hrtime() - t) / 1e6
  M.timing.runs = M.timing.runs + 1
  return obj.code, obj.stdout or ""
end

-- Parsed files, reused across builds while unchanged on disk.
local analysis_cache = {}

local function analyze_file(root, path)
  local full = root .. "/" .. path
  local stat = vim.uv.fs_stat(full)
  if not stat then return nil end
  local cached = analysis_cache[full]
  if cached and cached.mtime == stat.mtime.sec and cached.size == stat.size then
    return cached.result
  end
  local adapter = adapter_for(path)
  if not adapter then return nil end
  local file = io.open(full, "r")
  if not file then return nil end
  local source = file:read("*a")
  file:close()
  local t = vim.uv.hrtime()
  local result = adapter.analyze(source, path)
  M.timing.parse_ms = M.timing.parse_ms + (vim.uv.hrtime() - t) / 1e6
  M.timing.parses = M.timing.parses + 1
  if result then
    result.adapter = adapter
    result.path = path
  end
  analysis_cache[full] = { mtime = stat.mtime.sec, size = stat.size, result = result }
  return result
end

function M.clear_cache()
  analysis_cache = {}
end

-- Head line ranges a diff touches, from vim.diff indices. A pure deletion
-- touches the line it sits after and the one before it.
local function changed_ranges(hunks)
  local ranges = {}
  for _, h in ipairs(hunks) do
    local b_start, b_count = h[3], h[4]
    if b_count > 0 then
      ranges[#ranges + 1] = { b_start, b_start + b_count - 1, added = true }
    else
      ranges[#ranges + 1] = { b_start, b_start + 1, added = false }
    end
  end
  return ranges
end

local function first_touch(clauses, ranges)
  local best = nil
  for _, clause in ipairs(clauses) do
    for _, r in ipairs(ranges) do
      local first, last = math.max(clause[1], r[1]), math.min(clause[2], r[2])
      if first <= last and (not best or first < best) then best = first end
    end
  end
  return best
end

-- Lines added inside a def's clauses: the only places data keys are read from.
local function added_lines(clauses, ranges, lines)
  local result = {}
  for _, r in ipairs(ranges) do
    if r.added then
      for n = r[1], r[2] do
        for _, clause in ipairs(clauses) do
          if n >= clause[1] and n <= clause[2] then
            result[#result + 1] = lines[n]
            break
          end
        end
      end
    end
  end
  return result
end

local function by_name(defs)
  local result = {}
  for _, d in ipairs(defs) do
    local name = d.module .. "." .. d.name
    result[name] = result[name] or {}
    table.insert(result[name], d)
  end
  return result
end

local function overlapping(def, candidates)
  for _, other in ipairs(candidates or {}) do
    if other.min_arity <= def.max_arity and def.min_arity <= other.max_arity then return other end
  end
  return nil
end

-- A def's own source, all clauses, for comparing base and head.
local function def_text(def, lines)
  local parts = {}
  for _, clause in ipairs(def.clauses) do
    for n = clause[1], clause[2] do parts[#parts + 1] = lines[n] or "" end
  end
  return table.concat(parts, "\n")
end

local function node_from_def(def, path, status)
  return {
    key = def.key, module = def.module, name = def.name, min_arity = def.min_arity,
    max_arity = def.max_arity, path = path, line = def.clauses[1][1], jump_line = def.clauses[1][1],
    clauses = def.clauses, status = status, kind = "def",
  }
end

-- Step 1: the changed, new, and deleted functions of the diff.
local function changed_functions(ctx)
  for _, f in ipairs(ctx.files) do
    local adapter = adapter_for(f.path)
    if not adapter or not adapter.available() then
      ctx.other[#ctx.other + 1] = f
    elseif not ctx.opts.tests and adapter.is_test(f.path) then
      ctx.tests[#ctx.tests + 1] = f
    else
      local head_source = ""
      local head = nil
      if f.changeType ~= "DELETED" then
        head = analyze_file(ctx.root, f.path)
        local fh = io.open(ctx.root .. "/" .. f.path, "r")
        if fh then head_source = fh:read("*a"); fh:close() end
      end
      local base_source = ""
      if f.changeType ~= "ADDED" and ctx.base ~= "" then
        local code, out = run({ "git", "show", ctx.base .. ":" .. (f.previousPath or f.path) }, ctx.root)
        if code == 0 then base_source = out end
      end
      local base = base_source ~= "" and adapter.analyze(base_source, f.previousPath or f.path) or { defs = {} }
      local hunks = vim.diff(base_source, head_source, { result_type = "indices" }) or {}
      local ranges = changed_ranges(hunks)
      local head_lines = vim.split(head_source, "\n", { plain = true })
      local base_lines = vim.split(base_source, "\n", { plain = true })

      local base_defs = by_name(base.defs)
      local head_defs = by_name(head and head.defs or {})
      for _, def in ipairs(head and head.defs or {}) do
        local previous = overlapping(def, base_defs[def.module .. "." .. def.name])
        -- Changed means the def's own text differs: diff hunks often spill onto
        -- a neighbour's `end` or blank line when code is inserted next to it.
        local differs = previous and def_text(previous, base_lines) ~= def_text(def, head_lines)
        local touched = differs and first_touch(def.clauses, ranges)
        if not previous or differs then
          local node = node_from_def(def, f.path, previous and "changed" or "new")
          node.jump_line = touched or node.line
          node.added = added_lines(def.clauses, ranges, head_lines)
          ctx.nodes[node.key] = node
          ctx.changed[#ctx.changed + 1] = node
        end
      end
      local removed_clauses = {}
      for _, def in ipairs(base.defs) do
        if not overlapping(def, head_defs[def.module .. "." .. def.name]) then
          local node = node_from_def(def, f.path, "deleted")
          ctx.removed[#ctx.removed + 1] = node
          vim.list_extend(removed_clauses, def.clauses)
        end
      end

      -- Hunks no changed function covers (aliases, attributes, docs, module
      -- setup): listed on their own so the view accounts for the whole diff.
      local covered = {}
      for _, node in ipairs(ctx.changed) do
        if node.path == f.path then vim.list_extend(covered, node.clauses) end
      end
      local function overlaps(first, last, clauses)
        for _, c in ipairs(clauses) do
          if first <= c[2] and c[1] <= last then return true end
        end
        return false
      end
      for _, h in ipairs(hunks) do
        local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
        local first, last = b_start, b_count > 0 and (b_start + b_count - 1) or b_start
        local in_removed = b_count == 0 and overlaps(a_start, a_start + math.max(a_count, 1) - 1, removed_clauses)
        if not overlaps(first, last, covered) and not in_removed then
          local text = nil
          for n = first, last do
            if b_count > 0 and head_lines[n] and head_lines[n]:find("%S") then text = vim.trim(head_lines[n]) break end
          end
          if not text then
            for n = a_start, a_start + a_count - 1 do
              if base_lines[n] and base_lines[n]:find("%S") then text = "- " .. vim.trim(base_lines[n]) break end
            end
          end
          ctx.outside[#ctx.outside + 1] = { path = f.path, line = math.max(first, 1), text = text or "" }
        end
      end
      ctx.yield()
    end
  end
end

-- `rg` for many words at once: { [word] = { [path] = true } }.
local function files_with_words(ctx, words, globs, paths)
  local result = {}
  if #words == 0 then return result end
  local cmd = { "rg", "-o", "-w", "-F", "--no-line-number", "--with-filename", "--no-heading" }
  vim.list_extend(cmd, globs)
  for _, word in ipairs(words) do vim.list_extend(cmd, { "-e", word }) end
  vim.list_extend(cmd, { "--" })
  vim.list_extend(cmd, paths)
  local _, out = run(cmd, ctx.root)
  for line in out:gmatch("[^\n]+") do
    local path, word = line:match("^(.*):([^:]+)$")
    if path then
      path = path:gsub("^%./", "")
      result[word] = result[word] or {}
      result[word][path] = true
    end
  end
  return result
end

-- Files that may call each node of a walk level: its own file, plus files with
-- both its name and its module's last segment. Two `rg` runs per level.
local function candidate_files(ctx, nodes)
  local names, segments, globs, seen_globs = {}, {}, {}, {}
  local seen_name, seen_segment = {}, {}
  for _, node in ipairs(nodes) do
    local adapter = adapter_for(node.path)
    local name, segment = adapter.search_terms(node)
    node.search = { name, segment }
    if not seen_name[name] then seen_name[name] = true; names[#names + 1] = name end
    if not seen_segment[segment] then seen_segment[segment] = true; segments[#segments + 1] = segment end
    for ext in pairs(adapter.extensions) do
      if not seen_globs[ext] then
        seen_globs[ext] = true
        vim.list_extend(globs, { "-g", "*." .. ext })
      end
    end
  end

  local by_name = files_with_words(ctx, names, globs, ctx.search_roots)
  local union, in_union = {}, {}
  for _, paths in pairs(by_name) do
    for path in pairs(paths) do
      if not in_union[path] then in_union[path] = true; union[#union + 1] = path end
    end
  end
  local by_segment = files_with_words(ctx, segments, {}, union)

  local result = {}
  for _, node in ipairs(nodes) do
    local name, segment = node.search[1], node.search[2]
    local paths = { node.path }
    local adapter = adapter_for(node.path)
    for path in pairs(by_name[name] or {}) do
      if path ~= node.path and (by_segment[segment] or {})[path]
        and (ctx.opts.tests or not adapter.is_test(path)) then
        paths[#paths + 1] = path
      end
    end
    table.sort(paths)
    result[node.key] = paths
  end
  return result
end

local function ensure_caller(ctx, file, from_key)
  if ctx.nodes[from_key] then return ctx.nodes[from_key] end
  for _, def in ipairs(file.defs) do
    if def.key == from_key then
      local node = node_from_def(def, file.path, "context")
      ctx.nodes[from_key] = node
      return node
    end
  end
  local frame = file.frames[from_key]
  if frame then
    local node = { key = from_key, module = frame.module, name = from_key, path = file.path,
      line = frame.line, jump_line = frame.line, status = "context", kind = frame.kind }
    ctx.nodes[from_key] = node
    return node
  end
  return nil
end

-- Step 2: walk callers upward, one level at a time.
local function walk_callers(ctx)
  local frontier, visited, queued = {}, {}, {}
  -- Unchanged frames climbed since the nearest changed one. Feature entry
  -- points sit a hop or two above changed code; shared helpers drag in every
  -- caller in the codebase, so the climb stops after a few unchanged frames.
  local hops = {}
  for _, node in ipairs(ctx.changed) do
    frontier[#frontier + 1] = node
    hops[node.key] = 0
  end

  local depth = 0
  while #frontier > 0 do
    local level = {}
    for _, node in ipairs(frontier) do
      if not visited[node.key] and node.kind == "def" then
        visited[node.key] = true
        level[#level + 1] = node
      end
    end
    ctx.stats.visited = ctx.stats.visited + #level
    if ctx.stats.visited > ctx.opts.max_frames then
      ctx.stats.truncated = true
      for _, node in ipairs(level) do node.truncated = true end
      return
    end

    local candidates = candidate_files(ctx, level)
    local next_level = {}
    for _, node in ipairs(level) do
      for _, path in ipairs(candidates[node.key]) do
        local file = analyze_file(ctx.root, path)
        if file then
          for _, call in ipairs(file.calls) do
            if call.from and call.from ~= node.key and file.adapter.reaches(call, node, file) then
              local caller = ensure_caller(ctx, file, call.from)
              if caller then
                ctx.callers[node.key] = ctx.callers[node.key] or {}
                if not ctx.callers[node.key][caller.key] then
                  ctx.callers[node.key][caller.key] = { kind = call.kind, line = call.line, path = path }
                end
                if not visited[caller.key] then
                  local caller_hops = caller.status == "context" and hops[node.key] + 1 or 0
                  hops[caller.key] = math.min(hops[caller.key] or math.huge, caller_hops)
                  if depth + 1 <= ctx.opts.max_depth and hops[caller.key] < ctx.opts.max_context_hops then
                    if not queued[caller.key] then
                      queued[caller.key] = true
                      next_level[#next_level + 1] = caller
                    end
                    -- Walked after all, by a shorter path.
                    caller.truncated = nil
                  elseif not queued[caller.key] then
                    caller.truncated = true
                  end
                end
              end
            end
          end
        end
        ctx.stats.files = ctx.stats.files + 1
        ctx.yield()
      end
    end
    frontier = next_level
    depth = depth + 1
  end
end

local function count_changed(ctx, key, seen)
  if seen[key] then return 0 end
  seen[key] = true
  local n = ctx.nodes[key].status ~= "context" and 1 or 0
  for _, callee in ipairs(ctx.callees[key] or {}) do
    n = n + count_changed(ctx, callee.key, seen)
  end
  return n
end

-- Steps 3 and 4: roots, root groups, reachability, shared and data edges.
local function assemble(ctx)
  ctx.callees = {}
  for callee, callers in pairs(ctx.callers) do
    for caller, edge in pairs(callers) do
      ctx.callees[caller] = ctx.callees[caller] or {}
      table.insert(ctx.callees[caller], { key = callee, kind = edge.kind, line = edge.line })
    end
  end
  for _, list in pairs(ctx.callees) do
    table.sort(list, function(a, b) return a.line < b.line end)
  end

  -- Roots: frames nobody calls. Follow each unchanged root's single-callee
  -- chain down to where it converges (the first changed or branching frame):
  -- five cron workers whose handle_info/process_tick end in the same changed
  -- job fold into one group, drawn from that frame.
  -- Returns the frame and the kind of the edge that led to it.
  local function converge(key)
    local seen, edge = {}, nil
    while not seen[key] do
      seen[key] = true
      local node, callees = ctx.nodes[key], ctx.callees[key] or {}
      if node.status ~= "context" or #callees ~= 1 then return key, edge end
      key, edge = callees[1].key, callees[1].kind
    end
    return key, edge
  end

  local groups, by_signature = {}, {}
  local keys = vim.tbl_keys(ctx.nodes)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local node = ctx.nodes[key]
    if not ctx.callers[key] or next(ctx.callers[key]) == nil then
      local target, edge = converge(key)
      local signature = (node.kind == "test" and "test:" or "") .. target
      local group = by_signature[signature]
      if not group then
        group = { roots = {}, tests = node.kind == "test", converge = target, converge_edge = edge }
        by_signature[signature] = group
        groups[#groups + 1] = group
      end
      table.insert(group.roots, node)
      if node.truncated then group.truncated = true end
    end
  end

  -- Reachability: which groups reach each frame.
  local reached_by = {}
  for gi, group in ipairs(groups) do
    local seen = {}
    local function mark(key)
      if seen[key] then return end
      seen[key] = true
      reached_by[key] = reached_by[key] or {}
      reached_by[key][gi] = true
      for _, c in ipairs(ctx.callees[key] or {}) do mark(c.key) end
    end
    for _, root in ipairs(group.roots) do mark(root.key) end
  end

  -- The feature: the largest groups by changed code reached, taken greedily;
  -- a group joins unless at least half of what it reaches is already covered.
  -- The rest are other entry points: alternate callers of the same code, or
  -- existing callers of refactored helpers.
  local function reach_of(gi)
    local result = {}
    for key, by in pairs(reached_by) do
      if by[gi] and ctx.nodes[key].status ~= "context" then result[#result + 1] = key end
    end
    return result
  end
  local order = {}
  for gi, group in ipairs(groups) do
    group.changed = count_changed(ctx, group.roots[1].key, {})
    group.primary = false
    order[#order + 1] = gi
  end
  table.sort(order, function(a, b)
    if groups[a].changed ~= groups[b].changed then return groups[a].changed > groups[b].changed end
    return groups[a].roots[1].key < groups[b].roots[1].key
  end)
  local feature = {}
  for _, gi in ipairs(order) do
    local group = groups[gi]
    if not group.tests then
      local reach, covered = reach_of(gi), 0
      for _, key in ipairs(reach) do
        if feature[key] then covered = covered + 1 end
      end
      if #reach > 0 and covered * 2 < #reach then
        group.primary = true
        for _, key in ipairs(reach) do feature[key] = true end
      end
    end
  end
  -- Feature frames: everything a feature group reaches, unchanged ones included.
  local in_feature = {}
  for key, by in pairs(reached_by) do
    for gi in pairs(by) do
      if groups[gi].primary then in_feature[key] = true end
    end
  end

  -- Shared: where another entry point crosses into the feature. Only that
  -- frame is marked, not everything below it.
  for gi, group in ipairs(groups) do
    if not group.primary and not group.tests then
      local seen = {}
      local function cross(key)
        if seen[key] then return end
        seen[key] = true
        if in_feature[key] then
          local node = ctx.nodes[key]
          node.shared_from = node.shared_from or {}
          node.shared_from[gi] = true
          node.shared = vim.tbl_count(node.shared_from)
          return
        end
        for _, c in ipairs(ctx.callees[key] or {}) do cross(c.key) end
      end
      for _, root in ipairs(group.roots) do cross(root.key) end
    end
  end

  -- Changed code no root reaches: functions that only call each other.
  ctx.unreached = {}
  for _, node in ipairs(ctx.changed) do
    if not reached_by[node.key] then ctx.unreached[#ctx.unreached + 1] = node.key end
  end
  table.sort(ctx.unreached)

  table.sort(groups, function(a, b)
    if a.primary ~= b.primary then return a.primary end
    if a.tests ~= b.tests then return not a.tests end
    if a.changed ~= b.changed then return a.changed > b.changed end
    return a.roots[1].key < b.roots[1].key
  end)

  -- Data edges between changed functions, from added lines only.
  ctx.data_edges = {}
  if ctx.opts.data_edges then
    local writes, reads = {}, {}
    for _, node in ipairs(ctx.changed) do
      local adapter = adapter_for(node.path)
      writes[node.key], reads[node.key] = {}, {}
      for _, line in ipairs(node.added or {}) do
        local w, r = adapter.data_keys(line)
        for k in pairs(w) do writes[node.key][k] = true end
        for k in pairs(r) do reads[node.key][k] = true end
      end
    end
    for writer, keys_written in pairs(writes) do
      for reader, keys_read in pairs(reads) do
        -- Compound keys across files: the parser writing "scoring_player_id"
        -- that a notifier reads, not "id" or "team" in the same module.
        if writer ~= reader and ctx.nodes[writer].path ~= ctx.nodes[reader].path then
          for k in pairs(keys_written) do
            if keys_read[k] and k:find("_") then
              table.insert(ctx.data_edges, { from = writer, to = reader, key = k })
            end
          end
        end
      end
    end
    table.sort(ctx.data_edges, function(a, b)
      return a.key .. a.from .. a.to < b.key .. b.from .. b.to
    end)
  end

  ctx.groups = groups
end

-- Build the stacks for a diff.
-- args: { root, base, files, opts = { max_depth, max_frames, roots, data_edges }, yield }
function M.build(args)
  local opts = vim.tbl_extend("force", {
    max_depth = 12, max_frames = 400, max_context_hops = 3, data_edges = true, tests = false,
  }, args.opts or {})
  local ctx = {
    root = args.root, base = args.base or "", files = args.files, opts = opts,
    -- rg runs in the repo root, so relative roots give repo-relative paths.
    search_roots = opts.roots or { "." },
    yield = args.yield or function() end,
    nodes = {}, changed = {}, removed = {}, other = {}, tests = {}, outside = {}, callers = {},
    search_cache = {}, stats = { files = 0, visited = 0, truncated = false },
  }
  local started = vim.uv.hrtime()
  changed_functions(ctx)
  walk_callers(ctx)
  assemble(ctx)
  ctx.stats.ms = math.floor((vim.uv.hrtime() - started) / 1e6)
  return {
    nodes = ctx.nodes, callees = ctx.callees, callers = ctx.callers, groups = ctx.groups,
    changed = ctx.changed, removed = ctx.removed, other = ctx.other, tests = ctx.tests,
    outside = ctx.outside, unreached = ctx.unreached,
    data_edges = ctx.data_edges, stats = ctx.stats,
  }
end

M.adapter_for = adapter_for

return M
