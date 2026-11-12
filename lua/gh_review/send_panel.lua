-- A float that shows what is about to leave the editor before it does: the
-- text sent to an agent (or copied), or the drafts :GHReviewSubmit publishes.
--
-- Optional checkboxes pick which kinds of comments go; the preview under them
-- is rebuilt on every toggle, so what you see is exactly what is sent.
--
-- The preview also says which comment each of its lines came from (spans), so
-- the cursor can act on one comment: delete it, edit it, or leave its item out
-- of this send.

local M = {}

-- { buf, win, return_win, spec, ticked, skipped, categories, spans, offset, left_rows }
local panel = nil

local NS = vim.api.nvim_create_namespace("gh_review_send_panel")

function M.is_open()
  return panel ~= nil and vim.api.nvim_win_is_valid(panel.win)
end

function M.close()
  if not panel then return end
  local p = panel
  panel = nil
  if vim.api.nvim_win_is_valid(p.win) then vim.api.nvim_win_close(p.win, true) end
  if p.return_win and vim.api.nvim_win_is_valid(p.return_win) then
    vim.api.nvim_set_current_win(p.return_win)
  end
end

local function categories_of(spec)
  if type(spec.categories) == "function" then return spec.categories() or {} end
  return spec.categories or {}
end

-- Category keys that are ticked, as a set.
function M.selected()
  local result = {}
  if not panel then return result end
  for _, c in ipairs(panel.categories) do
    if panel.ticked[c.key] and c.count > 0 then result[c.key] = true end
  end
  return result
end

-- Thread ids left out of this send, as a set (a copy).
function M.skipped()
  return panel and vim.deepcopy(panel.skipped) or {}
end

-- preview -> text, spans, left_out. spans: see agent.message. left_out:
-- { { thread_id, label } } for skipped items, listed under the preview.
local function preview_of()
  return panel.spec.preview(M.selected(), panel.skipped)
end

-- The preview as one string (what the panel shows under the checkboxes).
function M.preview_text()
  if not panel then return nil end
  return (preview_of())
end

