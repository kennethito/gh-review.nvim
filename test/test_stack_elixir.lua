-- Tests for the Elixir stack adapter. They need the Elixir tree-sitter parser,
-- which `nvim --clean` doesn't load: look in the usual nvim-treesitter install
-- location, and skip when it isn't there.

local h = require("test.helpers")

vim.opt.rtp:append(vim.fn.expand("~/.local/share/nvim/site"))
local ex = require("gh_review.stack.lang.elixir")

if not ex.available() then
  h.run_test("Elixir adapter (skipped: no elixir parser installed)", function() end)
  h.write_results("/tmp/gh_review_test_stack_elixir.txt")
  return
end

local SOURCE = [[
defmodule App.Worker do
  alias App.{Store, Notify}
  alias App.Long.Name, as: Short
  alias App.Play
  alias __MODULE__.Private
  import App.Helpers

  @timeout 5

  def run(items, opts \\ []) when is_list(items) do
    items
    |> Enum.map(&Private.prepare/1)
    |> Store.save(opts)
    Enum.filter(items, &keep?/1)
    Play.BigPlay.schedule(items)
    Short.call(1, 2)
    :timer.apply_after(25_000, __MODULE__, :notify, [items])
    Job.schedule(@timeout, :worker, Notify, :deliver, [items, opts])
    RPC.cast(:worker, {App.Runner, :tick, [1]})
    __MODULE__.Private.prepare(1)
    helper_from_import(items)
  end

  def notify(items), do: Notify.send(items)

  def kind(%{type: :a}), do: :a
  def kind(other) do
    other
  end

  defp keep?(x), do: x

  defmodule Private do
    def prepare(x), do: x
  end

  test "it runs" do
    run([1])
  end
end
]]

local analysis = ex.analyze(SOURCE)

local function def(key)
  for _, d in ipairs(analysis.defs) do
    if d.key == key then return d end
  end
end

