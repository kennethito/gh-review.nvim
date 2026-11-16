-- User configuration for gh-review.nvim.
--
-- Consumers must read `M.options` at use time rather than capturing it at
-- module load: plugin/gh_review.lua is sourced before any setup() call can run.

local M = {}

M.defaults = {
  fold = { enabled = true, level = 0 },
  -- Last-turn baseline: inside herdr, watch agents and snapshot when one starts
  -- working; refresh an open local review when its turn ends.
  turn = { watch = true, refresh_on_end = true },
  -- Stack view: call stacks from entry points down to the changed functions.
  stack = {
    notes = true,           -- virtual text on changed functions in the diff
    data_edges = true,      -- ◆ string keys written by one changed function, read by another
    tests = false,          -- walk callers in test files too
    max_depth = 12,
    max_frames = 400,
    max_context_hops = 3,   -- unchanged frames climbed above changed code
  },
  -- Save PR comments and replies on this machine until :GHReviewSubmit
  -- publishes them; false posts each one to GitHub when you write it.
  pr_drafts = true,
  -- "split" (side by side) or "unified" (the head file with removed lines drawn in).
  diff_view = "split",
  -- Jumping from the head pane (gd, gF, :e) to another changed file opens it
  -- as a diff; to any other file ends the diff.
  diff_follow = true,
  -- What to mark inside a changed line: "word", "char", or "off".
  diff_inline = "word",
  -- Where the files list sits, and its height (bottom) or width (left).
  files_position = "bottom",
  -- How the changed files are listed: "flat", or "tree" (folders you can fold).
  files_view = "flat",
  files_size = { bottom = 12, left = 50 },
  keymaps = {
    -- Scope and send keys are off in the diff by default: the head pane is the
    -- real file there, where single letters and g-prefixes are already taken.
    diff = {
      thread_open  = "gt",
      comment      = "gc",
      suggestion   = "gs",
      next_thread  = "]t",
      prev_thread  = "[t",
      preview      = "K",
      toggle_files = "gf",
      goto_file    = "gF",
      to_stack     = "gS",
      close        = "q",
      send              = false,
      scope_pr          = false,
      scope_branch      = false,
      scope_uncommitted = false,
      scope_turn        = false,
      next_frame        = "]s",
      prev_frame        = "[s",
      -- The head pane is your real file, where `?` is backward search.
      help              = "g?",
      toggle_view       = "gu",
      next_hunk         = "]c",
      prev_hunk         = "[c",
    },
    files = {
      open          = "<CR>",
      toggle_viewed = "<Space>",
      refresh       = "R",
      toggle_files  = "gf",
      close         = "q",
      send              = "S",
      scope_pr          = "p",
      scope_branch      = "b",
      scope_uncommitted = "u",
      scope_turn        = "t",
      toggle_stack      = "s",
      toggle_fold       = "<Tab>",
      toggle_position   = "P",
      toggle_tree       = "T",
      help              = "?",
      toggle_view       = "gu",
    },
    thread = {
      submit       = "<C-s>",
      resolve      = "<C-r>",
      close        = "q",
      close_insert = "<C-q>",
      help         = "g?",
      toggle_agent = "ga",
    },
  },
}

M.options = vim.deepcopy(M.defaults)

-- Restore defaults. Used by the test suite between cases.
function M.reset()
  M.options = vim.deepcopy(M.defaults)
end

local function warn(msg)
  vim.notify("[gh-review] " .. msg, vim.log.levels.WARN)
end

local function validate_keymaps(keymaps)
  if keymaps == nil then return true end
  if type(keymaps) ~= "table" then
    warn("keymaps must be a table")
    return false
  end

  local ok = true
  for surface, actions in pairs(keymaps) do
    local known = M.defaults.keymaps[surface]
    if known == nil then
      warn(string.format("unknown keymap surface %q (expected diff, files, or thread)", surface))
      ok = false
    elseif type(actions) ~= "table" then
      warn(string.format("keymaps.%s must be a table", surface))
      ok = false
    else
      for action, lhs in pairs(actions) do
        if known[action] == nil then
          warn(string.format("unknown keymap action %q for surface %q", action, surface))
          ok = false
        elseif type(lhs) ~= "string" and lhs ~= false then
          warn(string.format("keymaps.%s.%s must be a string or false", surface, action))
          ok = false
        end
      end
    end
  end
  return ok
end

local function validate_fold(fold)
  if fold == nil then return true end
  if type(fold) ~= "table" then
    warn("fold must be a table or false")
    return false
  end

  local ok = true
  for key, value in pairs(fold) do
    if key == "enabled" then
      if type(value) ~= "boolean" then
        warn("fold.enabled must be a boolean")
        ok = false
      end
    elseif key == "level" then
      if type(value) ~= "number" then
        warn("fold.level must be a number")
        ok = false
      end
    else
      warn(string.format("unknown fold option %q (expected enabled or level)", key))
      ok = false
    end
  end
  return ok
end

local function validate_turn(turn)
  if turn == nil then return true end
  if type(turn) ~= "table" then
    warn("turn must be a table")
    return false
  end

  local ok = true
  for key, value in pairs(turn) do
    if key ~= "watch" and key ~= "refresh_on_end" then
      warn(string.format("unknown turn option %q (expected watch or refresh_on_end)", key))
      ok = false
    elseif type(value) ~= "boolean" then
      warn(string.format("turn.%s must be a boolean", key))
      ok = false
    end
  end
  return ok
