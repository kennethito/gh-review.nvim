-- Tests for sending review comments to an agent.

local h = require("test.helpers")
local agent = require("gh_review.agent")

local function comment(body, login, review_state)
  return { body = body, author = { login = login or "you" },
    pullRequestReview = { state = review_state or "PENDING" } }
end

local function local_thread(fields, ...)
  local nodes = {}
  for i, body in ipairs({ ... }) do
    nodes[i] = comment(body, i == 1 and "you" or "agent")
  end
  return vim.tbl_extend("force", { diffSide = "RIGHT", comments = { nodes = nodes } }, fields)
end

h.run_test("Message quotes, numbers and orders threads by path and line", function()
  local text = agent.message({
    local_thread({ path = "b.lua", line = 9, anchor = { "  return x" }, anchor_total = 1 }, "Why x?"),
    local_thread({ path = "a.lua", line = 7, startLine = 3,
      anchor = { "    local a = 1", "    local b = 2", "      local c = 3" }, anchor_total = 5 },
      "Rename these", "Done, renamed"),
  })
  local expected = table.concat({
    "Code review comments from my editor:",
    "",
    "1. a.lua:3-7",
    "   > local a = 1",
    "   > local b = 2",
    "   >   local c = 3",
    "   > ...",
    "   Comment: Rename these",
    "   Reply (agent): Done, renamed",
    "",
    "2. b.lua:9",
    "   > return x",
    "   Comment: Why x?",
    "",
    "Make the requested changes and answer any questions. Reply per item.",
  }, "\n")
  h.assert_equal(expected, text)
end)

h.run_test("Message marks base-side comments and indents multi-line bodies", function()
  local text = agent.message({
    local_thread({ path = "a.lua", line = 2, diffSide = "LEFT", anchor = { "old" } }, "line one\nline two"),
  })
  h.assert_match("1%. a%.lua:2 %(base%)", text)
  h.assert_match("   Comment: line one\n   line two", text)
end)

h.run_test("PR threads are quoted from disk and carry a header", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "first", "second", "third" }, dir .. "/f.txt")
  local text = agent.message({
    { path = "f.txt", line = 2, diffSide = "RIGHT", comments = { nodes = { comment("Hm", "rev", "COMMENTED") } } },
  }, { root = dir, header = "PR: https://github.com/o/r/pull/1" })
  h.assert_match("^Code review comments from my editor:\nPR: https://github.com/o/r/pull/1\n", text)
  h.assert_match("1%. f%.txt:2\n   > second\n   Comment: Hm", text)
end)

local LIST = vim.json.encode({ result = { agents = {
  { agent = "claude", pane_id = "w1:p2", workspace_id = "w1", cwd = "/repo/sub", agent_status = "idle",
    terminal_title_stripped = "here" },
  { agent = "codex", pane_id = "w1:p3", workspace_id = "w1", cwd = "/elsewhere", agent_status = "working",
    terminal_title_stripped = "away" },
  { agent = "claude", pane_id = "w1:p4", workspace_id = "w1", cwd = "/repo", agent_status = "blocked" },
  { agent = "claude", pane_id = "w2:p1", workspace_id = "w2", cwd = "/repo", agent_status = "idle" },
  { pane_id = "w1:p5", workspace_id = "w1", cwd = "/repo", agent_status = "unknown" },
  { agent = "claude", pane_id = "w1:p1", workspace_id = "w1", cwd = "/repo", agent_status = "idle" },
} } })

vim.env.HERDR_PANE_ID = "w1:p1"
vim.env.HERDR_WORKSPACE_ID = "w1"

