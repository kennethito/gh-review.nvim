-- Unified diff rendered onto the head buffer itself.
--
-- The head pane stays the real file (LSP, go-to-definition, editing all keep
-- working). Added and changed lines get line highlights, the changed
-- characters DiffText, and removed lines are drawn as virtual lines above where
-- they were. Nothing is written into the buffer.

local M = {}

M.ns = vim.api.nvim_create_namespace("gh_review_unified")
-- The cursor line on added lines, redrawn as the cursor moves.
M.cursor_ns = vim.api.nvim_create_namespace("gh_review_unified_cursor")

-- Per buffer: the head rows (0-based) the unified view highlights as added.
local added_rows = {}

-- Lines of context kept unfolded around each hunk.
M.CONTEXT = 3

-- Longest line pair compared character by character.
local MAX_INTRALINE = 400

-- vim.diff hunks { a_start, a_count, b_start, b_count } between two line lists.
function M.hunks(base_lines, head_lines)
  local a = table.concat(base_lines, "\n") .. "\n"
  local b = table.concat(head_lines, "\n") .. "\n"
  if #base_lines == 0 then a = "" end
  if #head_lines == 0 then b = "" end
  return vim.diff(a, b, { result_type = "indices" }) or {}
end

-- The head line a removed block sits above, and whether it hangs below the
-- last line instead (a deletion at the end of the file).
function M.anchor(hunk, head_count)
  local b_start, b_count = hunk[3], hunk[4]
  local line = b_count > 0 and b_start or b_start + 1
  if line > head_count then return math.max(head_count, 1), true end
  return math.max(line, 1), false
end

-- Where a base line shows in the head: its counterpart when unchanged, or the
-- line its removed block hangs above.
function M.base_to_head(line, hunks, head_count)
  local offset = 0
  for _, h in ipairs(hunks) do
    local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
    local a_last = a_start + a_count - 1
    if a_count > 0 and line >= a_start and line <= a_last then
      return (M.anchor(h, head_count))
    end
    if (a_count > 0 and line < a_start) or (a_count == 0 and line <= a_start) then break end
    -- The first line after the hunk on each side: a zero count means the
    -- hunk sits after its start line.
    local base_next = a_count > 0 and a_start + a_count or a_start + 1
    local head_next = b_count > 0 and b_start + b_count or b_start + 1
    offset = head_next - base_next
  end
  return math.min(math.max(line + offset, 1), math.max(head_count, 1))
end

local function chars(text)
  return vim.fn.split(text, "\\zs")
end

-- Byte ranges { first, last_exclusive } that differ between two lines.
local function is_word_char(c)
  return c:find("^[%w_]$") ~= nil or c:byte() >= 128
end

