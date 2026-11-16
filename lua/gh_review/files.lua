-- Changed files list buffer.

local state = require("gh_review.state")
local config = require("gh_review.config")
local win = require("gh_review.win")

local M = {}

local BUF_NAME = "gh-review://files"
local ns = vim.api.nvim_create_namespace("gh_review_files")

-- "files" lists the changed files; "stack" shows the call stacks into them.
local mode = "files"
-- The layout the last render drew ("flat", "tree" or "stack"), to know when
-- the folds belong to another one.
local last_layout = nil
-- Per files buffer, the fold level of each line in stack mode (see foldexpr).
local fold_levels = {}

-- The depth of a line for folding: a stack row's depth in the stack, or a
-- tree item's depth in the folder tree. Section titles and header lines are 0.
local function item_depth(item)
  if not item then return 0 end
  local row = item.row
  if row then return row.kind ~= "section" and (row.depth or 0) or 0 end
  return item.depth or 0
end

-- Only frames and folders can hold a fold; a file row never does.
local function foldable(item)
  if not item then return false end
  if item.row then return item.row.kind ~= "section" end
  return item.kind == "dir"
end

-- Fold levels from each line's depth in the stack or the folder tree. A line
-- whose next row is deeper starts a fold (">N"); others sit at their depth.
-- Section titles and header lines are depth 0, which ends every fold.
function M.fold_levels(line_items, count)
  local depths = {}
  for lnum = 1, count do depths[lnum] = item_depth(line_items[lnum]) end
  local levels = {}
  for lnum = 1, count do
    local d = depths[lnum]
    local next_depth = depths[lnum + 1]
    if foldable(line_items[lnum]) and next_depth and next_depth > d then
      levels[lnum] = ">" .. (d + 1)
    else
      levels[lnum] = tostring(d)
    end
  end
  return levels
end

function M.foldexpr()
  local levels = fold_levels[vim.api.nvim_get_current_buf()]
  return levels and levels[vim.v.lnum] or "0"
end

