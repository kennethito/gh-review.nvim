-- Side-by-side diff view with review thread signs.

local state = require("gh_review.state")
local api_mod = require("gh_review.api")
local config = require("gh_review.config")
local win = require("gh_review.win")
local unified = require("gh_review.unified")

local M = {}

-- Each open gets a number; a content fetch that finishes after a newer open
-- started is dropped, so quick ]s presses never show a stale file or line.
local open_seq = 0

-- Get the effective line number for a thread, falling back to originalLine
-- for outdated threads where line is null.
local function get_thread_line(t)
  local raw = state.get(t, "line", nil)
  if raw and type(raw) == "number" and raw > 0 then
    return raw
  end
  local orig = state.get(t, "originalLine", nil)
  if orig and type(orig) == "number" and orig > 0 then
    return orig
  end
  return 0
end

-- Remove a trailing empty string from split output.
local function trim_trailing_empty(lines)
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
end

-- "split" (side by side) or "unified", toggled per session.
local view_mode = nil

-- The user's 'diffopt' while a split diff overrides its inline setting.
local saved_diffopt = nil

-- Side by side, Vim marks the changed part of a line per 'diffopt' "inline:".
-- It is a global option, so set it while a review diff is open and put the
-- user's value back when the diff closes.
local function apply_inline()
  local mode = ({ word = "inline:word", char = "inline:char", off = "inline:none" })[config.options.diff_inline]
  if saved_diffopt == nil then saved_diffopt = vim.o.diffopt end
  local parts = {}
  for part in vim.o.diffopt:gmatch("[^,]+") do
    if not part:find("^inline:") then parts[#parts + 1] = part end
  end
  parts[#parts + 1] = mode
  -- Neovim before 0.12 has no "inline:" item; leave its default alone there.
  if not pcall(function() vim.o.diffopt = table.concat(parts, ",") end) then
    vim.o.diffopt = saved_diffopt
  end
end

local function restore_inline()
  if saved_diffopt ~= nil then
    vim.o.diffopt = saved_diffopt
    saved_diffopt = nil
  end
end

function M.view_mode()
  return view_mode or config.options.diff_view
end

-- The hunks of the unified view on the head pane, or nil in a split view.
local function unified_hunks()
  local rbuf = state.get_right_bufnr()
  if rbuf == -1 or vim.fn.bufexists(rbuf) ~= 1 then return nil end
  return vim.b[rbuf].gh_review_unified_hunks
end

-- Where a thread shows: its side and line, except that a unified view has no
-- base pane, so base-side threads show on the head line their code maps to.
local function thread_position(t)
  local line = get_thread_line(t)
  local side = state.get(t, "diffSide", "RIGHT")
  local hunks = unified_hunks()
  if side == "LEFT" and hunks and line > 0 then
    local count = vim.api.nvim_buf_line_count(state.get_right_bufnr())
    return "RIGHT", unified.base_to_head(line, hunks, count)
  end
  return side, line
end

local function get_current_side()
  if vim.api.nvim_get_current_buf() == state.get_left_bufnr() then
    return "LEFT"
  end
  return "RIGHT"
end

local function place_signs(path)
  local file_threads = state.get_threads_for_file(path)
  local lbuf = state.get_left_bufnr()
  local rbuf = state.get_right_bufnr()

  -- Clear existing extmarks
  if lbuf ~= -1 and vim.fn.bufexists(lbuf) == 1 then
    vim.api.nvim_buf_clear_namespace(lbuf, state.ns, 0, -1)
  end
  if rbuf ~= -1 and vim.fn.bufexists(rbuf) == 1 then
    vim.api.nvim_buf_clear_namespace(rbuf, state.ns, 0, -1)
  end

  for _, t in ipairs(file_threads) do
    local side, line = thread_position(t)
    -- A base-side thread drawn on the head pane of a unified view.
    local from_base = side ~= state.get(t, "diffSide", "RIGHT")
    if line > 0 then
      local target_bufnr = side == "LEFT" and lbuf or rbuf
      if target_bufnr ~= -1 and vim.fn.bufexists(target_bufnr) == 1 then
        local line_count = vim.api.nvim_buf_line_count(target_bufnr)
        if line > line_count then goto continue end

        local is_resolved = state.get(t, "isResolved", false)
        local is_pending = false
        local comments_obj = state.get(t, "comments", {})
        local comments = state.get(comments_obj, "nodes", {})
        if #comments > 0 then
          local last_comment = comments[#comments]
          local review = state.get(last_comment, "pullRequestReview", {})
          if type(review) == "table" and next(review) and state.get(review, "state", "") == "PENDING" then
            is_pending = true
          end
        end

        local sign_text = "CT"
        local sign_hl = "GHReviewThread"
        if is_pending then
          sign_text = "CP"
          sign_hl = "GHReviewThreadPending"
        elseif is_resolved then
          sign_text = "CR"
          sign_hl = "GHReviewThreadResolved"
        end

        -- Build virtual text label from first comment
        local virt_text
        if #comments > 0 then
          local first = comments[1]
          local author_obj = state.get(first, "author", {})
          local author = state.get(author_obj, "login", "")
          local body = state.get(first, "body", "")
          body = body:gsub("\r", ""):gsub("\n", " "):gsub("%s+", " ")
          if #body > 60 then
            body = body:sub(1, 57) .. "..."
          end
          if author ~= "" and body ~= "" then
            virt_text = {{ (from_base and "(base) " or "") .. author .. ": " .. body, "GHReviewVirtText" }}
          end
        end

        vim.api.nvim_buf_set_extmark(target_bufnr, state.ns, line - 1, 0, {
          sign_text = sign_text,
          sign_hl_group = sign_hl,
          virt_text = virt_text,
          virt_text_pos = "eol",
        })
      end
    end
    ::continue::
  end
end

function M.refresh_signs()
  local path = state.get_diff_path()
  if path ~= "" then
    place_signs(path)
    require("gh_review.stack.view").place_notes(path, state.get_right_bufnr())
  end
end

-- Reaction emoji for comment display
local REACTION_EMOJI = {
  THUMBS_UP = "👍",
  THUMBS_DOWN = "👎",
  LAUGH = "😄",
  HOORAY = "🎉",
  CONFUSED = "😕",
  HEART = "❤️",
  ROCKET = "🚀",
  EYES = "👀",
}

local function format_reactions(comment)
  local groups = state.get(comment, "reactionGroups", {})
  if type(groups) ~= "table" or #groups == 0 then return nil end
  local parts = {}
  for _, g in ipairs(groups) do
    local content_val = state.get(g, "content", "")
    local reactors = state.get(g, "reactors", {})
    local count = state.get(reactors, "totalCount", 0)
    if count > 0 then
      local emoji = REACTION_EMOJI[content_val] or content_val
      parts[#parts + 1] = emoji .. " " .. count
    end
  end
  if #parts == 0 then return nil end
  return "  " .. table.concat(parts, "  ")
end

-- Module-local state for floating preview window
local preview_winid = -1
local preview_bufnr = -1

local function close_preview()
  if preview_winid ~= -1 and vim.api.nvim_win_is_valid(preview_winid) then
    vim.api.nvim_win_close(preview_winid, true)
  end
  if preview_bufnr ~= -1 and vim.fn.bufexists(preview_bufnr) == 1 then
    vim.cmd("silent! bwipeout! " .. preview_bufnr)
  end
  preview_winid = -1
  preview_bufnr = -1
end

local function preview_thread_at_cursor()
  close_preview()

  local lnum = vim.fn.line(".")
  local side = get_current_side()
  local path = state.get_diff_path()
  local file_threads = state.get_threads_for_file(path)

  local t
  for _, thread in ipairs(file_threads) do
    local thread_side, thread_line = thread_position(thread)
    if thread_line > 0 then
      if thread_line == lnum and thread_side == side then
        t = thread
        break
      end
    end
  end

  if not t then
    print("No thread at this line")
    return
  end

  local comments_obj = state.get(t, "comments", {})
  local comments = state.get(comments_obj, "nodes", {})
  if #comments == 0 then
    print("No comments in this thread")
    return
  end

  -- Build content lines
  local lines = {}
  local is_resolved = state.get(t, "isResolved", false)
  lines[#lines + 1] = is_resolved and "Thread [Resolved]" or "Thread [Active]"
  lines[#lines + 1] = string.rep("─", 40)

  for _, c in ipairs(comments) do
    local author_obj = state.get(c, "author", {})
    local author = state.get(author_obj, "login", "unknown")
    local created = (state.get(c, "createdAt", "")):gsub("T.*", "")
    lines[#lines + 1] = string.format("%s (%s):", author, created)
    local body = state.get(c, "body", "")
    body = body:gsub("\r", "")
    local body_lines = vim.split(body, "\n", { plain = true })
    for _, bl in ipairs(body_lines) do
      lines[#lines + 1] = "  " .. bl
    end
    local reaction_line = format_reactions(c)
    if reaction_line then
      lines[#lines + 1] = reaction_line
    end
    lines[#lines + 1] = ""
  end

  -- Remove trailing blank line
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end

  -- Calculate dimensions
  local max_width = 0
  for _, l in ipairs(lines) do
    if #l > max_width then max_width = #l end
  end
  max_width = math.min(math.max(max_width + 2, 30), 80)
  local height = math.min(#lines, 20)

  -- Create buffer and window
  preview_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(preview_bufnr, 0, -1, false, lines)
  vim.bo[preview_bufnr].buftype = "nofile"
  vim.bo[preview_bufnr].modifiable = false
  vim.bo[preview_bufnr].filetype = "gh-review-thread"

  preview_winid = vim.api.nvim_open_win(preview_bufnr, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = max_width,
    height = height,
    border = "rounded",
    style = "minimal",
  })
  win.no_folds(preview_winid)

  -- Close on q, Esc, or BufLeave
  local opts = { buffer = preview_bufnr, silent = true }
  vim.keymap.set("n", "q", close_preview, opts)
  vim.keymap.set("n", "<Esc>", close_preview, opts)
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = preview_bufnr,
    once = true,
    callback = close_preview,
  })
end

local function open_thread_at_cursor()
  local lnum = vim.fn.line(".")
  local side = get_current_side()
  local path = state.get_diff_path()
  local file_threads = state.get_threads_for_file(path)

  for _, t in ipairs(file_threads) do
    local thread_side, thread_line = thread_position(t)
    if thread_line > 0 then
      if thread_line == lnum and thread_side == side then
        require("gh_review.thread").open(t.id)
        return
      end
    end
  end

  print("No thread at this line")
end

local function create_comment_at_cursor()
  local lnum = vim.fn.line(".")
  local side = get_current_side()
  local path = state.get_diff_path()
  -- A unified view has no base pane: removed lines shown above this line can
  -- only be commented on from here.
  local hunks = unified_hunks()
  local removed = hunks and unified.removed_above(lnum, hunks, vim.api.nvim_buf_line_count(0))
  if removed then
    vim.ui.select({ "This line", "The removed lines above (base side)" }, { prompt = "Comment on:" },
      function(choice, idx)
        if not choice then return end
        if idx == 2 then
          require("gh_review.thread").open_new(path, removed[1], removed[2], "LEFT")
        else
          require("gh_review.thread").open_new(path, lnum, lnum, side)
        end
      end)
    return
  end
  require("gh_review.thread").open_new(path, lnum, lnum, side)
end

-- ]c / [c: Vim's own diff jumps in a split view; hunk starts in a unified one.
local function jump_hunk(dir)
  local hunks = unified_hunks()
  if not hunks then
    vim.cmd("normal! " .. (dir > 0 and "]c" or "[c"))
    return
  end
  local lnum = vim.fn.line(".")
  local starts = unified.starts(hunks, vim.api.nvim_buf_line_count(0))
  local target = nil
  for _, line in ipairs(starts) do
    if dir > 0 and line > lnum and (not target or line < target) then target = line end
    if dir < 0 and line < lnum and (not target or line > target) then target = line end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.cmd("normal! zv")
  else
    print("No more changes")
  end
end

local function create_comment_visual()
  local start_lnum = math.min(vim.fn.line("v"), vim.fn.line("."))
  local end_lnum = math.max(vim.fn.line("v"), vim.fn.line("."))
  local side = get_current_side()
  local path = state.get_diff_path()
  require("gh_review.thread").open_new(path, start_lnum, end_lnum, side)
end

local function create_suggestion_at_cursor()
  if get_current_side() ~= "RIGHT" then
    print("Suggestions are only available in the head (right) buffer")
    return
  end
  local lnum = vim.fn.line(".")
  local path = state.get_diff_path()
  local code_line = vim.fn.getline(lnum)
  local suggestion = "```suggestion\n" .. code_line .. "\n```"
  require("gh_review.thread").open_new(path, lnum, lnum, "RIGHT", suggestion)
end

local function create_suggestion_visual()
  if get_current_side() ~= "RIGHT" then
    print("Suggestions are only available in the head (right) buffer")
    return
  end
  local start_lnum = math.min(vim.fn.line("v"), vim.fn.line("."))
  local end_lnum = math.max(vim.fn.line("v"), vim.fn.line("."))
  local path = state.get_diff_path()
  local buf_lines = vim.api.nvim_buf_get_lines(0, start_lnum - 1, end_lnum, false)
  local suggestion = "```suggestion\n" .. table.concat(buf_lines, "\n") .. "\n```"
  require("gh_review.thread").open_new(path, start_lnum, end_lnum, "RIGHT", suggestion)
end

local function jump_to_next_thread()
  local lnum = vim.fn.line(".")
  local side = get_current_side()
  local path = state.get_diff_path()
  local file_threads = state.get_threads_for_file(path)

  local next_line = 999999
  for _, t in ipairs(file_threads) do
    local thread_side, thread_line = thread_position(t)
    if thread_line > 0 then
      if thread_side == side and thread_line > lnum and thread_line < next_line then
        next_line = thread_line
      end
    end
  end

  if next_line < 999999 then
    vim.api.nvim_win_set_cursor(0, { next_line, 0 })
  else
    print("No more threads")
  end
end

local function jump_to_prev_thread()
  local lnum = vim.fn.line(".")
  local side = get_current_side()
  local path = state.get_diff_path()
  local file_threads = state.get_threads_for_file(path)

  local prev_line = 0
  for _, t in ipairs(file_threads) do
    local thread_side, thread_line = thread_position(t)
    if thread_line > 0 then
      if thread_side == side and thread_line < lnum and thread_line > prev_line then
        prev_line = thread_line
      end
    end
  end

  if prev_line > 0 then
    vim.api.nvim_win_set_cursor(0, { prev_line, 0 })
  else
    print("No more threads")
  end
end

local function write_buffer(bufnr, path)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.fn.writefile(lines, path)
  vim.bo[bufnr].modified = false
  vim.b[bufnr].gh_review_file_mtime = vim.fn.getftime(path)
  local size = vim.fn.getfsize(path)
  print(string.format('"%s" %dL, %dB written', path, #lines, size))
end

local function check_external_change(bufnr)
  local path = vim.b[bufnr].gh_review_file_path
  if not path or path == "" then return end
  local old_mtime = vim.b[bufnr].gh_review_file_mtime or 0
  local cur_mtime = vim.fn.getftime(path)
  if cur_mtime <= old_mtime then return end
  vim.b[bufnr].gh_review_file_mtime = cur_mtime
  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("%s changed on disk. Reload?", path),
  }, function(choice)
    if choice ~= "Yes" then return end
    local new_content = vim.fn.readfile(path)
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
      vim.fn.win_gotoid(winid)
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_content)
    vim.bo[bufnr].modified = false
    vim.cmd("diffupdate")
    vim.cmd("redraw")
    print("Reloaded from disk")
  end)
end

local syntax_map = {
  ts = "typescript",
  tsx = "typescriptreact",
  js = "javascript",
  jsx = "javascriptreact",
  py = "python",
  rb = "ruby",
  rs = "rust",
  go = "go",
  java = "java",
  kt = "kotlin",
  kts = "kotlin",
  swift = "swift",
  php = "php",
  lua = "lua",
  pl = "perl",
  pm = "perl",
  sh = "sh",
  bash = "sh",
  zsh = "zsh",
  vim = "vim",
  el = "lisp",
  ex = "elixir",
  exs = "elixir",
  erl = "erlang",
  hs = "haskell",
  scala = "scala",
  r = "r",
  yml = "yaml",
  md = "markdown",
  h = "c",
  hpp = "cpp",
  cc = "cpp",
  cxx = "cpp",
  cs = "cs",
  m = "objc",
  mm = "objcpp",
}

-- Action declaration for diff buffers. `comment` and `suggestion` each own a
-- normal-mode and a visual-mode mapping with different handlers. M.goto_file
-- and M.close_diff are referenced through closures because they are defined
-- further down the module.
local ACTIONS = {
  thread_open  = { { "n", open_thread_at_cursor,       "Open review thread" } },
  comment      = { { "n", create_comment_at_cursor,    "New comment" },
                   { "x", create_comment_visual,       "New comment (range)" } },
  suggestion   = { { "n", create_suggestion_at_cursor, "New suggestion" },
                   { "x", create_suggestion_visual,    "New suggestion (range)" } },
  next_thread  = { { "n", jump_to_next_thread,         "Next review thread" } },
  prev_thread  = { { "n", jump_to_prev_thread,         "Previous review thread" } },
  preview      = { { "n", preview_thread_at_cursor,    "Preview thread" } },
  toggle_files = { { "n", function() require("gh_review.files").toggle() end,
                     "Toggle files list" } },
  goto_file    = { { "n", function() M.goto_file() end, "Go to file (checkout only)" } },
  to_stack     = { { "n", function()
    require("gh_review.files").show_in_stack(state.get_diff_path(), vim.fn.line("."), get_current_side())
  end, "Show this function in the stack view" } },
  next_frame   = { { "n", function() require("gh_review.stack.view").step(1) end, "Next changed frame" } },
  prev_frame   = { { "n", function() require("gh_review.stack.view").step(-1) end, "Previous changed frame" } },
  help         = { { "n", function() require("gh_review.help").open() end, "Show keys and commands" } },
  toggle_view  = { { "n", function() M.toggle_view() end, "Toggle side-by-side / unified" } },
  next_hunk    = { { "n", function() jump_hunk(1) end, "Next change" } },
  prev_hunk    = { { "n", function() jump_hunk(-1) end, "Previous change" } },
  close        = { { "n", function() M.close_diff() end, "Close diff" } },
  send              = { { "n", function() require("gh_review").send() end, "Send comments to agent" } },
  scope_pr          = { { "n", function() require("gh_review").set_scope("pr") end, "Scope: PR" } },
  scope_branch      = { { "n", function() require("gh_review").set_scope("branch") end, "Scope: branch" } },
  scope_uncommitted = { { "n", function() require("gh_review").set_scope("uncommitted") end, "Scope: uncommitted" } },
  scope_turn        = { { "n", function() require("gh_review").set_scope("turn") end, "Scope: last turn" } },
}

local function setup_diff_buffer(bufnr, name, path, content, real_file)
  if real_file then
    -- Real file on disk: don't touch buftype or content
    vim.bo[bufnr].bufhidden = "hide"
  else
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    vim.bo[bufnr].modifiable = false
  end

  -- Skip for real files: :edit already set up filetype/Treesitter/LSP, which this would clobber.
  if not real_file then
    local ext = vim.fn.fnamemodify(path, ":e")
    if ext and ext ~= "" then
      local syn = syntax_map[ext] or ext
      vim.cmd("setlocal syntax=" .. syn)
    end
  end

  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    -- Real files keep their window after the diff closes, so remember the
    -- options we override here and restore them in close_diff. Capture once,
    -- before the first override, so we never save already-diffed values.
    if real_file and state.get_saved_win_opts() == nil then
      state.set_saved_win_opts({
        winid = winid,
        foldmethod = vim.wo[winid].foldmethod,
        signcolumn = vim.wo[winid].signcolumn,
        number = vim.wo[winid].number,
      })
    end
    -- foldmethod is not set here: :diffthis forces it to "diff" anyway.
    vim.wo[winid].signcolumn = "yes"
    vim.wo[winid].number = false
  end

  -- Mark buffer so the fold guard can identify it
  vim.b[bufnr].gh_review_diff = true

  -- Diff-buffer-local keymaps
  config.apply_keymaps(bufnr, "diff", ACTIONS)
end

-- Make both diff panes use the same highlighting engine.
--
-- On a local checkout the head buffer is a real file opened with :edit, so it
-- has a filetype and Neovim has started treesitter on it. The base buffer is
-- always a scratch buffer carrying only `setlocal syntax=`. Left alone, the two
-- panes render identical code in different colours -- @keyword against
-- Statement, @comment against Comment -- which reads as the diff itself being
-- wrong rather than as a highlighting mismatch.
--
-- The head pane is the reference: mirror whatever it ended up with rather than
-- mapping the extension to a parser name ourselves, since it already knows its
-- own language. When it has no treesitter, both panes are on regex syntax
-- loaded from the same syntax file, so there is nothing to do.
--
-- vim.treesitter.start attaches only the highlighter. It fires no FileType
-- autocmd, so the scratch buffer still never attracts LSP clients or linters,
-- which is why setup_diff_buffer sets `syntax=` rather than `filetype=`.
function M.sync_highlighting(left_bufnr, right_bufnr)
  if not (vim.api.nvim_buf_is_valid(left_bufnr) and vim.api.nvim_buf_is_valid(right_bufnr)) then
    return
  end
  if vim.treesitter.highlighter.active[right_bufnr] == nil then return end
  if vim.treesitter.highlighter.active[left_bufnr] ~= nil then return end

  local ok, parser = pcall(vim.treesitter.get_parser, right_bufnr)
  if not ok or not parser then return end

  -- vim.treesitter.start clears 'syntax' itself, so the base pane does not end
  -- up highlighted twice.
  pcall(vim.treesitter.start, left_bufnr, parser:lang())
end

local function show_diff(path, left_content, right_content, line, side)
  local left_name = "gh-review://LEFT/" .. path
  local right_name = "gh-review://RIGHT/" .. path

  -- Clean up existing left diff window, or the unshown base buffer of a
  -- unified view
  local old_left = state.get_left_bufnr()
  if old_left ~= -1 and vim.fn.bufexists(old_left) == 1 then
    local winid = vim.fn.bufwinid(old_left)
    if winid ~= -1 then
      vim.fn.win_gotoid(winid)
      win.close_current()
    else
      vim.cmd("silent! bwipeout! " .. old_left)
    end
  end

  -- Find target window: reuse existing right, or go above files list
  local old_right = state.get_right_bufnr()
  if old_right ~= -1 and vim.fn.bufexists(old_right) == 1 and vim.fn.bufwinid(old_right) ~= -1 then
    vim.fn.win_gotoid(vim.fn.bufwinid(old_right))
    vim.cmd("diffoff")
  else
    local fb = state.get_files_bufnr()
    local files_winid = fb ~= -1 and vim.fn.bufwinid(fb) or -1
    if files_winid ~= -1 then
      vim.fn.win_gotoid(files_winid)
      -- The diff goes above a bottom list, or to the right of a left one.
      local left = require("gh_review.config").options.files_position == "left"
      vim.cmd(left and "wincmd l" or "wincmd k")
      -- If we didn't move, files is the only window -- split next to it
      if vim.fn.win_getid() == files_winid then
        vim.cmd(left and "rightbelow vsplit" or "aboveleft split")
      end
    end
  end

  -- Set up the right (head) buffer.
  local right_bufnr
  if state.is_local_checkout() then
    -- path is repo-root-relative; make it absolute so :edit works from a subdirectory.
    local root = state.get_local_info().root or vim.fs.root(0, ".git")
    local abs_path = root and (root .. "/" .. path) or path
    vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
    right_bufnr = vim.api.nvim_get_current_buf()
  else
    right_bufnr = vim.fn.bufnr(right_name, true)
    vim.cmd("noautocmd buffer " .. right_bufnr)
  end
  state.set_right_bufnr(right_bufnr)
  setup_diff_buffer(right_bufnr, right_name, path, right_content, state.is_local_checkout())
  -- Drop what a unified view of this file left behind before redrawing.
  unified.clear(right_bufnr)
  if vim.wo.foldmethod == "manual" then vim.cmd("silent! normal! zE") end

  if M.view_mode() == "unified" then
    -- The base buffer still exists, unshown: base-side comments read their
    -- code context from it.
    local left_bufnr = vim.fn.bufnr(left_name, true)
    state.set_left_bufnr(left_bufnr)
    vim.api.nvim_buf_call(left_bufnr, function()
      setup_diff_buffer(left_bufnr, left_name, path, left_content)
    end)
    return M.show_unified(path, left_bufnr, right_bufnr, line, side)
  end

  apply_inline()

  -- Set up the left (base) buffer in a vertical split
  vim.cmd("noautocmd aboveleft vsplit")
  local left_bufnr = vim.fn.bufnr(left_name, true)
  vim.cmd("noautocmd buffer " .. left_bufnr)
  state.set_left_bufnr(left_bufnr)
  setup_diff_buffer(left_bufnr, left_name, path, left_content)

  M.sync_highlighting(left_bufnr, right_bufnr)

  -- Enable diff mode on both -- left window first, then right. Fold settings
  -- go on after :diffthis, which forces foldmethod=diff and foldlevel=0 itself.
  local fold = config.fold_settings()
  local function apply_fold()
    vim.wo.foldenable = fold.foldenable
    if fold.foldlevel ~= nil then
      vim.wo.foldlevel = fold.foldlevel
    end
  end

  vim.cmd("wincmd p")
  vim.cmd("diffthis")
  vim.wo.wrap = true
  apply_fold()
  vim.cmd("wincmd p")
  vim.cmd("diffthis")
  vim.wo.wrap = true
  apply_fold()

  -- Set winbar on both diff windows
  local base_short = state.get_merge_base_oid()
  if base_short == "" then base_short = state.get_base_oid() end
  base_short = base_short:sub(1, 7)
  local label, head_label
  if state.is_local_mode() then
    label = state.get_scope()
    head_label = "working tree"
  else
    label = string.format("PR #%d", state.get_pr_number())
    head_label = string.format("head (%s)", state.get_head_oid():sub(1, 7))
  end
  local left_winid = vim.fn.bufwinid(left_bufnr)
  local right_winid = vim.fn.bufwinid(right_bufnr)
  if left_winid ~= -1 then
    vim.wo[left_winid].winbar = string.format(" %s · %s · base (%s)", label, path, base_short)
  end
  if right_winid ~= -1 then
    vim.wo[right_winid].winbar = string.format(" %s · %s · %s", label, path, head_label)
  end

  -- Place signs for review threads, and the stack view's notes
  place_signs(path)
  require("gh_review.stack.view").place_notes(path, right_bufnr)

  -- Position cursor in the right (head) window: at the requested line (a
  -- stack frame), unfolded and centred, or at the top.
  vim.fn.win_gotoid(vim.fn.bufwinid(right_bufnr))
  if line then
    -- A removed function only exists on the base side.
    if side == "LEFT" then vim.fn.win_gotoid(vim.fn.bufwinid(left_bufnr)) end
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
    vim.cmd("normal! zvzz")
    -- The fold workaround below would close the fold the frame sits in.
    return
  end
  vim.cmd("normal! gg")

  -- Workaround: Neovim fails to render syntax concealing when
  -- foldmethod=diff has closed folds.  Opening all folds, forcing
  -- a redraw, then re-closing them refreshes the conceal state.
  -- Only folds that will actually be closed need this, and running it
  -- otherwise would zM folds the user asked to keep open.
  if not (fold.foldenable and fold.foldlevel == 0) then
    return
  end
  vim.defer_fn(function()
    for _, bid in ipairs({ left_bufnr, right_bufnr }) do
      local wid = vim.fn.bufwinid(bid)
      if wid ~= -1 then
        vim.fn.win_execute(wid, "normal! zR")
      end
    end
    vim.cmd("redraw")
    for _, bid in ipairs({ left_bufnr, right_bufnr }) do
      local wid = vim.fn.bufwinid(bid)
      if wid ~= -1 then
        vim.fn.win_execute(wid, "normal! zM")
      end
    end
  end, 50)
end

local function winbar_labels()
  local base_short = state.get_merge_base_oid()
  if base_short == "" then base_short = state.get_base_oid() end
  base_short = base_short:sub(1, 7)
  if state.is_local_mode() then
    return state.get_scope(), "working tree", base_short
  end
  return string.format("PR #%d", state.get_pr_number()),
    string.format("head (%s)", state.get_head_oid():sub(1, 7)), base_short
end

-- One window: the head file with the diff drawn on it (see unified.lua).
function M.show_unified(path, left_bufnr, right_bufnr, line, side)
  local winid = vim.fn.bufwinid(right_bufnr)
  vim.fn.win_gotoid(winid)
  vim.wo.diff = false
  vim.wo.wrap = true
  restore_inline()
  unified.inline = config.options.diff_inline
  local base_lines = vim.api.nvim_buf_get_lines(left_bufnr, 0, -1, false)
  local hunks = unified.render(right_bufnr, base_lines)
  local count = vim.api.nvim_buf_line_count(right_bufnr)
  local fold = config.fold_settings()
  if fold.foldenable then
    unified.fold(hunks, count, fold.foldlevel)
  else
    vim.wo.foldenable = false
  end

  local label, head_label, base_short = winbar_labels()
  vim.wo[winid].winbar = string.format(" %s · %s · unified: %s vs base (%s)", label, path, head_label, base_short)

  place_signs(path)
  require("gh_review.stack.view").place_notes(path, right_bufnr)

  if line then
    -- A base line (a removed function) shows where its block hangs.
    if side == "LEFT" then line = unified.base_to_head(line, hunks, count) end
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, count), 0 })
    vim.cmd("normal! zvzz")
  else
    local starts = unified.starts(hunks, count)
    pcall(vim.api.nvim_win_set_cursor, 0, { starts[1] or 1, 0 })
    vim.cmd("normal! zvzz")
  end
end

-- Switch between side-by-side and unified, keeping the file and line.
function M.toggle_view()
  view_mode = M.view_mode() == "unified" and "split" or "unified"
  local path = state.get_diff_path()
  local rbuf = state.get_right_bufnr()
  if path == "" or rbuf == -1 then
    print("Diff view: " .. view_mode)
    return
  end
  local line = 1
  local rwin = vim.fn.bufwinid(rbuf)
  local lwin = vim.fn.bufwinid(state.get_left_bufnr())
  if vim.api.nvim_get_current_win() == lwin and lwin ~= -1 then
    -- From the base pane: open the unified view where that base line shows.
    M.open(path, { line = vim.api.nvim_win_get_cursor(lwin)[1], side = "LEFT" })
    return
  end
  if rwin ~= -1 then line = vim.api.nvim_win_get_cursor(rwin)[1] end
  M.open(path, { line = line })
end

local function fetch_graphql_content(ref, path, callback)
  local graphql = require("gh_review.graphql")
  local owner = state.get_owner()
  local name = state.get_name()
  local query = [[
    query($owner: String!, $name: String!, $expression: String!) {
      repository(owner: $owner, name: $name) {
        object(expression: $expression) {
          ... on Blob {
            text
          }
        }
      }
    }
  ]]
  local gql_vars = {
    owner = owner,
    name = name,
    expression = ref .. ":" .. path,
  }
  api_mod.graphql(query, gql_vars, function(result)
    local data = state.get(result, "data", {})
    local repo = type(data) == "table" and state.get(data, "repository", {}) or {}
    local obj = type(repo) == "table" and state.get(repo, "object", {}) or {}
    local text = type(obj) == "table" and state.get(obj, "text", "") or ""
    local content = vim.split(text, "\n", { plain = true, trimempty = false })
    trim_trailing_empty(content)
    callback(content)
  end)
end

local function fetch_git_content(ref, path, callback)
  local cmd = string.format("git show %s:%s",
    vim.fn.shellescape(ref), vim.fn.shellescape(path))
  local local_mode = state.is_local_mode()
  local cwd = local_mode and state.get_local_info().root or nil
  vim.system({ "bash", "-c", cmd }, { text = true, cwd = cwd }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        -- Local scopes have no GitHub repo to ask; a missing blob is an empty side.
        if local_mode then
          callback({})
          return
        end
        -- Fall back to GraphQL blob query
        fetch_graphql_content(ref, path, callback)
        return
      end
      local content = vim.split(obj.stdout or "", "\n", { plain = true, trimempty = false })
      trim_trailing_empty(content)
      callback(content)
    end)
  end)
end

local function fetch_contents(base_oid, head_oid, path, line, seq, side)
  -- Determine change type for this file
  local change_type = "MODIFIED"
  -- A renamed file's base content lives at its old path.
  local base_path = path
  for _, f in ipairs(state.get_changed_files()) do
    if f.path == path then
      change_type = state.get(f, "changeType", "MODIFIED")
      base_path = state.get(f, "previousPath", path)
      break
    end
  end

  local left_content = {}
  local right_content = {}
  local fetches_done = 0
  local total_fetches = 2

  local function handle_done()
    fetches_done = fetches_done + 1
    if fetches_done >= total_fetches then
      vim.schedule(function()
        if seq == open_seq then show_diff(path, left_content, right_content, line, side) end
      end)
    end
  end

  -- Fetch left (base) content
  if change_type == "ADDED" then
    left_content = {}
    fetches_done = fetches_done + 1
  else
    fetch_git_content(base_oid, base_path, function(content)
      left_content = content
      handle_done()
    end)
  end

  -- Fetch right (head) content (skip for local checkout -- we open the real file)
  if change_type == "DELETED" or state.is_local_checkout() then
    fetches_done = fetches_done + 1
  else
    fetch_git_content(head_oid, path, function(content)
      right_content = content
      handle_done()
    end)
  end

  -- Check if both were synchronous (ADDED/DELETED)
  if fetches_done >= total_fetches then
    vim.schedule(function()
      if seq == open_seq then show_diff(path, left_content, right_content, line, side) end
    end)
  end
end

-- opts.line: put the cursor on this line once the diff is shown, in the head
-- pane, or the base pane with opts.side = "LEFT".
function M.open(path, opts)
  open_seq = open_seq + 1
  state.set_diff_path(path)

  local base_oid = state.get_merge_base_oid()
  if base_oid == "" then
    base_oid = state.get_base_oid()
  end
  local head_oid = state.get_head_oid()

  fetch_contents(base_oid, head_oid, path, opts and opts.line or nil, open_seq, opts and opts.side or nil)
end

function M.goto_file()
  if not state.is_local_checkout() then
    print("gF requires a local checkout review")
    return
  end
  if get_current_side() ~= "RIGHT" then
    print("gF works from the right (head) buffer only")
    return
  end

  local lnum = vim.fn.line(".")
  local path = state.get_diff_path()
  local right = state.get_right_bufnr()
  local winid = right ~= -1 and vim.fn.bufwinid(right) or -1

  M.close_diff()

  if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
    vim.fn.win_gotoid(winid)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local line_count = vim.api.nvim_buf_line_count(0)
  if lnum > line_count then lnum = line_count end
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
end

-- Open a file that is not part of the change, at a line, in the diff area:
-- a function on a call path into the change, where a diff would show nothing.
function M.open_plain(path, line)
  if state.get_left_bufnr() ~= -1 then M.close_diff() end
  open_seq = open_seq + 1
  local fb = state.get_files_bufnr()
  local files_winid = fb ~= -1 and vim.fn.bufwinid(fb) or -1
  if files_winid ~= -1 then
    vim.fn.win_gotoid(files_winid)
    local left = config.options.files_position == "left"
    vim.cmd(left and "wincmd l" or "wincmd k")
    if vim.fn.win_getid() == files_winid then
      vim.cmd(left and "rightbelow vsplit" or "aboveleft split")
    end
  end
  local root = state.get_local_info().root or vim.fs.root(0, ".git") or vim.fn.getcwd()
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. path))
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line or 1, vim.api.nvim_buf_line_count(0)), 0 })
  vim.cmd("normal! zvzz")