h.run_test("herdr candidates: same workspace, agents only, not us, repo first, blocked skipped", function()
  local candidates, blocked = agent.herdr_candidates(LIST, "/repo")
  h.assert_equal(2, #candidates)
  h.assert_equal("w1:p2", candidates[1].pane, "the agent in this repo comes first")
  h.assert_equal("w1:p3", candidates[2].pane)
  h.assert_equal(1, blocked)
end)

-- Stub herdr: `agent list` answers `list`; other commands are recorded.
local function stub_herdr(list)
  local calls = {}
  agent.herdr_available = function() return true end
  agent.run = function(cmd)
    calls[#calls + 1] = cmd
    if cmd[2] == "agent" and cmd[3] == "list" then return 0, list, "" end
    return 0, "", ""
  end
  return calls
end

h.run_test("herdr send pastes bracketed text into the single candidate and focuses it", function()
  local single = vim.json.encode({ result = { agents = {
    { agent = "claude", pane_id = "w1:p2", workspace_id = "w1", cwd = "/repo", agent_status = "idle" },
  } } })
  local calls = stub_herdr(single)
  vim.g.gh_review_agent_pane = nil
  local sent, where
  agent.send("review\x1b[201~ text", "/repo", function(ok, label) sent, where = ok, label end)

  h.assert_true(sent)
  h.assert_match("^herdr claude", where)
  h.assert_equal("send-text", calls[2][3])
  h.assert_equal("w1:p2", calls[2][4])
  h.assert_equal("\27[200~review text\27[201~", calls[2][5], "inner end marker stripped")
  h.assert_equal("focus", calls[3][3])
  h.assert_equal("w1:p2", vim.g.gh_review_agent_pane)
end)

h.run_test("herdr send reuses the remembered pane without asking", function()
  local calls = stub_herdr(LIST)
  vim.g.gh_review_agent_pane = "w1:p3"
  local sent
  agent.send("x", "/repo", function(ok) sent = ok end)
  h.assert_true(sent)
  h.assert_equal("w1:p3", calls[2][4])
end)

h.run_test("An agent at a prompt gets nothing; the text is copied instead", function()
  local only_blocked = vim.json.encode({ result = { agents = {
    { agent = "claude", pane_id = "w1:p4", workspace_id = "w1", cwd = "/repo", agent_status = "blocked" },
  } } })
  local calls = stub_herdr(only_blocked)
  local sent
  agent.send("blocked review", "/repo", function(ok) sent = ok end)
  h.assert_false(sent)
  h.assert_equal(1, #calls, "nothing pasted")
  h.assert_equal("blocked review", vim.fn.getreg('"'))
end)

h.run_test("Without herdr, reviewr.nvim's transport delivers", function()
  agent.herdr_available = function() return false end
  local got
  package.loaded["reviewr.transport"] = {
    detect = function() return { { transport = "tmux" } } end,
    send = function(text, opts, cb)
      got = { text = text, opts = opts }
      cb("tmux", "tmux %3")
    end,
  }
  local sent, where
  agent.send("via reviewr", "/repo", function(ok, label) sent, where = ok, label end)
  h.assert_true(sent)
  h.assert_equal("tmux %3", where)
  h.assert_equal("via reviewr", got.text)
  h.assert_equal("/repo", got.opts.repo)
  h.assert_equal("queue", got.opts.mode)
end)

h.run_test("reviewr's inbox and clipboard fallbacks are not counted as sent", function()
  for _, via in ipairs({ "clipboard", "filesystem-inbox" }) do
    package.loaded["reviewr.transport"] = {
      detect = function() return { { transport = "tmux" } } end,
      send = function(_, _, cb) cb(via, nil) end,
    }
    local sent
    agent.send("x", "/repo", function(ok) sent = ok end)
    h.assert_false(sent, via)
  end
end)

h.run_test("reviewr is skipped when it sees no agent, so no inbox file is written", function()
  local called = false
  package.loaded["reviewr.transport"] = {
    detect = function() return {} end,
    send = function() called = true end,
  }
  local sent, where
  agent.send("no agents", "/repo", function(ok, label) sent, where = ok, label end)
  h.assert_false(called)
  h.assert_false(sent)
  h.assert_equal("clipboard", where)
  h.assert_equal("no agents", vim.fn.getreg('"'))
end)

h.run_test("With neither, the text goes to the clipboard", function()
  package.loaded["reviewr.transport"] = nil
  package.preload["reviewr.transport"] = function() error("not installed") end
  local sent, where
  agent.send("clipboard review", "/repo", function(ok, label) sent, where = ok, label end)
  h.assert_false(sent)
  h.assert_equal("clipboard", where)
  h.assert_equal("clipboard review", vim.fn.getreg('"'))
end)

h.write_results("/tmp/gh_review_test_agent.txt")