local function help_lines(spec)
  local parts = {}
  if #panel.categories > 0 then parts[#parts + 1] = "<Space> tick" end
  for _, a in ipairs(spec.actions) do
    parts[#parts + 1] = string.format("%s %s", a.key, a.label)
  end
  parts[#parts + 1] = "q cancel"
  local lines = { " " .. table.concat(parts, " · ") }
  local keys = {}
  if spec.on_delete then keys[#keys + 1] = "dd delete" end
  if spec.on_edit then keys[#keys + 1] = "e edit" end
  if spec.skippable then keys[#keys + 1] = "- skip" end
  if #keys > 0 then lines[#lines + 1] = " On a comment: " .. table.concat(keys, " · ") end
  return lines
end

-- Lines and highlights for the current state. Also sets panel.rows (buffer
-- line -> category), panel.spans and panel.offset (the preview starts at
-- buffer line offset + 1), and panel.left_rows (buffer line -> skipped thread).
local function build()
  local spec = panel.spec
  panel.categories = categories_of(spec)
  local lines, hls, rows = {}, {}, {}
  for _, l in ipairs(help_lines(spec)) do
    lines[#lines + 1] = l
    hls[#hls + 1] = { #lines, "Comment" }
  end
  lines[#lines + 1] = ""
  for i, c in ipairs(panel.categories) do
    local box = c.count == 0 and "[-]" or (panel.ticked[c.key] and "[x]" or "[ ]")
    lines[#lines + 1] = string.format(" %s %d. %s (%d)", box, i, c.label, c.count)
    rows[#lines] = c
    hls[#hls + 1] = { #lines, c.count == 0 and "Comment" or (panel.ticked[c.key] and (c.hl or "GHReviewThread") or "Normal") }
  end
  if #panel.categories > 0 then
    lines[#lines + 1] = " " .. string.rep("─", 40)
    hls[#hls + 1] = { #lines, "Comment" }
  end

  local text, spans, left_out = preview_of()
  panel.offset = #lines
  panel.spans = spans or {}
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = l
    if l:find("^%d+%. ") then hls[#hls + 1] = { #lines, "Title" } end
  end

  panel.left_rows = {}
  if left_out and #left_out > 0 then
    lines[#lines + 1] = " " .. string.rep("─", 40)
    lines[#lines + 1] = " Skipped for this send (- on one brings it back):"
    hls[#hls + 1] = { #lines - 1, "Comment" }
    hls[#hls + 1] = { #lines, "Comment" }
    for _, item in ipairs(left_out) do
      lines[#lines + 1] = "   " .. item.label
      panel.left_rows[#lines] = item.thread_id
      hls[#hls + 1] = { #lines, "Comment" }
    end
  end
  return lines, hls, rows
end

-- Fit the float to its content, centred.
local function fit(lines)
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.max(50, math.min(width + 2, 100, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
  }
end

local function render()
  local lines, hls, rows = build()
  panel.rows = rows
  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(panel.buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(panel.buf, NS, h[1] - 1, 0, { line_hl_group = h[2] })
  end
  return lines
end

-- Rebuild the panel from its spec, e.g. after a comment was deleted or edited.
-- Closes it, with the spec's message, when nothing is left to show.
function M.refresh()
  if not M.is_open() then return end
  local message = panel.spec.is_empty and panel.spec.is_empty()
  if message then
    M.close()
    print(message)
    return
  end
  local lines = render()
  if vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_win_set_config(panel.win, fit(lines))
  end
end

-- Tick or untick a category by key; empty categories stay unticked.
function M.toggle(key)
  if not panel then return end
  for _, c in ipairs(panel.categories) do
    if c.key == key and c.count > 0 then
      panel.ticked[key] = not panel.ticked[key]
      M.refresh()
      return
    end
  end
end

-- Run the action bound to `key` (as the user pressing it).
function M.act(key)
  if not panel then return end
  for _, a in ipairs(panel.spec.actions) do
    if a.key == key then
      local selected = M.selected()
      if #panel.categories > 0 and next(selected) == nil then
        print("Nothing ticked")
        return
      end
      local _, spans = preview_of()
      if spans and #spans == 0 then
        print("Nothing to send")
        return
      end
      local skipped = panel.skipped
      M.close()
      a.fn(selected, skipped)
      return
    end
  end
end

-- What the buffer line is about: its item (a thread) and, within it, the
-- comment on that line. Title and quote lines belong to the item's first
-- comment. Returns nil off the items (help, categories, blank lines between).
local function locate(line)
  local rel = line - panel.offset
  for _, item in ipairs(panel.spans) do
    if rel >= item.first_line and rel <= item.last_line then
      for _, c in ipairs(item.comments) do
        if rel >= c.first_line and rel <= c.last_line then return item, c end
      end
      return item, item.comments[1]
    end
  end
  return nil
end

local function cursor_line()
  return vim.api.nvim_win_get_cursor(panel.win)[1]
end

local function at_cursor(handler)
  if not M.is_open() then return end
  local item, comment = locate(cursor_line())
  if not item then
    print("Not on a comment")
    return
  end
  handler(item, comment)
end

-- Leave an item out of this send, or bring it back (from its own lines or
-- from the skipped list under the preview).
local function toggle_skip()
  if not M.is_open() then return end
  local id = panel.left_rows[cursor_line()]
  local was_skipped = id ~= nil
  if not id then
    local item = locate(cursor_line())
    id = item and item.thread_id
  end
  if not id then
    print("Not on a comment")
    return
  end
  panel.skipped[id] = (not panel.skipped[id]) or nil
  M.refresh()
  if was_skipped and M.is_open() then
    -- Follow the item back to its place in the preview.
    for _, item in ipairs(panel.spans) do
      if item.thread_id == id then
        vim.api.nvim_win_set_cursor(panel.win, { panel.offset + item.first_line, 0 })
      end
    end
  end
end

-- A small float to edit a comment body. :w (or the thread buffer's submit key)
-- calls on_save(text) and closes it; q cancels. Focus returns to the panel.
function M.edit(title, body, on_save)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "gh-review://edit-comment/" .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split((body or ""):gsub("\r", ""), "\n", { plain = true }))
  vim.bo[buf].modified = false
  local width = math.min(80, vim.o.columns - 4)
  local height = math.max(5, math.min(15, vim.api.nvim_buf_line_count(buf) + 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = string.format(" %s (:w save, q cancel) ", title),
    title_pos = "center",
  })
  vim.cmd("stopinsert")
  require("gh_review.win").no_folds(win)
  vim.wo[win].wrap = true

  local function leave()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if M.is_open() then vim.api.nvim_set_current_win(panel.win) end
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      if text == "" then
        print("A comment cannot be empty; q cancels, dd in the panel deletes it")
        return
      end
      vim.bo[buf].modified = false
      leave()
      on_save(text)
      M.refresh()
    end,
  })
  vim.keymap.set("n", "q", leave, { buffer = buf, nowait = true, silent = true })
  local submit = require("gh_review.config").options.keymaps.thread.submit
  if type(submit) == "string" then
    vim.keymap.set({ "n", "i" }, submit, "<Cmd>write<CR>", { buffer = buf, silent = true })
  end
end

-- spec:
--   title       window title
--   categories  optional { { key, label, count, ticked, hl } }, or a function
--               returning it (counts change when comments are deleted)
--   preview     function(selected_set, skipped_set) -> text, spans, left_out
--               spans: see agent.message; left_out: { { thread_id, label } }
--   actions     { { key, label, fn(selected_set, skipped_set) } }
--   on_delete   optional function(item, comment): `dd` on a comment line
--   on_edit     optional function(item, comment): `e` on a comment line
--   skippable   optional: `-` leaves an item out of this send, or brings it back
--   is_empty    optional function() -> message when nothing is left to show;
--               checked on refresh, the panel closes with the message
-- on_delete and on_edit change the data themselves, then call M.refresh().
function M.open(spec)
  M.close()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  panel = { buf = buf, spec = spec, ticked = {}, skipped = {}, return_win = vim.api.nvim_get_current_win() }
  for _, c in ipairs(categories_of(spec)) do
    panel.ticked[c.key] = c.count > 0 and c.ticked ~= false
  end

  local lines = render()
  local config = fit(lines)
  config.style = "minimal"
  config.border = "rounded"
  config.title = " " .. spec.title .. " "
  config.title_pos = "center"
  panel.win = vim.api.nvim_open_win(buf, true, config)
  -- Keys here are commands: a comment buffer just closed may have left a
  -- pending startinsert.
  vim.cmd("stopinsert")
  require("gh_review.win").no_folds(panel.win)
  vim.wo[panel.win].wrap = false
  vim.wo[panel.win].cursorline = true

  -- Start on the first category, else the first comment.
  local first_row = nil
  for row in pairs(panel.rows) do
    if not first_row or row < first_row then first_row = row end
  end
  if not first_row and panel.spans[1] then first_row = panel.offset + panel.spans[1].first_line end
  if first_row then vim.api.nvim_win_set_cursor(panel.win, { first_row, 0 }) end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  local function toggle_cursor()
    local c = panel and panel.rows[cursor_line()]
    if c then M.toggle(c.key) end
  end
  if #panel.categories > 0 then
    map("<Space>", toggle_cursor)
    map("x", toggle_cursor)
    for i, c in ipairs(panel.categories) do
      if i <= 9 then map(tostring(i), function() M.toggle(c.key) end) end
    end
  end
  for _, a in ipairs(spec.actions) do
    map(a.key, function() M.act(a.key) end)
  end
  if spec.on_delete then map("dd", function() at_cursor(spec.on_delete) end) end
  if spec.on_edit then map("e", function() at_cursor(spec.on_edit) end) end
  if spec.skippable then map("-", toggle_skip) end
  map("q", M.close)
  map("<Esc>", M.close)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if panel and panel.buf == buf then panel = nil end
    end,
  })
end

return M