-- A line as the units compared: characters, or words (runs of letters,
-- digits, _ and non-ASCII), runs of spaces, and single punctuation marks.
local function tokens(text, mode)
  local list = chars(text)
  if mode ~= "word" then return list end
  local result = {}
  for _, c in ipairs(list) do
    local last = result[#result]
    local joins = last and ((is_word_char(c) and is_word_char(last:sub(-1)))
      or (c:find("^%s$") and last:find("^%s+$")))
    if joins then
      result[#result] = last .. c
    else
      result[#result + 1] = c
    end
  end
  return result
end

-- Which part of a changed line to mark: "word", "char", or "off".
M.inline = "word"

local function intraline(old, new)
  if M.inline == "off" then return nil, nil end
  if #old > MAX_INTRALINE or #new > MAX_INTRALINE then return nil, nil end
  local a, b = tokens(old, M.inline), tokens(new, M.inline)
  -- An empty line is no units at all, not one empty unit: joining it would
  -- give vim.diff a blank line that has no offset to map back to.
  local function joined(list) return #list == 0 and "" or (table.concat(list, "\n") .. "\n") end
  local idx = vim.diff(joined(a), joined(b), { result_type = "indices" }) or {}
  local function offsets(list)
    local result, pos = { 0 }, 0
    for i, c in ipairs(list) do
      pos = pos + #c
      result[i + 1] = pos
    end
    return result
  end
  local oa, ob = offsets(a), offsets(b)
  local old_ranges, new_ranges = {}, {}
  for _, h in ipairs(idx) do
    if h[2] > 0 then old_ranges[#old_ranges + 1] = { oa[h[1]], oa[h[1] + h[2]] } end
    if h[4] > 0 then new_ranges[#new_ranges + 1] = { ob[h[3]], ob[h[3] + h[4]] } end
  end
  return old_ranges, new_ranges
end

local function expand_tabs(text, tabstop)
  local out, col = {}, 0
  for _, c in ipairs(chars(text)) do
    if c == "\t" then
      local n = tabstop - (col % tabstop)
      out[#out + 1] = string.rep(" ", n)
      col = col + n
    else
      out[#out + 1] = c
      col = col + vim.fn.strdisplaywidth(c)
    end
  end
  return table.concat(out)
end

-- A removed line as virtual-text chunks, the changed bytes in DiffText.
local function removed_chunks(text, ranges, tabstop)
  if not ranges or #ranges == 0 then
    return { { expand_tabs(text, tabstop), "DiffDelete" } }
  end
  local chunks, pos = {}, 0
  for _, r in ipairs(ranges) do
    if r[1] > pos then chunks[#chunks + 1] = { expand_tabs(text:sub(pos + 1, r[1]), tabstop), "DiffDelete" } end
    chunks[#chunks + 1] = { expand_tabs(text:sub(r[1] + 1, r[2]), tabstop), "DiffText" }
    pos = r[2]
  end
  if pos < #text then chunks[#chunks + 1] = { expand_tabs(text:sub(pos + 1), tabstop), "DiffDelete" } end
  return chunks
end

-- Draw the unified diff on `bufnr` (whose lines are the head) against
-- `base_lines`. Returns the hunks, also kept in b:gh_review_unified_hunks.
function M.render(bufnr, base_lines)
  M.clear(bufnr)
  local head_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = M.hunks(base_lines, head_lines)
  local tabstop = vim.bo[bufnr].tabstop
  local head_count = #head_lines

  local added = {}
  for _, h in ipairs(hunks) do
    local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
    local pairs_count = math.min(a_count, b_count)
    local removed = {}
    for i = 0, a_count - 1 do
      local old = base_lines[a_start + i] or ""
      local old_ranges = nil
      if i < pairs_count then
        old_ranges = (intraline(old, head_lines[b_start + i] or ""))
      end
      removed[#removed + 1] = removed_chunks(old, old_ranges, tabstop)
    end
    for i = 0, b_count - 1 do
      local row = b_start + i - 1
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, { line_hl_group = "DiffAdd", priority = 50 })
      added[row] = true
      if i < pairs_count then
        local _, new_ranges = intraline(base_lines[a_start + i] or "", head_lines[b_start + i] or "")
        for _, r in ipairs(new_ranges or {}) do
          vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, r[1], { end_col = r[2], hl_group = "DiffText", priority = 60 })
        end
      end
    end
    if #removed > 0 and head_count > 0 then
      local line, below = M.anchor(h, head_count)
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, line - 1, 0, { virt_lines = removed, virt_lines_above = not below })
    end
  end
  vim.b[bufnr].gh_review_unified_hunks = hunks
  added_rows[bufnr] = added
  M.track_cursor(bufnr)
  return hunks
end

function M.clear(bufnr)
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, M.cursor_ns, 0, -1)
    pcall(vim.api.nvim_del_augroup_by_name, "gh_review_unified_cursor_" .. bufnr)
    vim.b[bufnr].gh_review_unified_hunks = nil
    added_rows[bufnr] = nil
  end
end

-- An added line's background replaces the cursor line, and in many colour
-- schemes DiffAdd and CursorLine are close shades, so inside a new function
-- the cursor line vanished. Draw a distinct one there as the cursor moves.
function M.show_cursor(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.cursor_ns, 0, -1)
  local rows = added_rows[bufnr]
  local winid = vim.fn.bufwinid(bufnr)
  if not rows or winid == -1 or not vim.wo[winid].cursorline then return end
  local row = vim.api.nvim_win_get_cursor(winid)[1] - 1
  if rows[row] then
    vim.api.nvim_buf_set_extmark(bufnr, M.cursor_ns, row, 0,
      { line_hl_group = "GHReviewUnifiedCursorLine", priority = 55 })
  end
end

function M.track_cursor(bufnr)
  local group = vim.api.nvim_create_augroup("gh_review_unified_cursor_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function() M.show_cursor(bufnr) end,
  })
  M.show_cursor(bufnr)
end

-- Head line ranges a hunk touches, context included.
local function shown_ranges(hunks, head_count)
  local ranges = {}
  for _, h in ipairs(hunks) do
    local first, last
    if h[4] > 0 then
      first, last = h[3], h[3] + h[4] - 1
    else
      first = M.anchor(h, head_count)
      last = first
    end
    ranges[#ranges + 1] = { math.max(first - M.CONTEXT, 1), math.min(last + M.CONTEXT, head_count) }
  end
  return ranges
end

-- Manual folds over unchanged stretches in the current window.
function M.fold(hunks, head_count, level)
  vim.wo.foldmethod = "manual"
  vim.cmd("silent! normal! zE")
  local pos = 1
  for _, r in ipairs(shown_ranges(hunks, head_count)) do
    if r[1] - 1 > pos then vim.cmd(string.format("silent! %d,%dfold", pos, r[1] - 1)) end
    pos = math.max(pos, r[2] + 1)
  end
  if head_count > pos then vim.cmd(string.format("silent! %d,%dfold", pos, head_count)) end
  vim.wo.foldenable = true
  vim.wo.foldlevel = level or 0
end

-- The head lines each hunk starts on, in order.
function M.starts(hunks, head_count)
  local result = {}
  for _, h in ipairs(hunks) do
    result[#result + 1] = h[4] > 0 and h[3] or (M.anchor(h, head_count))
  end
  return result
end

-- The removed block that hangs above `line`, as { first, last } base lines.
function M.removed_above(line, hunks, head_count)
  for _, h in ipairs(hunks) do
    if h[2] > 0 then
      local anchor, below = M.anchor(h, head_count)
      if anchor == line and not below then return { h[1], h[1] + h[2] - 1 } end
    end
  end
  return nil
end

return M
