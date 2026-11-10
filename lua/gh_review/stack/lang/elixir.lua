-- Elixir adapter for the stack view: definitions and call sites from tree-sitter.
--
-- analyze(source) returns:
--   defs:  { key, module, name, min_arity, max_arity, public, clauses = { {first, last}, ... } }
--          one per module/name/arity, clauses merged; lines are 1-based.
--   calls: { module?, name, arity, line, kind, scope, from }
--          kind is "remote", "local", "capture", or "dynamic" (an inferred
--          {Module, :fun, args} triple); module is nil for unqualified calls,
--          which resolve against `scope` (the enclosing module) or its imports.
--          `from` is the key of the enclosing def or pseudo frame.
--   frames: pseudo frames for calls outside any def: ExUnit tests and module bodies.
--   imports: { [module] = { imported module, ... } }

local M = {}

M.name = "elixir"
M.extensions = { ex = true, exs = true }

local DEFINE = { def = true, defp = true, defmacro = true, defmacrop = true }
-- Unqualified calls that are syntax, not function calls.
local SPECIAL = {
  defmodule = true, alias = true, import = true, require = true, use = true,
  defstruct = true, defdelegate = true, defguard = true, defguardp = true,
  defimpl = true, defprotocol = true, defexception = true, quote = true,
  test = true, describe = true, setup = true, setup_all = true,
}

function M.available()
  return (pcall(vim.treesitter.language.add, "elixir"))
end

local function text(node, source)
  return vim.treesitter.get_node_text(node, source)
end

