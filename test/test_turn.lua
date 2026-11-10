-- Tests for the last-turn baseline.

local h = require("test.helpers")
local repo = require("test.git_repo")
local turn = require("gh_review.turn")
local local_git = require("gh_review.local_git")

h.run_test("Fold: any working wins; idle/done rest; blocked or unknown hold", function()
  h.assert_equal("working", turn.fold({ "idle", "working", "blocked" }))
  h.assert_equal("resting", turn.fold({ "idle", "done" }))
  h.assert_equal("resting", turn.fold({}))
  h.assert_equal("neither", turn.fold({ "idle", "blocked" }))
end)

h.run_test("Tracker: a start needs a seen rest; an end needs work since", function()
  local tracker = turn.new_tracker()
  local started, ended = tracker.observe("working")
  h.assert_false(started, "first sample starts nothing")
  started, ended = tracker.observe("resting")
  h.assert_true(ended, "the unseen turn still ends")
  started = tracker.observe("working")
  h.assert_true(started)
  started, ended = tracker.observe("neither")
  h.assert_false(started)
  h.assert_false(ended, "blocked keeps the turn open")
  started, ended = tracker.observe("resting")
  h.assert_true(ended)
  started, ended = tracker.observe("resting")
  h.assert_false(ended, "one end per turn")
end)

local dir = repo.feature_repo()

h.run_test("Snapshot includes untracked files and leaves the index alone", function()
  repo.git(dir, { "add", "a.txt" })
  local staged_before = repo.git(dir, { "diff", "--cached", "--name-only" })
  local tree = local_git.snapshot(dir)
  h.assert_true(tree ~= nil)
  h.assert_match("e%.txt", repo.git(dir, { "ls-tree", "-r", "--name-only", tree }))
  h.assert_equal(staged_before, repo.git(dir, { "diff", "--cached", "--name-only" }))
  h.assert_match("%?%? e.txt", repo.git(dir, { "status", "--porcelain" }))
  repo.git(dir, { "reset", "-q", "a.txt" })
end)

h.run_test("Member statuses: agents whose cwd is inside this worktree", function()
  vim.fn.mkdir(dir .. "/sub", "p")
  local other = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(other, "p")
  local list = vim.json.encode({ result = { agents = {
    { agent = "claude", cwd = dir .. "/sub", agent_status = "working" },
    { agent = "codex", cwd = other, agent_status = "idle" },
    { cwd = dir, agent_status = "unknown" },
    { agent = "claude", cwd = "relative/path", agent_status = "idle" },
  } } })
  local statuses = turn.member_statuses(list, dir)
  h.assert_equal(1, #statuses)
  h.assert_equal("working", statuses[1])
  h.assert_equal(nil, turn.member_statuses("not json", dir))
end)

h.run_test("Watcher marks the baseline when a turn starts and reports its end", function()
  local replies = {}
  turn.run = function(_, callback)
    callback(0, table.remove(replies, 1))
  end
  turn.herdr_available = function() return true end
  turn.POLL_MS = 1000000

  local function agents(status)
    return vim.json.encode({ result = { agents = { { agent = "claude", cwd = dir, agent_status = status } } } })
  end
  local ended = 0
  h.assert_true(turn.start_watcher(dir, function() ended = ended + 1 end))

  replies = { agents("idle") }
  turn.poll()
  h.assert_equal(nil, local_git.rev_parse(dir, turn.REF), "resting marks nothing")

  replies = { agents("working") }
  turn.poll()
  local marked = local_git.rev_parse(dir, turn.REF)
  h.assert_true(marked ~= nil, "turn start marks the baseline")

  replies = { agents("working") }
  turn.poll()
  h.assert_equal(marked, local_git.rev_parse(dir, turn.REF), "no remark mid-turn")
  h.assert_equal(0, ended)

  replies = { agents("idle") }
  turn.poll()
  h.assert_equal(1, ended)
  turn.stop_watcher()
  h.assert_equal(nil, turn.watching())
end)

h.run_test("Baseline picks the newest ref among gh-review, herdr-reviewr and reviewr.nvim", function()
  local function set_ref(ref, seconds_ago)
    local commit = repo.git(dir, { "rev-parse", "HEAD" })
    repo.git(dir, { "update-ref", ref, commit })
    local path = local_git.git_path(dir, ref)
    local t = os.time() - seconds_ago
    vim.uv.fs_utime(path, t, t)
  end

  set_ref(turn.REF, 300)
  set_ref("refs/worktree/reviewr/turn-base", 200)
  h.assert_equal("herdr-reviewr", turn.baseline(dir).source)

  set_ref("refs/reviewr/" .. dir:gsub("[^%w%._-]", "_") .. "/turn", 100)
  h.assert_equal("reviewr.nvim", turn.baseline(dir).source)

  turn.mark(dir)
  h.assert_equal("gh-review", turn.baseline(dir).source, "a fresh mark wins")
end)

h.write_results("/tmp/gh_review_test_turn.txt")