local function calls_named(name)
  local result = {}
  for _, c in ipairs(analysis.calls) do
    if c.name == name then result[#result + 1] = c end
  end
  return result
end

h.run_test("Guarded heads and default arguments: one def answering every arity", function()
  local run = def("App.Worker.run/2")
  h.assert_true(run ~= nil)
  h.assert_equal(1, run.min_arity)
  h.assert_equal(2, run.max_arity)
  h.assert_true(run.public)
end)

h.run_test("`, do:` defs and multi-clause functions keep each clause's range", function()
  h.assert_true(def("App.Worker.notify/1") ~= nil)
  local kind = def("App.Worker.kind/1")
  h.assert_equal(2, #kind.clauses)
  h.assert_true(kind.clauses[2][1] > kind.clauses[1][1])
  h.assert_false(def("App.Worker.keep?/1").public)
end)

h.run_test("Nested modules are named under their parent", function()
  h.assert_true(def("App.Worker.Private.prepare/1") ~= nil)
end)

h.run_test("Pipes add the piped argument", function()
  local save = calls_named("save")[1]
  h.assert_equal("App.Store", save.module, "alias App.{Store, Notify}")
  h.assert_equal(2, save.arity)
end)

h.run_test("Captures are references with their arity", function()
  local prepare = calls_named("prepare")
  h.assert_equal("capture", prepare[1].kind)
  h.assert_equal("App.Worker.Private", prepare[1].module, "alias __MODULE__.Private")
  h.assert_equal(1, prepare[1].arity)
  local keep = calls_named("keep?")[1]
  h.assert_equal("capture", keep.kind)
  h.assert_equal(nil, keep.module)
  h.assert_equal("App.Worker", keep.scope)
end)

h.run_test("Partial aliases, as: aliases and __MODULE__ chains expand", function()
  h.assert_equal("App.Play.BigPlay", calls_named("schedule")[1].module)
  h.assert_equal("App.Long.Name", calls_named("call")[1].module)
  h.assert_equal("App.Worker.Private", calls_named("prepare")[2].module)
end)

h.run_test("Module/atom/list triples are dynamic calls", function()
  local notify = calls_named("notify")[1]
  h.assert_equal("dynamic", notify.kind)
  h.assert_equal("App.Worker", notify.module)
  h.assert_equal(1, notify.arity)
  local deliver = calls_named("deliver")[1]
  h.assert_equal("App.Notify", deliver.module)
  h.assert_equal(2, deliver.arity)
  local tick = calls_named("tick")[1]
  h.assert_equal("App.Runner", tick.module, "{Module, :fun, args} tuple")
  h.assert_equal("dynamic", tick.kind)
end)

h.run_test("Calls carry the enclosing def as their frame", function()
  h.assert_equal("App.Worker.run/2", calls_named("save")[1].from)
  h.assert_equal("App.Worker.notify/1", calls_named("send")[1].from)
end)

h.run_test("Imports resolve unqualified calls", function()
  local call = calls_named("helper_from_import")[1]
  local target = { module = "App.Helpers", name = "helper_from_import", min_arity = 1, max_arity = 1 }
  h.assert_true(ex.reaches(call, target, analysis))
  local other = { module = "App.Other", name = "helper_from_import", min_arity = 1, max_arity = 1 }
  h.assert_false(ex.reaches(call, other, analysis))
end)

h.run_test("Arity ranges decide what a call reaches", function()
  local run = def("App.Worker.run/2")
  h.assert_true(ex.reaches({ name = "run", arity = 1, scope = "App.Worker" }, run, analysis))
  h.assert_true(ex.reaches({ name = "run", arity = 2, scope = "App.Worker" }, run, analysis))
  h.assert_false(ex.reaches({ name = "run", arity = 3, scope = "App.Worker" }, run, analysis))
end)

h.run_test("Calls in a test block belong to a test pseudo frame", function()
  local call = calls_named("run")[1]
  h.assert_match("App%.Worker test", call.from)
  h.assert_equal("test", analysis.frames[call.from].kind)
end)

h.run_test("Test paths are recognised", function()
  h.assert_true(ex.is_test("apps/data/test/actions/play_test.exs"))
  h.assert_false(ex.is_test("apps/data/lib/data/actions/play.ex"))
end)

h.run_test("Data keys: map writes and access reads", function()
  local writes, reads = ex.data_keys('Map.merge(metadata, %{"scoring_player_id" => id, "x" => 1})')
  h.assert_true(writes.scoring_player_id)
  local _, reads2 = ex.data_keys('metadata["return_td"] || Map.get(m, "period_status")')
  h.assert_true(reads2.return_td)
  h.assert_true(reads2.period_status)
  h.assert_equal(nil, reads.scoring_player_id)
end)

-- ------- Behaviours and dispatch -------

local DISPATCH = [[
defmodule App.Tool do
  @callback run(map(), map()) :: map()
end
defmodule App.Tools.One do
  @behaviour App.Tool
  use Core.Logger
  def run(input, ctx), do: input
end
defmodule App.Sports.NFL do
  use App.Sport
  def stat_keys, do: []
end
defmodule App.Tools do
  alias App.Llm.Format
  def call(tool, input) do
    tool.run(input, %{})
    App.Sport.module!(input).stat_keys()
    opts.field
    case input do
      {:vertex, Format.Gemini} -> :ok
    end
  end
end
]]
local dispatch = ex.analyze(DISPATCH)

local function find_def(key)
  for _, d in ipairs(dispatch.defs) do
    if d.key == key then return d end
  end
end

h.run_test("Dispatch: calls on a variable or expression, with parentheses", function()
  local kinds = {}
  for _, c in ipairs(dispatch.calls) do kinds[c.name] = c.kind end
  h.assert_equal("dispatch", kinds.run)
  h.assert_equal("dispatch", kinds.stat_keys)
  h.assert_equal("remote", kinds["module!"], "the receiver's own call is recorded")
  h.assert_equal(nil, kinds.field, "map access is not a call")
end)

h.run_test("Dispatch: behaviours, uses, callbacks and module values are recorded", function()
  h.assert_equal("App.Tool", find_def("App.Tools.One.run/2").behaviours[1])
  h.assert_equal("Core.Logger", find_def("App.Tools.One.run/2").uses[1])
  h.assert_equal("App.Sport", find_def("App.Sports.NFL.stat_keys/0").uses[1])
  h.assert_true(dispatch.callbacks["App.Tool"])
  h.assert_true(dispatch.module_refs["App.Llm.Format.Gemini"])
end)

h.run_test("Dispatch reaches behaviour implementations and named module values only", function()
  local call = { name = "run", arity = 2, kind = "dispatch", scope = "App.Tools" }
  h.assert_true(ex.reaches(call, { name = "run", min_arity = 2, max_arity = 2, public = true,
    module = "App.Tools.One", behaviours = { "App.Tool" } }, dispatch))
  h.assert_false(ex.reaches(call, { name = "run", min_arity = 2, max_arity = 2, public = true,
    module = "App.Other", behaviours = {} }, dispatch), "no behaviour, not named here")
  h.assert_false(ex.reaches(call, { name = "run", min_arity = 2, max_arity = 2, public = false,
    module = "App.Tools.One", behaviours = { "App.Tool" } }, dispatch), "private functions are not callbacks")
  local render = { name = "render", arity = 2, kind = "dispatch", scope = "App.Tools" }
  h.assert_true(ex.reaches(render, { name = "render", min_arity = 2, max_arity = 2, public = true,
    module = "App.Llm.Format.Gemini", behaviours = {} }, dispatch), "a module named as a value")
end)

h.run_test("Dispatch in a build: callers found through the behaviour, not through `use Core.Logger`", function()
  local repo = require("test.git_repo")
  local local_git = require("gh_review.local_git")
  local build = require("gh_review.stack.build")
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  repo.git(dir, { "init", "-q", "-b", "main" })
  repo.git(dir, { "config", "user.email", "t@example.com" })
  repo.git(dir, { "config", "user.name", "T" })
  repo.write(dir, "lib/sport.ex", { "defmodule App.Sport do", "  @callback keys() :: list()",
    "  defmacro __using__(_), do: quote(do: @behaviour App.Sport)", "end" })
  repo.write(dir, "lib/nfl.ex", { "defmodule App.Sports.NFL do", "  use App.Sport", "  def keys, do: [1]", "end" })
  repo.write(dir, "lib/plain.ex", { "defmodule App.Plain do", "  use Core.Logger", "  def keys, do: [2]", "end" })
  repo.write(dir, "lib/caller.ex", { "defmodule App.Caller do", "  alias App.Sport",
    "  def go(sport), do: Sport.module!(sport).keys()", "end" })
  repo.git(dir, { "add", "-A" })
  repo.git(dir, { "commit", "-q", "-m", "base" })
  local base = repo.git(dir, { "rev-parse", "HEAD" })
  repo.write(dir, "lib/nfl.ex", { "defmodule App.Sports.NFL do", "  use App.Sport", "  def keys, do: [1, 2]", "end" })
  repo.write(dir, "lib/plain.ex", { "defmodule App.Plain do", "  use Core.Logger", "  def keys, do: [3]", "end" })

  local result = build.build({ root = dir, base = base,
    files = local_git.changed_files(dir, base, local_git.snapshot(dir)) })
  local edge = (result.callers["App.Sports.NFL.keys/0"] or {})["App.Caller.go/1"]
  h.assert_true(edge ~= nil, "the dispatching caller is found")
  h.assert_equal("dispatch", edge.kind)
  h.assert_equal("App.Sport", result.nodes["App.Sports.NFL.keys/0"].behaviours[1])
  h.assert_equal(nil, (result.callers["App.Plain.keys/0"] or {})["App.Caller.go/1"],
    "use Core.Logger is not a behaviour")
end)

h.write_results("/tmp/gh_review_test_stack_elixir.txt")