-- Named children without comments, which tree-sitter keeps as named nodes
-- wherever they sit (between pipeline steps, between arguments).
local function named_children(node)
  local result = {}
  for child in node:iter_children() do
    if child:named() and child:type() ~= "comment" then result[#result + 1] = child end
  end
  return result
end

local function child_of_type(node, type_name)
  for child in node:iter_children() do
    if child:type() == type_name then return child end
  end
  return nil
end

local function operator(node, source)
  local op = node:field("operator")[1]
  return op and text(op, source) or nil
end

local function key_of(module, name, arity)
  return string.format("%s.%s/%d", module or "?", name, arity)
end
M.key_of = key_of

-- The module a node names: an alias (expanded through the file's aliases),
-- __MODULE__, a chain of those (__MODULE__.Private), or an Erlang atom.
local function resolve_module(node, source, ctx)
  local kind = node:type()
  if kind == "alias" then
    local name = text(node, source)
    local first, rest = name:match("^([^.]+)(.*)$")
    local expanded = ctx.aliases[first]
    return expanded and (expanded .. rest) or name
  elseif kind == "identifier" and text(node, source) == "__MODULE__" then
    return ctx.module
  elseif kind == "dot" then
    local parts = named_children(node)
    if #parts == 2 and parts[2]:type() == "alias" then
      local left = resolve_module(parts[1], source, ctx)
      return left and (left .. "." .. text(parts[2], source)) or nil
    end
  elseif kind == "atom" then
    return text(node, source)
  end
  return nil
end

local function arg_count(call_node)
  local args = child_of_type(call_node, "arguments")
  if not args then return 0 end
  return #named_children(args)
end

-- A call piped into (x |> f(a)) takes the piped value as its first argument.
local function piped(node, source)
  local parent = node:parent()
  return parent and parent:type() == "binary_operator" and operator(parent, source) == "|>"
    and named_children(parent)[2] == node
end

function M.analyze(source)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "elixir")
  if not ok then return nil end
  local root = parser:parse()[1]:root()

  local defs, by_key, calls, frames, imports = {}, {}, {}, {}, {}

  local function add_call(ctx, call)
    call.scope = ctx.module
    call.from = ctx.frame
    calls[#calls + 1] = call
  end

  -- {Module, :fun, [args]} next to each other, in arguments or a tuple:
  -- apply/3, :timer.apply_after/4, RPC casts, scheduled jobs.
  local function scan_triples(node, ctx)
    local items = named_children(node)
    for i = 1, #items - 2 do
      local module = resolve_module(items[i], source, ctx)
      if module and items[i + 1]:type() == "atom" and items[i + 2]:type() == "list" then
        add_call(ctx, {
          module = module,
          name = text(items[i + 1], source):sub(2),
          arity = #named_children(items[i + 2]),
          line = items[i]:start() + 1,
          kind = "dynamic",
        })
      end
    end
  end

  local walk

  local function walk_children(node, ctx)
    for child in node:iter_children() do
      if child:named() then walk(child, ctx) end
    end
  end

  local function add_def(ctx, node, keyword)
    local args = child_of_type(node, "arguments")
    local head = args and named_children(args)[1]
    if not head then return end
    if head:type() == "binary_operator" and operator(head, source) == "when" then
      head = named_children(head)[1]
    end
    local name, max_arity, defaults = nil, 0, 0
    if head:type() == "call" then
      local ident = child_of_type(head, "identifier")
      name = ident and text(ident, source)
      local params = child_of_type(head, "arguments")
      for _, param in ipairs(params and named_children(params) or {}) do
        max_arity = max_arity + 1
        if param:type() == "binary_operator" and operator(param, source) == "\\\\" then
          defaults = defaults + 1
        end
      end
    elseif head:type() == "identifier" then
      name = text(head, source)
    end
    if not name or not ctx.module then return end

    local key = key_of(ctx.module, name, max_arity)
    local first, last = node:start() + 1, node:end_() + 1
    local def = by_key[key]
    if not def then
      def = { key = key, module = ctx.module, name = name, min_arity = max_arity - defaults,
        max_arity = max_arity, public = keyword == "def" or keyword == "defmacro", clauses = {} }
      by_key[key] = def
      defs[#defs + 1] = def
    end
    def.min_arity = math.min(def.min_arity, max_arity - defaults)
    def.clauses[#def.clauses + 1] = { first, last }

    local body_ctx = setmetatable({ frame = key }, { __index = ctx })
    local block = child_of_type(node, "do_block")
    if block then walk_children(block, body_ctx) end
    -- `, do: expr` bodies live in a keywords node after the head.
    for _, arg in ipairs(named_children(args)) do
      if arg:type() == "keywords" then walk(arg, body_ctx) end
    end
  end

  walk = function(node, ctx)
    local kind = node:type()

    if kind == "call" then
      local target = named_children(node)[1]
      local target_kind = target and target:type()

      if target_kind == "identifier" then
        local word = text(target, source)
        local args = child_of_type(node, "arguments")

        if word == "defmodule" then
          local name_node = args and named_children(args)[1]
          local name = name_node and resolve_module(name_node, source, { aliases = {}, module = ctx.module })
          if name then
            -- A nested module is always named under its parent, and the parent
            -- can refer to it by its first segment.
            local full = ctx.module and (ctx.module .. "." .. name) or name
            if ctx.module then ctx.aliases[name:match("^[^.]+")] = ctx.module .. "." .. name:match("^[^.]+") end
            imports[full] = imports[full] or {}
            local module_ctx = {
              module = full,
              aliases = setmetatable({}, { __index = ctx.aliases }),
              frame = full .. " (body)",
            }
            frames[module_ctx.frame] = { key = module_ctx.frame, module = full, kind = "body",
              line = node:start() + 1 }
            local block = child_of_type(node, "do_block")
            if block then walk_children(block, module_ctx) end
          end
          return
        elseif DEFINE[word] then
          add_def(ctx, node, word)
          return
        elseif word == "alias" and args then
          local parts = named_children(args)
          local target_node = parts[1]
          if target_node and target_node:type() == "dot" and child_of_type(target_node, "tuple") then
            -- alias A.{B, C}
            local prefix = resolve_module(named_children(target_node)[1], source, ctx)
            for _, item in ipairs(named_children(child_of_type(target_node, "tuple"))) do
              local leaf = text(item, source)
              ctx.aliases[leaf:match("[^.]+$")] = prefix .. "." .. leaf
            end
          elseif target_node then
            local full = resolve_module(target_node, source, ctx)
            local as_name = nil
            local keywords = parts[2]
            if keywords and keywords:type() == "keywords" then
              for _, pair in ipairs(named_children(keywords)) do
                local pk = named_children(pair)
                if #pk == 2 and vim.trim(text(pk[1], source)) == "as:" then as_name = text(pk[2], source) end
              end
            end
            if full then ctx.aliases[as_name or full:match("[^.]+$")] = full end
          end
          return
        elseif word == "import" and args then
          local first = named_children(args)[1]
          local full = first and resolve_module(first, source, ctx)
          if full and ctx.module then
            imports[ctx.module] = imports[ctx.module] or {}
            table.insert(imports[ctx.module], full)
          end
          return
        elseif word == "test" and args then
          local label = named_children(args)[1]
          local key = string.format("%s test %s", ctx.module or "?", label and text(label, source) or "")
          frames[key] = { key = key, module = ctx.module, kind = "test", line = node:start() + 1 }
          local block = child_of_type(node, "do_block")
          if block then walk_children(block, setmetatable({ frame = key }, { __index = ctx })) end
          return
        elseif not SPECIAL[word] then
          add_call(ctx, { name = word, arity = arg_count(node) + (piped(node, source) and 1 or 0),
            line = node:start() + 1, kind = "local" })
        end
      elseif target_kind == "dot" then
        local parts = named_children(target)
        local fun = parts[#parts]
        if #parts == 2 and fun:type() == "identifier" then
          local module = resolve_module(parts[1], source, ctx)
          if module then
            add_call(ctx, { module = module, name = text(fun, source),
              arity = arg_count(node) + (piped(node, source) and 1 or 0),
              line = node:start() + 1, kind = "remote" })
          end
        end
      end

      local args = child_of_type(node, "arguments")
      if args then
        scan_triples(args, ctx)
        walk_children(args, ctx)
      end
      local block = child_of_type(node, "do_block")
      if block then walk_children(block, ctx) end
      return
    end

    if kind == "unary_operator" and operator(node, source) == "&" then
      local inner = named_children(node)[1]
      if inner and inner:type() == "binary_operator" and operator(inner, source) == "/" then
        local parts = named_children(inner)
        local fun, arity = parts[1], tonumber(parts[2] and text(parts[2], source) or "")
        if fun and arity then
          if fun:type() == "identifier" then
            add_call(ctx, { name = text(fun, source), arity = arity, line = node:start() + 1, kind = "capture" })
            return
          elseif fun:type() == "call" then
            local dot = named_children(fun)[1]
            local dparts = dot and dot:type() == "dot" and named_children(dot) or {}
            local module = #dparts == 2 and resolve_module(dparts[1], source, ctx)
            if module then
              add_call(ctx, { module = module, name = text(dparts[2], source), arity = arity,
                line = node:start() + 1, kind = "capture" })
              return
            end
          end
        end
      end
    end

    if kind == "tuple" then scan_triples(node, ctx) end
    walk_children(node, ctx)
  end

  walk(root, { module = nil, aliases = {}, frame = nil })
  return { defs = defs, calls = calls, frames = frames, imports = imports }
end

-- Does `call` (from an analyzed file) reach `def`?
function M.reaches(call, def, file)
  if call.name ~= def.name or call.arity < def.min_arity or call.arity > def.max_arity then
    return false
  end
  if call.module then return call.module == def.module end
  if call.scope == def.module then return true end
  for _, imported in ipairs(file.imports[call.scope] or {}) do
    if imported == def.module then return true end
  end
  return false
end

function M.is_test(path)
  return path:find("/test/") ~= nil or path:find("_test%.exs$") ~= nil or path:find("^test/") ~= nil
end

-- What a candidate caller file must contain: the name and the module's last segment.
function M.search_terms(def)
  return def.name, def.module:match("[^.]+$")
end

local CALLBACKS = {
  handle_info = true, handle_cast = true, handle_call = true, handle_continue = true,
  init = true, terminate = true, perform = true, start_link = true, child_spec = true,
}

-- Why a def with no callers is still an entry point, for display.
function M.entry_label(def)
  if CALLBACKS[def.name] then return "callback" end
  if def.module:find("Chronos") then return "cron" end
  if def.name:find("^resolve") or def.module:find("Resolver") then return "resolver" end
  if def.module:find("Controller") then return "controller" end
  return nil
end

-- String keys a line writes or reads, for data edges.
function M.data_keys(line)
  local writes, reads = {}, {}
  for key in line:gmatch('"([%w_]+)"%s*=>') do writes[key] = true end
  for key in line:gmatch('Map%.put%(.-,%s*"([%w_]+)"') do writes[key] = true end
  for key in line:gmatch('%["([%w_]+)"%]') do reads[key] = true end
  for key in line:gmatch('Map%.get%(.-,%s*"([%w_]+)"') do reads[key] = true end
  -- A key matched in a pattern (%{"k" => v} on the left of = or in a case) reads it.
  if line:find("%%{") and (line:find("%->") or line:find("<%-") or line:find("=%s*[%w_]+%s*$")) then
    for key in pairs(writes) do reads[key] = true end
  end
  return writes, reads
end

return M