end

function M.close_diff()
  local left = state.get_left_bufnr()
  local right = state.get_right_bufnr()

  -- Clear guard flags before closing so the fold guard doesn't interfere
  if left ~= -1 and vim.fn.bufexists(left) == 1 then
    vim.b[left].gh_review_diff = false
  end
  if right ~= -1 and vim.fn.bufexists(right) == 1 then
    vim.b[right].gh_review_diff = false
  end

  -- The head is often a real file that stays open: drop the stack notes and
  -- anything a unified view drew on it, and its folds.
  if right ~= -1 and vim.fn.bufexists(right) == 1 then
    vim.api.nvim_buf_clear_namespace(right, require("gh_review.stack.view").ns, 0, -1)
    local had_unified = vim.b[right].gh_review_unified_hunks ~= nil
    unified.clear(right)
    local rwin = vim.fn.bufwinid(right)
    if had_unified and rwin ~= -1 then
      vim.api.nvim_win_call(rwin, function() vim.cmd("silent! normal! zE") end)
    end
  end

  -- Close the left diff window (a unified view's base buffer is unshown)
  if left ~= -1 and vim.fn.bufexists(left) == 1 then
    local winid = vim.fn.bufwinid(left)
    if winid ~= -1 then
      vim.fn.win_gotoid(winid)
      win.close_current()
    else
      vim.cmd("silent! bwipeout! " .. left)
    end
  end

  -- For real file buffers just turn off diff; for scratch buffers replace with empty
  if right ~= -1 and vim.fn.bufexists(right) == 1 then
    local winid = vim.fn.bufwinid(right)
    if winid ~= -1 then
      vim.fn.win_gotoid(winid)
      vim.cmd("diffoff")
      if not state.is_local_checkout() then
        vim.cmd("enew")
      else
        -- Real file buffer stays open: drop our keymaps so `q`/`K` don't shadow
        -- macro recording / LSP hover. Walking ACTIONS keeps this in step with
        -- whatever setup_diff_buffer applied, including remapped keys.
        config.clear_keymaps(right, "diff", ACTIONS)
        -- Restore the window options the diff overrode. :diffoff leaves
        -- foldmethod as "diff" (we set it before :diffthis), and it never
        -- touches signcolumn/number, so the real file would otherwise keep
        -- diff folding, a forced signcolumn, and hidden line numbers.
        local wo = state.get_saved_win_opts()
        if wo and wo.winid == winid then
          vim.wo[winid].foldmethod = wo.foldmethod
          vim.wo[winid].signcolumn = wo.signcolumn
          vim.wo[winid].number = wo.number
        end
      end
    end
  end

  state.set_left_bufnr(-1)
  state.set_right_bufnr(-1)
  state.set_diff_path("")
  state.set_saved_win_opts(nil)
  restore_inline()

  -- Return focus to the files list
  local fb = state.get_files_bufnr()
  local files_winid = fb ~= -1 and vim.fn.bufwinid(fb) or -1
  if files_winid ~= -1 then
    vim.fn.win_gotoid(files_winid)
  end
end


-- For the `?` help, which lists what each surface maps.
M.ACTIONS = ACTIONS

return M