-- A closed frame keeps its own line and colours, and says how much is folded.
-- A closed folder in the file tree keeps just its line.
function M.foldtext()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.v.foldstart - 1
  local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  -- Colour each byte from the row's extmarks, later (narrower) marks on top.
  local hl = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, { details = true })) do
    local first, last = m[3], (m[4].end_col or #text) - 1
    for i = first, math.min(last, #text - 1) do hl[i] = m[4].hl_group end
  end
  local chunks, start = {}, 0
  for i = 1, #text do
    if i == #text or hl[i] ~= hl[start] then
      chunks[#chunks + 1] = { text:sub(start + 1, i), hl[start] or "Normal" }
      start = i
    end
  end
  -- A closed folder is just its own row, which already carries its totals.
  if mode == "stack" then
    local hidden = vim.v.foldend - vim.v.foldstart
    chunks[#chunks + 1] = { string.format("   ··· %d frame%s", hidden, hidden == 1 and "" or "s"), "Comment" }
  end
  return chunks
end
-- What each buffer line stands for: { kind = "file", path } or
-- { kind = "dir", path, depth } in the tree, or a stack item.
local items = {}

function M.mode() return mode end

-- The file list's layout: "flat" or "tree". The tree is a variant of the
-- "files" mode, so the stack view comes and goes without losing the choice.
function M.view() return config.options.files_view end
local function tree_layout() return mode == "files" and config.options.files_view == "tree" end

local function change_type_to_flag(change_type)
  if change_type == "ADDED" then return "A"
  elseif change_type == "DELETED" then return "D"
  elseif change_type == "RENAMED" then return "R"
  elseif change_type == "COPIED" then return "C"
  end
  return "M"
end

local SCOPE_NAMES = { branch = "Branch", uncommitted = "Uncommitted", turn = "Last turn" }

-- First header line: the PR, or the local scope and what it compares against.
function M.title()
  if not state.is_local_mode() then
    local pr_url = string.format("https://%s/%s/%s/pull/%d",
      state.get_host(), state.get_owner(), state.get_name(), state.get_pr_number())
    return string.format("%s: %s", pr_url, state.get_pr_title())
  end
  local info = state.get_local_info()
  return string.format("%s · %s vs %s (%s)", SCOPE_NAMES[state.get_scope()] or state.get_scope(),
    info.branch or "", info.base_label or "", state.get_merge_base_oid():sub(1, 7))
end

-- Folder tree of the changed files: directories first, then files, each
-- alphabetical. A folder whose only child is another folder is merged with it
-- ("lua/gh_review/"). Returns rows in display order:
--   { kind = "dir", name, path, depth, count, additions, deletions, paths }
--   { kind = "file", file, name, path, depth }
function M.build_tree(files)
  local root = { dirs = {}, files = {} }
  for _, f in ipairs(files) do
    local path = state.get(f, "path", "")
    local parts = vim.split(path, "/", { plain = true })
    local node = root
    for i = 1, #parts - 1 do
      local child = node.dirs[parts[i]]
      if not child then
        child = { name = parts[i], dirs = {}, files = {} }
        node.dirs[parts[i]] = child
      end
      node = child
    end
    node.files[#node.files + 1] = { file = f, name = parts[#parts], path = path }
  end

  local rows = {}
  -- Appends this node's rows and returns the totals under it.
  local function totals_of(node, out)
    local total = { count = 0, additions = 0, deletions = 0, paths = {} }
    local function add(t)
      total.count = total.count + t.count
      total.additions = total.additions + t.additions
      total.deletions = total.deletions + t.deletions
      vim.list_extend(total.paths, t.paths)
    end
    local names = vim.tbl_keys(node.dirs)
    table.sort(names)
    for _, name in ipairs(names) do
      local dir = node.dirs[name]
      local label = name
      -- Fold a chain of folders that each hold only one folder into one row.
      while #dir.files == 0 and vim.tbl_count(dir.dirs) == 1 do
        local only = next(dir.dirs)
        label = label .. "/" .. only
        dir = dir.dirs[only]
      end
      dir.label = label
      local children = {}
      local sub = totals_of(dir, children)
      add(sub)
      out[#out + 1] = { dir = dir, label = label, totals = sub, children = children }
    end
    table.sort(node.files, function(a, b) return a.name < b.name end)
    for _, entry in ipairs(node.files) do
      local f = entry.file
      local t = { count = 1, additions = state.get(f, "additions", 0), deletions = state.get(f, "deletions", 0),
        paths = { entry.path } }
      add(t)
      out[#out + 1] = { file = f, name = entry.name, path = entry.path }
    end
    return total
  end

  local top = {}
  totals_of(root, top)
  -- Flatten, tracking each folder's full path and depth.
  local function flatten(list, prefix, depth)
    for _, entry in ipairs(list) do
      if entry.dir then
        local path = prefix == "" and entry.label or (prefix .. "/" .. entry.label)
        local t = entry.totals
        rows[#rows + 1] = { kind = "dir", name = entry.label, path = path, depth = depth,
          count = t.count, additions = t.additions, deletions = t.deletions, paths = t.paths }
        flatten(entry.children, path, depth + 1)
      else
        rows[#rows + 1] = { kind = "file", file = entry.file, name = entry.name, path = entry.path, depth = depth }
      end
    end
  end
  flatten(top, "", 0)
  return rows
end

local function file_lines()
  local files = state.get_changed_files()
  local lines, line_items, hls = {}, {}, {}
  lines[#lines + 1] = string.format("Files changed (%d)", #files)
  local note = state.get_local_info().note
  if not state.is_local_mode() then
    local drafts = require("gh_review.pr_drafts").count()
    if drafts > 0 then
      note = string.format("%d draft%s saved locally, not on GitHub: :GHReviewSubmit publishes", drafts,
        drafts == 1 and "" or "s")
    end
  end
  lines[#lines + 1] = note or ""

  -- One row per file; in the tree, indented under its folder and showing its
  -- basename. `name` and `depth` are the flat list's path and 0.
  local function file_row(f, name, depth)
    local flag = change_type_to_flag(state.get(f, "changeType", "MODIFIED"))
    local additions = state.get(f, "additions", 0)
    local deletions = state.get(f, "deletions", 0)
    local path = state.get(f, "path", "")

    local file_threads = state.get_threads_for_file(path)
    local thread_count = #file_threads
    local thread_info = ""
    if thread_count > 0 then
      thread_info = string.format("  [%d thread%s]", thread_count, thread_count > 1 and "s" or "")
    end

    local checkbox = state.is_file_checked(path) and "[x]" or "[ ]"
    lines[#lines + 1] = string.format("%s +%-4d -%-4d %s  %s%s%s", checkbox, additions, deletions, flag,
      string.rep("  ", depth), name, thread_info)
    line_items[#lines] = { kind = "file", path = path, depth = depth }
  end

  if not tree_layout() then
    for _, f in ipairs(files) do
      local path = state.get(f, "path", "")
      file_row(f, path, 0)
    end
    return lines, line_items, hls
  end

  for _, row in ipairs(M.build_tree(files)) do
    if row.kind == "file" then
      file_row(row.file, row.name, row.depth)
    else
      local viewed = 0
      for _, p in ipairs(row.paths) do
        if state.is_file_checked(p) then viewed = viewed + 1 end
      end
      local checkbox = viewed == row.count and "[x]" or "[ ]"
      local head = string.format("%s +%-4d -%-4d    %s", checkbox, row.additions, row.deletions,
        string.rep("  ", row.depth))
      local name = row.name .. "/"
      local tail = string.format("  (%d file%s)", row.count, row.count == 1 and "" or "s")
      lines[#lines + 1] = head .. name .. tail
      line_items[#lines] = { kind = "dir", path = row.path, depth = row.depth }
      -- hls rows are 0-based body lines. The syntax file colours file rows;
      -- a folder row is coloured here, so it survives being folded closed.
      local r = #lines - 1
      local plus_end = 4 + #string.format("+%-4d", row.additions)
      hls[#hls + 1] = { r, 4, 4 + #tostring(row.additions) + 1, "ghReviewAdditions" }
      hls[#hls + 1] = { r, plus_end + 1, plus_end + 1 + #tostring(row.deletions) + 1, "ghReviewDeletions" }
      hls[#hls + 1] = { r, #head, #head + #name, "GHReviewFilesDir" }
      hls[#hls + 1] = { r, #head + #name, #lines[#lines], "Comment" }
    end
  end
  return lines, line_items, hls
end

-- "? help · s stack view", from the configured keys; disabled keys are left out.
function M.key_hint()
  local keys = config.options.keymaps.files
  local parts = {}
  if type(keys.help) == "string" then parts[#parts + 1] = keys.help .. " help" end
  if type(keys.toggle_stack) == "string" then
    parts[#parts + 1] = keys.toggle_stack .. (mode == "stack" and " file list" or " stack view")
  end
  return table.concat(parts, " · ")
end

local function render()
  local view = require("gh_review.stack.view")
  local body, body_items, hls
  if mode == "stack" then
    body, body_items, hls = view.render()
  else
    body, body_items, hls = file_lines()
  end
  -- Line one is always the title; the body brings its own two header lines.
  local lines = { M.title() }
  items = {}
  for i, text in ipairs(body) do
    lines[#lines + 1] = text
    items[#lines] = body_items[i]
  end
  -- Point at the help from the second header line, where it costs no space.
  local hint = M.key_hint()
  local hint_col = nil
  if hint ~= "" and lines[2] then
    hint_col = #lines[2] + 3
    lines[2] = lines[2] .. "   " .. hint
  end

  local bufnr = state.get_files_bufnr()
  -- Stack mode folds by depth: every frame with frames below it can fold. The
  -- folder tree folds the same way, a folder over its contents.
  -- Set before the lines change, which is when Neovim recomputes the folds.
  local folds = mode == "stack" or tree_layout()
  fold_levels[bufnr] = folds and M.fold_levels(items, #lines) or nil
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  -- The files syntax would misread stack rows; they are highlighted by extmarks.
  vim.bo[bufnr].syntax = mode == "stack" and "" or "gh-review-files"
  local layout = mode == "stack" and "stack" or config.options.files_view
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if hint_col then
    vim.api.nvim_buf_set_extmark(bufnr, ns, 1, hint_col, { end_col = #lines[2], hl_group = "Comment" })
  end
  local winid_for_folds = vim.fn.bufwinid(bufnr)
  if winid_for_folds ~= -1 then
    vim.api.nvim_win_call(winid_for_folds, function()
      if folds then
        -- Another layout's folds mean nothing here: start over, fully open.
        if layout ~= last_layout then
          vim.wo.foldmethod = "manual"
          vim.cmd("silent! normal! zE")
        end
        if vim.wo.foldmethod ~= "expr" then
          vim.wo.foldmethod = "expr"
          vim.wo.foldexpr = "v:lua.require'gh_review.files'.foldexpr()"
          vim.wo.foldtext = "v:lua.require'gh_review.files'.foldtext()"
          -- Start fully open; later redraws keep whatever is folded.
          vim.wo.foldlevel = 99
        end
        vim.wo.foldenable = true
        -- ▾ where a frame's fold is open, ▸ where it is closed. A custom
        -- 'statuscolumn' (LazyVim sets one globally) replaces the fold column,
        -- so this window draws the plain one.
        vim.wo.statuscolumn = ""
        vim.wo.foldcolumn = "1"
        vim.wo.fillchars = "foldopen:▾,foldclose:▸,foldsep: ,fold: "
      else
        vim.wo.foldcolumn = "0"
        if vim.wo.foldmethod ~= "manual" then
          vim.wo.foldmethod = "manual"
          vim.cmd("silent! normal! zE")
        end
      end
    end)
  end
  last_layout = layout
  for _, hl in ipairs(hls) do
    local row, col_start, col_end, group = hl[1] + 1, hl[2], hl[3], hl[4]
    local text = lines[row + 1] or ""
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, col_start,
      { end_col = col_end == -1 and #text or math.min(col_end, #text), hl_group = group })
  end

  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    -- First file row, clamped to the buffer: an empty scope has only the header.
    local row = math.min(math.max(4, cursor[1]), line_count)
    vim.api.nvim_win_set_cursor(winid, { row, cursor[2] })
  end
end

-- Mark each of `paths` viewed or not, locally at once, then on GitHub (one
-- mutation per file) or in the local store. M.rerender keeps the cursor in place.
local function set_checked(paths, checked)
  local changed = {}
  for _, path in ipairs(paths) do
    if state.is_file_checked(path) ~= checked then changed[#changed + 1] = path end
  end
  if #changed == 0 then return end
  for _, path in ipairs(changed) do state.set_file_checked(path, checked) end
  M.rerender()

  if state.is_local_mode() then
    for _, path in ipairs(changed) do
      require("gh_review.local_store").set_viewed(state.get_scope(), path, checked)
    end
    return
  end

  local api = require("gh_review.api")
  local graphql = require("gh_review.graphql")
  local mutation = checked and graphql.MUTATION_MARK_FILE_VIEWED or graphql.MUTATION_UNMARK_FILE_VIEWED
  for _, path in ipairs(changed) do
    local vars = { pullRequestId = state.get_pr_id(), path = path }
    api.graphql(mutation, vars, function(result, err)
      local data = ((result or {}).data) or {}
      local ok = not err and (data.markFileAsViewed or data.unmarkFileAsViewed)
      if not ok then
        -- Revert, unless the user re-toggled this file while the request was in
        -- flight (which would make this a stale response we'd be clobbering).
        if state.is_file_checked(path) == checked then
          state.set_file_checked(path, not checked)
          M.rerender()
        end
      end
    end)
  end
end

-- Every changed file at or under the folder `dir`.
local function paths_under(dir)
  local paths = {}
  for _, f in ipairs(state.get_changed_files()) do
    local path = state.get(f, "path", "")
    if path:sub(1, #dir + 1) == dir .. "/" then paths[#paths + 1] = path end
  end
  return paths
end

local function toggle_checked_under_cursor()
  local item = items[vim.fn.line(".")]
  if not item then return end
  if item.kind == "file" then
    set_checked({ item.path }, not state.is_file_checked(item.path))
  elseif item.kind == "dir" then
    -- All viewed already: unmark them all. Otherwise mark the rest.
    local paths = paths_under(item.path)
    local all = #paths > 0
    for _, path in ipairs(paths) do
      if not state.is_file_checked(path) then all = false end
    end
    set_checked(paths, not all)
  end
end

local function open_file_under_cursor()
  local item = items[vim.fn.line(".")]
  if not item then return end
  if item.kind == "file" then
    require("gh_review.diff").open(item.path)
    return
  end
  if item.kind == "dir" then
    vim.cmd("silent! normal! za")
    return
  end
  -- A stack row: a "see above" reference jumps to the expanded frame.
  if item.target then
    -- Targets count the view's own lines; the title line sits above them.
    vim.api.nvim_win_set_cursor(0, { item.target + 1, 0 })
    return
  end
  local row = item.row
  local node = row and row.node
  if row and row.kind == "file" then
    require("gh_review.diff").open(row.file.path)
  elseif row and row.kind == "hunk" then
    require("gh_review.diff").open(row.hunk.path, { line = row.hunk.line })
  elseif node then
    local diff = require("gh_review.diff")
    if node.status == "deleted" then
      diff.open(node.path, { line = node.line, side = "LEFT" })
    elseif M.in_change(node.path) then
      diff.open(node.path, { line = node.jump_line or node.line })
    else
      diff.open_plain(node.path, node.line)
    end
  end
end

function M.in_change(path)
  for _, f in ipairs(state.get_changed_files()) do
    if f.path == path then return true end
  end
  return false
end

-- Switch between the file list and the stack view.
function M.toggle_stack()
  mode = mode == "stack" and "files" or "stack"
  if mode == "stack" then
    local view = require("gh_review.stack.view")
    if not view.unavailable() then view.ensure(function() M.rerender() end) end
  end
  M.rerender()
  local winid = vim.fn.bufwinid(state.get_files_bufnr())
  if winid ~= -1 then
    local first = 4
    for lnum = 4, vim.api.nvim_buf_line_count(state.get_files_bufnr()) do
      if items[lnum] then first = lnum break end
    end
    pcall(vim.api.nvim_win_set_cursor, winid, { first, 0 })
  end
end

-- Switch the file list between the flat list and the folder tree, for this
-- session. The cursor goes to the same file (or folder) when it is still shown.
function M.toggle_tree()
  local options = config.options
  local bufnr = state.get_files_bufnr()
  local winid = bufnr ~= -1 and vim.fn.bufwinid(bufnr) or -1
  local item = winid ~= -1 and items[vim.api.nvim_win_get_cursor(winid)[1]] or nil
  options.files_view = options.files_view == "tree" and "flat" or "tree"
  -- The stack view has no tree; the choice shows when the list comes back.
  if mode ~= "files" then return end
  M.rerender()
  if winid == -1 or not item then return end
  for lnum, it in pairs(items) do
    if it.kind == item.kind and it.path == item.path then
      pcall(vim.api.nvim_win_set_cursor, winid, { lnum, 0 })
      return
    end
  end
end

-- Put the cursor on `key`'s expanded row in the stack view (not a "see above"
-- reference), unfolding what hides it, and focus the list. False when the
-- view has no row for it.
function M.reveal(key)
  local bufnr = state.get_files_bufnr()
  local winid = bufnr ~= -1 and vim.fn.bufwinid(bufnr) or -1
  if winid == -1 then return false end
  local fallback = nil
  for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
    local row = (items[lnum] or {}).row
    if row and row.node and row.node.key == key then
      if row.kind == "frame" and not row.ref then
        fallback = lnum
        break
      end
      fallback = fallback or lnum
    end
  end
  if not fallback then return false end
  vim.fn.win_gotoid(winid)
  vim.api.nvim_win_set_cursor(winid, { fallback, 0 })
  vim.cmd("normal! zvzz")
  return true
end

-- From the diff: show the function at `path`:`line` in the stack view,
-- opening the list, switching it to the stack view and waiting for the build
-- as needed.
function M.show_in_stack(path, line, side)
  local view = require("gh_review.stack.view")
  local bufnr = state.get_files_bufnr()
  if bufnr == -1 or vim.fn.bufexists(bufnr) == 0 or vim.fn.bufwinid(bufnr) == -1 then
    local from = vim.api.nvim_get_current_win()
    M.open()
    -- Opening the list moves the cursor; the reveal below decides focus.
    if vim.api.nvim_win_is_valid(from) and view.result() == nil then vim.fn.win_gotoid(from) end
  end
  if mode ~= "stack" then M.toggle_stack() end
  local reason = view.unavailable()
  if reason then
    vim.notify("[gh-review] " .. reason, vim.log.levels.WARN)
    return
  end
  view.ensure(function() M.rerender() end)
  if not view.result() then print("Building the stack view…") end
  view.when_built(function()
    local node = view.node_at(path, line, side)
    if not node then
      print("No function here in the stack view")
    elseif not M.reveal(node.key) then
      print("That function has no row in the stack view")
    end
  end)
end

-- Move the list between the bottom and the left, keeping mode and cursor.
function M.toggle_position()
  local options = config.options
  options.files_position = options.files_position == "left" and "bottom" or "left"
  local bufnr = state.get_files_bufnr()
  local winid = bufnr ~= -1 and vim.fn.bufwinid(bufnr) or -1
  local cursor = winid ~= -1 and vim.api.nvim_win_get_cursor(winid) or nil
  M.close()
  M.open()
  winid = vim.fn.bufwinid(state.get_files_bufnr())
  if cursor and winid ~= -1 then pcall(vim.api.nvim_win_set_cursor, winid, cursor) end
end

local function refresh_and_render()
  require("gh_review").refresh_threads()
end

-- Action declaration for the files list. Drives both keymap application and
-- the README/help mapping tables. M.close is referenced through a closure
-- because it is defined further down the module.
local ACTIONS = {
  open          = { { "n", open_file_under_cursor,      "Open diff" } },
  toggle_viewed = { { "n", toggle_checked_under_cursor, "Toggle file reviewed" } },
  refresh       = { { "n", refresh_and_render,          "Refresh threads" } },
  toggle_files  = { { "n", function() M.close() end,    "Close files list" } },
  close         = { { "n", function() M.close() end,    "Close files list" } },
  send              = { { "n", function() require("gh_review").send() end, "Send comments to agent" } },
  scope_pr          = { { "n", function() require("gh_review").set_scope("pr") end, "Scope: PR" } },
  scope_branch      = { { "n", function() require("gh_review").set_scope("branch") end, "Scope: branch" } },
  scope_uncommitted = { { "n", function() require("gh_review").set_scope("uncommitted") end, "Scope: uncommitted" } },
  scope_turn        = { { "n", function() require("gh_review").set_scope("turn") end, "Scope: last turn" } },
  toggle_stack      = { { "n", function() M.toggle_stack() end, "Toggle stack view" } },
  toggle_fold       = { { "n", function() vim.cmd("silent! normal! za") end, "Fold or unfold a frame or folder" } },
  toggle_tree       = { { "n", function() M.toggle_tree() end, "Toggle flat list / folder tree" } },
  toggle_position   = { { "n", function() M.toggle_position() end, "Move list left/bottom" } },
  help              = { { "n", function() require("gh_review.help").open() end, "Show keys and commands" } },
  toggle_view       = { { "n", function() require("gh_review.diff").toggle_view() end, "Toggle side-by-side / unified" } },
}

-- For the `?` help, which lists what each surface maps.
M.ACTIONS = ACTIONS

local function setup_buffer()
  local bufnr = state.get_files_bufnr()
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false

  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    vim.wo[winid].wrap = false
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].list = false
    local left = config.options.files_position == "left"
    vim.wo[winid].winfixheight = not left
    vim.wo[winid].winfixwidth = left
  end

  vim.bo[bufnr].filetype = "gh-review-files"

  -- Keymaps
  config.apply_keymaps(bufnr, "files", ACTIONS)
end

function M.open()
  -- Reuse existing buffer if it exists
  local bufnr = state.get_files_bufnr()
  if bufnr ~= -1 and vim.fn.bufexists(bufnr) == 1 then
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
      vim.fn.win_gotoid(winid)
      render()
      return
    end
  end

  -- Create a new split at the bottom or on the left. :split rather than :new,
  -- because :new would open a throwaway empty buffer that is orphaned the
  -- moment the window is pointed at the files buffer below.
  local size = config.options.files_size
  if config.options.files_position == "left" then
    vim.cmd("topleft vsplit")
    vim.cmd("vertical resize " .. size.left)
  else
    vim.cmd("botright split")
    vim.cmd("resize " .. size.bottom)
  end
  local new_bufnr = vim.fn.bufnr(BUF_NAME, true)
  vim.cmd("buffer " .. new_bufnr)
  state.set_files_bufnr(new_bufnr)

  setup_buffer()
  render()
end

function M.close()
  local bufnr = state.get_files_bufnr()
  if bufnr ~= -1 and vim.fn.bufexists(bufnr) == 1 then
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
      vim.fn.win_gotoid(winid)
      win.close_current()
      -- Let diff windows expand into the freed space and redraw.
      vim.cmd("wincmd =")
      local left_winid = vim.fn.bufwinid(state.get_left_bufnr())
      if left_winid ~= -1 then
        vim.fn.win_gotoid(left_winid)
        vim.cmd([[execute "normal! \<C-e>\<C-y>"]])
      end
      local right_winid = vim.fn.bufwinid(state.get_right_bufnr())
      if right_winid ~= -1 then
        vim.fn.win_gotoid(right_winid)
        vim.cmd([[execute "normal! \<C-e>\<C-y>"]])
      end
    end
  end
end

function M.toggle()
  local bufnr = state.get_files_bufnr()
  if bufnr ~= -1 and vim.fn.bufexists(bufnr) == 1 and vim.fn.bufwinid(bufnr) ~= -1 then
    M.close()
  else
    M.open()
  end
end

-- A new review starts in the file list.
function M.reset_mode()
  mode = "files"
  items = {}
end

function M.rerender()
  local bufnr = state.get_files_bufnr()
  if bufnr ~= -1 and vim.fn.bufexists(bufnr) == 1 then
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
      local save_winid = vim.fn.win_getid()
      vim.fn.win_gotoid(winid)
      render()
      vim.fn.win_gotoid(save_winid)
    end
  end
end

return M
