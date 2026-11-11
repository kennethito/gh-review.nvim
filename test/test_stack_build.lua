-- Tests for the stack generator, using Lua sources (Neovim ships the parser).

local h = require("test.helpers")
local repo = require("test.git_repo")
local build = require("gh_review.stack.build")
local rows = require("gh_review.stack.rows")
local local_git = require("gh_review.local_git")

local dir, base = repo.stack_repo()

local function files()
  return local_git.changed_files(dir, base, local_git.snapshot(dir))
end

local function run(opts)
  return build.build({ root = dir, base = base, files = files(), opts = opts })
end

local result = run()
local function node(name) return result.nodes["app.core." .. name] end

h.run_test("Changed, new and deleted functions come from the diff", function()
  h.assert_equal("changed", node("leaf/1").status)
  h.assert_equal("new", node("fresh/1").status)
  h.assert_equal("new", node("deferred/1").status)
  h.assert_equal(nil, node("middle/1") and node("middle/1").status ~= "context" or nil, "middle is unchanged")
  h.assert_equal(1, #result.removed)
  h.assert_equal("app.core.old/1", result.removed[1].key)
end)

h.run_test("Callers are walked up to the entry point as context frames", function()
  h.assert_equal("context", node("middle/1").status)
  h.assert_equal("context", result.nodes["app.entry.start/1"].status)
  h.assert_true(result.callers["app.core.middle/1"]["app.entry.start/1"] ~= nil)
end)

h.run_test("Dynamic calls are edges of their own kind", function()
  local edge = result.callers["app.core.deferred/1"]["app.jobs.tick/0"]
  h.assert_true(edge ~= nil)
  h.assert_equal("dynamic", edge.kind)
end)

h.run_test("Recursion terminates and adds no self edge", function()
  h.assert_equal(nil, (result.callers["app.core.recur/1"] or {})["app.core.recur/1"])
end)

h.run_test("The feature is the large groups; other callers mark where they cross in", function()
  local primary, secondary = {}, {}
  for _, group in ipairs(result.groups) do
    local list = group.primary and primary or secondary
    list[#list + 1] = group.roots[1].key
  end
  h.assert_true(vim.tbl_contains(primary, "app.entry.start/1"))
  h.assert_true(vim.tbl_contains(secondary, "app.other.legacy/1"))
  h.assert_equal(1, node("fresh/1").shared, "legacy enters the feature at fresh, via helper")
  h.assert_equal(nil, node("recur/1").shared, "only the crossing frame is marked")
  h.assert_equal(nil, node("leaf/1").shared)
end)

h.run_test("A changed function nobody calls is its own root", function()
  local found = false
  for _, group in ipairs(result.groups) do
    if group.roots[1].key == "app.core.lonely/0" then found = true end
  end
  h.assert_true(found)
end)

h.run_test("Data edges link a key across files, from added lines only", function()
  h.assert_equal(0, #result.data_edges, "leaf and deferred are in the same file")
end)

h.run_test("Text rows draw each subtree once", function()
  local text = table.concat(rows.to_text(result), "\n")
  h.assert_match("@ app%.entry%.start/1", text)
  h.assert_match(">%s+app%.core%.deferred/1.-⇢", text)
  h.assert_match("%-app%.core%.old/1", text)
  local _, leaf_rows = text:gsub("\n[!+ >-]%s*app%.core%.leaf/1", "")
  local _, leaf_refs = text:gsub("↪ app%.core%.leaf/1", "")
  h.assert_equal(1, leaf_rows - leaf_refs, "leaf expanded once")
end)

h.run_test("The climb stops after the configured unchanged hops, and says so", function()
  local short = run({ max_context_hops = 1 })
  h.assert_true(short.nodes["app.core.middle/1"].truncated)
  h.assert_equal(nil, short.nodes["app.entry.start/1"])
  h.assert_match("@ app%.core%.middle/1 .*climb stopped here", table.concat(rows.to_text(short), "\n"))
end)

h.run_test("The frame limit never stops changed functions from being walked", function()
  local tight = run({ max_frames = 1 })
  h.assert_true(tight.callers["app.core.fresh/1"] ~= nil, "callers of changed code still found")
  h.assert_true(tight.callers["app.core.leaf/1"] ~= nil)
end)

h.run_test("Every changed function and file shows up somewhere in the view", function()
  local shown_keys, shown_paths = {}, {}
  for _, row in ipairs(rows.build(result)) do
    if row.node then
      shown_keys[row.node.key] = true
      shown_paths[row.node.path] = true
    end
    if row.hunk then shown_paths[row.hunk.path] = true end
    if row.file then shown_paths[row.file.path] = true end
  end
  for _, n in ipairs(result.changed) do
    h.assert_true(shown_keys[n.key], n.key .. " drawn")
  end
  for _, f in ipairs(files()) do
    h.assert_true(shown_paths[f.path], f.path .. " drawn")
  end
end)

h.run_test("Functions that only call each other are listed as unreached", function()
  h.assert_true(vim.tbl_contains(result.unreached, "app.core.ping/1"))
  h.assert_true(vim.tbl_contains(result.unreached, "app.core.pong/1"))
  h.assert_match("@ Changed, not reached from an entry point", table.concat(rows.to_text(result), "\n"))
end)

h.run_test("Hunks outside functions are listed with their first line", function()
  h.assert_equal(1, #result.outside)
  h.assert_equal("lua/app/core.lua", result.outside[1].path)
  h.assert_equal(2, result.outside[1].line)
  h.assert_equal("M.VERSION = 2", result.outside[1].text)
end)

h.run_test("Grouped roots keep the edge kind into the frame they converge on", function()
  local group
  for _, g in ipairs(result.groups) do
    if g.converge == "app.core.deferred/1" then group = g end
  end
  h.assert_equal(2, #group.roots, "tick and tick2 fold into one group")
  h.assert_equal("dynamic", group.converge_edge)
end)

h.run_test("Unchanged files are parsed once across builds", function()
  local before = build.timing.parses
  run()
  h.assert_equal(before, build.timing.parses)
end)

h.write_results("/tmp/gh_review_test_stack_build.txt")