end

local STACK_TYPES = {
  notes = "boolean", data_edges = "boolean", tests = "boolean",
  max_depth = "number", max_frames = "number", max_context_hops = "number",
}

local function validate_stack(stack)
  if stack == nil then return true end
  if type(stack) ~= "table" then
    warn("stack must be a table")
    return false
  end
  local ok = true
  for key, value in pairs(stack) do
    if STACK_TYPES[key] == nil then
      warn(string.format("unknown stack option %q", key))
      ok = false
    elseif type(value) ~= STACK_TYPES[key] then
      warn(string.format("stack.%s must be a %s", key, STACK_TYPES[key]))
      ok = false
    end
  end
  return ok
end

local function validate_files(opts)
  local ok = true
  if opts.files_position ~= nil and opts.files_position ~= "bottom" and opts.files_position ~= "left" then
    warn('files_position must be "bottom" or "left"')
    ok = false
  end
  if opts.files_view ~= nil and opts.files_view ~= "flat" and opts.files_view ~= "tree" then
    warn('files_view must be "flat" or "tree"')
    ok = false
  end
  if opts.files_size ~= nil then
    if type(opts.files_size) ~= "table" then
      warn("files_size must be a table")
      ok = false
    else
      for key, value in pairs(opts.files_size) do
        if (key ~= "bottom" and key ~= "left") or type(value) ~= "number" then
          warn("files_size takes numbers for bottom and left")
          ok = false
        end
      end
    end
  end
  return ok
end

-- Accept `fold = false` as shorthand for `fold = { enabled = false }`.
local function normalize(opts)
  opts = vim.deepcopy(opts or {})
  if opts.fold == false then
    opts.fold = { enabled = false }
  end
  return opts
end

-- Merge user options over the defaults. A call containing any invalid key is
-- rejected whole, so a typo fails loudly rather than half-applying.
function M.setup(opts)
  opts = normalize(opts)

  local ok = true
  for key in pairs(opts) do
    if key ~= "fold" and key ~= "keymaps" and key ~= "turn" and key ~= "stack"
      and key ~= "files_position" and key ~= "files_view" and key ~= "files_size" and key ~= "diff_view" and key ~= "pr_drafts"
      and key ~= "diff_inline" and key ~= "diff_follow" then
      warn(string.format("unknown option %q (expected fold, keymaps, turn, stack, diff_view, pr_drafts, files_position, files_view, or files_size)", key))
      ok = false
    end
  end
  if opts.diff_inline ~= nil and opts.diff_inline ~= "word" and opts.diff_inline ~= "char"
    and opts.diff_inline ~= "off" then
    warn('diff_inline must be "word", "char", or "off"')
    ok = false
  end
  if opts.diff_follow ~= nil and type(opts.diff_follow) ~= "boolean" then
    warn("diff_follow must be a boolean")
    ok = false
  end
  if opts.pr_drafts ~= nil and type(opts.pr_drafts) ~= "boolean" then
    warn("pr_drafts must be a boolean")
    ok = false
  end
  if opts.diff_view ~= nil and opts.diff_view ~= "split" and opts.diff_view ~= "unified" then
    warn('diff_view must be "split" or "unified"')
    ok = false
  end
  if not validate_stack(opts.stack) then ok = false end
  if not validate_files(opts) then ok = false end
  if not validate_fold(opts.fold) then ok = false end
  if not validate_turn(opts.turn) then ok = false end
  if not validate_keymaps(opts.keymaps) then ok = false end
  if not ok then return end

  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
end

-- Apply a module's ACTIONS declaration to a buffer using the configured keys.
-- `actions` maps an action name to a list of { mode, handler, desc } triples;
-- one action may own several mappings across modes with distinct handlers.
-- Actions configured as `false` are skipped.
function M.apply_keymaps(bufnr, surface, actions)
  local configured = M.options.keymaps[surface]
  for action, bindings in pairs(actions) do
    local lhs = configured[action]
    if type(lhs) == "string" then
      for _, binding in ipairs(bindings) do
        local mode, handler, desc = binding[1], binding[2], binding[3]
        vim.keymap.set(mode, lhs, handler, { buffer = bufnr, silent = true, desc = desc })
      end
    end
  end
end

-- Remove the mappings apply_keymaps would have set. Walks the same declaration
-- rather than a separate list, so the two cannot drift apart.
function M.clear_keymaps(bufnr, surface, actions)
  local configured = M.options.keymaps[surface]
  for action, bindings in pairs(actions) do
    local lhs = configured[action]
    if type(lhs) == "string" then
      for _, binding in ipairs(bindings) do
        pcall(vim.keymap.del, binding[1], lhs, { buffer = bufnr })
      end
    end
  end
end

-- Window options to apply after :diffthis.
--
-- :diffthis sets foldmethod=diff itself and leaves foldlevel at 0, so turning
-- folding off means actively setting foldenable=false -- not merely declining
-- to set foldmethod, which would have no effect at all.
function M.fold_settings()
  if not M.options.fold.enabled then
    return { foldenable = false }
  end
  return { foldenable = true, foldlevel = M.options.fold.level }
end

return M
