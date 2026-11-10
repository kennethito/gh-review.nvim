-- Lua adapter for the stack view. Small on purpose: it exists so the generator
-- can be tested with a parser Neovim ships (the test harness runs `--clean`),
-- and covers the common module shape:
--
--   local dep = require("pkg.dep")   -- dep.f() calls pkg.dep.f
--   local M = {}                     -- functions on the file's table belong
--   function M.f() end               -- to the module named by its path
--   M.g = function() end
--   local function h() end
--   apply(M, "name", { args })       -- inferred dynamic call

local M = {}

M.name = "lua"
M.extensions = { lua = true }

function M.available()
  return (pcall(vim.treesitter.language.add, "lua"))
end

local function text(node, source)
  return vim.treesitter.get_node_text(node, source)
end

-- lua/pkg/mod.lua and pkg/mod/init.lua are both "pkg.mod".
function M.module_for(path)
  local module = (path or ""):gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
  return module
end

local function key_of(module, name, arity)
  return string.format("%s.%s/%d", module, name, arity)
end

local function param_count(fn_node)
  local params = fn_node:field("parameters")[1]
  if not params then return 0 end
  local n = 0
  for child in params:iter_children() do
    if child:named() then n = n + 1 end
  end
  return n
end

local function arg_list(call)
  local args = call:field("arguments")[1]
  local result = {}
  if args then
    for child in args:iter_children() do
      if child:named() and child:type() ~= "comment" then result[#result + 1] = child end
    end
  end
  return result
end

function M.analyze(source, path)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "lua")
  if not ok then return nil end
  local root = parser:parse()[1]:root()
  local module = M.module_for(path)
  local requires, tables = {}, {}
  local defs, calls = {}, {}

  local function add_def(name, fn_node, range_node)
    local arity = param_count(fn_node)
    local key = key_of(module, name, arity)
    defs[#defs + 1] = { key = key, module = module, name = name, min_arity = arity, max_arity = arity,
      public = true, clauses = { { range_node:start() + 1, range_node:end_() + 1 } } }
    return key
  end

  -- The module's own table is the one the file returns (`return M`).
  local module_table = "M"
  for child in root:iter_children() do
    if child:type() == "return_statement" then
      local value = child:named_child(0)
      local ident = value and value:named_child(0)
      if ident and ident:type() == "identifier" then module_table = text(ident, source) end
    end
  end

  local function require_target(node)
    if node:type() ~= "function_call" then return nil end
    local callee = node:field("name")[1]
    local args = arg_list(node)
    if callee and text(callee, source) == "require" and args[1] and args[1]:type() == "string" then
      return (text(args[1], source):gsub("^[\"']", ""):gsub("[\"']$", ""))
    end
    return nil
  end

  -- A module a name or expression stands for: a required module, the file's
  -- own table, or an inline require("x").
  local function resolve(node)
    local inline = require_target(node)
    if inline then return inline end
    if node:type() ~= "identifier" then return nil end
    local name = text(node, source)
    if requires[name] then return requires[name] end
    if tables[name] and name == module_table then return module end
    return nil
  end

  local walk
  local function walk_children(node, frame)
    for child in node:iter_children() do
      if child:named() then walk(child, frame) end
    end
  end

  walk = function(node, frame)
    local kind = node:type()
    if kind == "variable_declaration" or kind == "assignment_statement" then
      local assignment = kind == "assignment_statement" and node or node:named_child(0)
      -- The `name` and `value` fields sit on the variable and expression lists.
      local names, values = {}, {}
      local name_list = assignment and assignment:named_child(0)
      local value_list = assignment and assignment:named_child(1)
      if name_list then names = name_list:field("name") end
      if value_list then values = value_list:field("value") end
      for i, name_node in ipairs(names) do
        local value = values[i]
        if value and name_node:type() == "identifier" then
          if value:type() == "table_constructor" then
            tables[text(name_node, source)] = true
          elseif require_target(value) then
            requires[text(name_node, source)] = require_target(value)
          end
        elseif value and value:type() == "function_definition" and name_node:type() == "dot_index_expression" then
          local table_node = name_node:field("table")[1]
          if table_node and resolve(table_node) == module then
            local key = add_def(text(name_node:field("field")[1], source), value, node)
            walk_children(value, key)
            return
          end
        end
      end
      if assignment then walk_children(assignment, frame) end
      return
    end

    if kind == "function_declaration" then
      local name_node = node:field("name")[1]
      local name = nil
      if name_node:type() == "identifier" then
        name = text(name_node, source)
      elseif name_node:type() == "dot_index_expression" and resolve(name_node:field("table")[1]) == module then
        name = text(name_node:field("field")[1], source)
      end
      if name then
        local key = add_def(name, node, node)
        local body = node:field("body")[1]
        if body then walk_children(body, key) end
        return
      end
    end

    if kind == "function_call" then
      local callee = node:field("name")[1]
      local args = arg_list(node)
      if callee and frame then
        if callee:type() == "identifier" then
          calls[#calls + 1] = { name = text(callee, source), arity = #args, line = node:start() + 1,
            kind = "local", scope = module, from = frame }
        elseif callee:type() == "dot_index_expression" then
          local target = resolve(callee:field("table")[1])
          if target then
            calls[#calls + 1] = { module = target, name = text(callee:field("field")[1], source),
              arity = #args, line = node:start() + 1, kind = "remote", scope = module, from = frame }
          end
        end
        -- apply(Module, "name", { args }): an inferred dynamic call.
        for i = 1, #args - 2 do
          local target = resolve(args[i])
          if target and args[i + 1]:type() == "string" and args[i + 2]:type() == "table_constructor" then
            local fields = 0
            for child in args[i + 2]:iter_children() do
              if child:type() == "field" then fields = fields + 1 end
            end
            calls[#calls + 1] = { module = target, name = text(args[i + 1], source):sub(2, -2),
              arity = fields, line = node:start() + 1, kind = "dynamic", scope = module, from = frame }
          end
        end
      end
    end
    walk_children(node, frame)
  end

  walk(root, nil)
  return { defs = defs, calls = calls, frames = {}, imports = {} }
end

function M.reaches(call, def)
  if call.name ~= def.name or call.arity < def.min_arity or call.arity > def.max_arity then
    return false
  end
  return (call.module or call.scope) == def.module
end

function M.search_terms(def)
  return def.name, def.module:match("[^.]+$")
end

function M.is_test(path)
  return path:find("_spec%.lua$") ~= nil or path:find("^test/") ~= nil
end

function M.entry_label()
  return nil
end

function M.data_keys(line)
  local writes, reads = {}, {}
  for key in line:gmatch('%["([%w_]+)"%]%s*=[^=]') do writes[key] = true end
  for key in line:gmatch('%["([%w_]+)"%]') do
    if not writes[key] then reads[key] = true end
  end
  return writes, reads
end

return M
