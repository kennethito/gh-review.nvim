# gh-review.nvim

A Neovim 0.10+ plugin for reviewing GitHub pull requests entirely within Neovim.

Side-by-side diffs, review threads, code suggestions, and review submission — all driven by the `gh` CLI.

Also available for Vim 9.0+: [gh-review.vim](https://github.com/gh-tui-tools/gh-review.vim).

## Goal

This plugin — which is designed for the use case where you’ve already identified a specific PR or PR branch you’re ready to review — has just one single goal:

✅ provide the simplest means possible for performing a GitHub PR review within Neovim

Anything beyond that is a non-goal — for example:

❌ GitHub Issues, Notifications, Discussions, or Actions/Workflows\
❌ Managing labels, assignees, or requested reviewers\
❌ Browsing or searching lists of PRs\
❌ Merging or closing PRs

You are expected to perform those tasks using other tooling (for example, [gh-dash](https://github.com/dlvhdr/gh-dash)).

## Requirements

- Neovim 0.10 or later
- [`gh` CLI](https://cli.github.com), authenticated

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "gh-tui-tools/gh-review.nvim" }
```

With Neovim’s built-in package manager:

```sh
mkdir -p ~/.local/share/nvim/site/pack/plugins/start
cd ~/.local/share/nvim/site/pack/plugins/start
git clone https://github.com/gh-tui-tools/gh-review.nvim.git
```

No `setup()` call is required — commands register automatically. Call `setup()`
only if you want to customize keymaps or folding.

## Configuration

`setup()` is optional. These are the defaults:

```lua
require("gh_review").setup({
  fold = { enabled = true, level = 0 },
  -- Last-turn baseline: watch herdr agents; refresh an open turn review when a turn ends
  turn = { watch = true, refresh_on_end = true },
  stack = {
    notes = true,            -- stack marks as virtual text in the diff
    data_edges = true,       -- ◆ keys passed between changed functions
    tests = false,           -- walk callers in test files too
    max_depth = 12,
    max_frames = 400,
    max_context_hops = 3,    -- unchanged functions climbed above changed code
  },
  pr_drafts = true,          -- keep PR comments local until :GHReviewSubmit
  diff_view = "split",       -- or "unified"
  diff_inline = "word",      -- mark changed words in a line: "word", "char", or "off"
  diff_follow = true,        -- a jump (gd, gF, :e) to another changed file opens it as a diff
  files_position = "bottom", -- or "left"
  files_size = { bottom = 12, left = 50 },
  keymaps = {
    diff = {
      thread_open  = "gt",
      comment      = "gc",
      suggestion   = "gs",
      next_thread  = "]t",
      prev_thread  = "[t",
      preview      = "K",
      toggle_files = "gf",
      goto_file    = "gF",
      to_stack     = "gS",   -- show the function under the cursor in the stack view
      close        = "q",
      -- off by default: the head pane is your real file
      send              = false,
      scope_pr          = false,
      scope_branch      = false,
      scope_uncommitted = false,
      scope_turn        = false,
      next_frame        = "]s",
      prev_frame        = "[s",
      help              = "g?",   -- the head pane is your file: ? stays search
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
      help              = "?",
      toggle_view       = "gu",
    },
    thread = {
      submit       = "<C-s>",
      resolve      = "<C-r>",
      close        = "q",
      close_insert = "<C-q>",
      toggle_agent = "ga",
    },
  },
})
```

Write only the keys you want to change:

```lua
require("gh_review").setup({
  keymaps = {
    diff  = { preview = false },      -- keep K for LSP hover
    files = { toggle_viewed = "v" },  -- keep <Space> for your leader
  },
  fold = { level = 99 },              -- diff folds, but open on arrival
})
```

### Keymaps

A mapping is either a string, which remaps it, or `false`, which drops it.
Omitted keys keep their defaults. An unrecognized surface, action, or value
type is reported through `vim.notify` and the whole `setup()` call is ignored,
so a typo fails loudly rather than half-applying.

The reply hint in the thread buffer names whichever keys you configured, and
omits any action you disabled.

### Folding

| Value | Effect |
|-------|--------|
| `fold = { enabled = true, level = 0 }` | Default. Diff folding, everything closed. |
| `fold = { enabled = true, level = 99 }` | Diff folding, everything open on arrival. |
| `fold = false` | No fold management at all. |

`fold = false` is shorthand for `fold = { enabled = false }`.

Neovim’s `:diffthis` sets `foldmethod=diff` by itself, so disabling folding
means the plugin actively sets `nofoldenable` once. After that it leaves
folding alone entirely — including declining to restore `foldmethod` if
another plugin changes it, which it does do in the other two modes.

## Workflows

The plugin has two main workflows: A “checkout” workflow, and a “no-checkout” workflow.

### Checkout workflow

Typically used by a project maintainer reviewing a contributor’s PR. The branch is checked out locally so the reviewer can make edits, commit fixes, and push directly.

```vim
:GHReview 123          " PR number (checks out the branch)
:GHReview              " auto-detect from current branch
```

- The right/head diff buffer is editable — `:w` writes to the working tree.
- External file changes are detected and the plugin prompts to reload.
- `git push` pushes changes back to the PR branch (works for fork PRs too).

### No-checkout workflow

Typically used by a non-maintainer reviewer who only needs to read the diff and leave comments.

```vim
:GHReview https://github.com/owner/repo/pull/123
:GHReview https://git.example.com/owner/repo/pull/123   " GitHub Enterprise host
```

When the URL refers to a different repo than the current working directory, no checkout is attempted. The right/head diff buffer is read-only, but comments, suggestions, and review submission all work normally.

GitHub Enterprise hosts work in both workflows: The plugin sends its API requests to the host in the PR URL — or, for a PR number or the current branch, to the host of the clone’s base repo.

A PR number refers to a PR in the clone’s base repo — the same repo `gh pr list` and `gh pr view` use. That’s the remote that `gh repo set-default` chose, if any; otherwise `upstream`, `github`, or `origin`, in that order. So in a clone of a fork, PR numbers refer to the parent repo’s PRs.

### Drafts: nothing reaches GitHub until you publish

On a PR, writing a comment or reply (`:w` or `<C-s>` in the comment buffer) saves it as a **draft on this machine**, under Neovim's data directory (`stdpath("data")/gh-review/drafts/`). Drafts show as pending (`CP`), survive restarts, and work with or without a checkout. Nothing is sent to GitHub, and nobody is notified.

`:GHReviewSubmit` first shows every draft it will publish, then publishes them as one review: `c` Comment, `a` Approve, or `r` Request changes, with an optional summary. It can instead upload them to a pending review on GitHub without publishing (visible only to you, like GitHub's "Start a review"). If publishing stops part way, the drafts not yet on GitHub stay drafts and `:GHReviewSubmit` retries. `:GHReviewDiscard` asks what to delete: drafts, agent notes, or both; resolving a draft thread keeps it out of publishing.

In that panel the cursor line belongs to one comment (a title line to its first comment). `dd` deletes it after a Yes/No: the first comment of a draft thread deletes the whole thread, a later one only that comment, a draft reply just the reply. `e` edits it in a small float (`:w` saves, `q` cancels). The list and counts update as you go, and the panel closes once no drafts are left.

**Agent notes.** `ga` in the comment buffer switches a new comment or reply between a GitHub draft and an **agent note**: a note for your coding agent that is never published (the buffer's first line says which). Notes show as `CA` with an "(agent)" label, are left out of `:GHReviewSubmit`, and go to the agent with `:GHReviewSend`. Replies on your own draft or note thread follow the thread, so the switch is locked there.

Set `pr_drafts = false` to post each comment when you write it, as upstream gh-review does.

### Local scopes (no PR)

Review your own working tree, or an agent's changes, the same way: no PR and no `gh` needed.

```vim
:GHReview branch [base]   " the branch against its merge base with base (default: origin's default branch)
:GHReview uncommitted     " the working tree against HEAD
:GHReview turn            " what changed since a coding agent last started working
:GHReviewScope {pr|branch|uncommitted|turn} [arg]   " switch the open review
```

- The head pane is always the real file in the working tree, so LSP works there. Untracked files are included.
- Comments are saved per branch in `.git/gh-review/<branch>.json` (inside the git directory, never the working tree). They show as pending (`CP`) until sent, and follow their lines when the file changes (marked outdated when the lines are gone).
- `:GHReviewSend` (or `S` in the files list, or `:GHReviewSubmit`) pastes the unsent comments into a running coding agent, unsubmitted, so you can add to it before pressing Enter. It tries, in order:
  1. **herdr**: an agent in the same herdr workspace (one in this repo first; you pick if there are several). An agent waiting at a permission prompt is skipped, since the prompt would swallow the paste.
  2. **[reviewr.nvim](https://github.com/paul-enz/reviewr.nvim)**, if installed: agents in Neovim terminals, tmux, Rex, or WezTerm.
  3. The clipboard.
- `:GHReviewSend` first opens a panel with the exact text it will send; `<CR>` sends it, `y` copies it, `q` cancels. In PR scope the panel has a checkbox per kind of comment, each with its count: unresolved GitHub threads (the whole conversation), your drafts, and agent notes. `<Space>` (or `1`–`3`) ticks one, and the text updates as you do. A draft reply or note on a GitHub thread brings that thread with it, so the agent sees what it answers. Sending leaves GitHub as it is. `:GHReviewCopy` opens the same panel to copy instead.
  The cursor line in the panel belongs to one comment (a title or quote line to its item's first comment): `dd` deletes it after a Yes/No (a draft, an agent note or a local comment; the first comment of such a thread takes the whole thread with it, a later one goes alone, and GitHub's own comments are left alone), `e` edits it in a small float (`:w` saves, `q` cancels), and `-` leaves that whole numbered item out of this send only, GitHub threads included. Skipped items leave the text and are listed under it, where `-` brings one back; nothing is deleted, and the text sent is always the text shown.

**Last turn.** Inside herdr, gh-review watches the agents in the worktree while Neovim runs and snapshots the worktree when they start working (`refs/worktree/gh-review/turn-base`); when the turn ends, an open turn review refreshes. Otherwise it uses the newest baseline left by [herdr-reviewr](https://github.com/persiyanov/herdr-reviewr) or reviewr.nvim, or one you mark yourself with `:GHReviewTurn` before prompting.

### Unified view

`gu` (in the diff or the files list) switches between side-by-side and unified, keeping the file and line; `diff_view = "unified"` makes it the default.

The unified view is one window on the head file itself, so LSP, go-to-definition, and editing work as usual. Added and changed lines are highlighted (the changed characters too), removed lines are drawn above where they were (they are not part of the file), and unchanged stretches fold with three lines of context. `]c` / `[c` jump between changes. On added lines the cursor line uses `GHReviewUnifiedCursorLine` (by default your colour scheme's `DiffAdd` lifted towards the text colour), since the added-line background would otherwise hide it. `gc` on a line with removed lines above it asks whether to comment on that line or on the removed lines (the base side); base-side comments show on the head line their code maps to, marked `(base)`.

Inside a changed line, the changed **words** are marked in both views (`diff_inline = "word"`; `"char"` marks characters, `"off"` neither). Side by side this is Neovim's `diffopt` `inline:word` (Neovim 0.12+), set while a review diff is open and restored when it closes.

### Stack view

Press `s` in the files list to see the change as call stacks instead of files: one stack per entry point (a cron worker, a GenServer callback, a controller), from the entry down to the changed functions, with the unchanged functions on the way shown dimmed. It is built from the diff and the code itself, in the background.

```
▾ Chronos.Minute.Worker.CBB.handle_info/2  (+4 more entries)  worker_cbb.ex:44
  ~ Data.Action.GameStatus.Runner.run/1  runner.ex:20
    ⇢ Data.Action.GameStatus.Runner.process_game/1  runner.ex:40
      + Data.Action.GameStatus.Runner.notification_score/1  runner.ex:65
```

- Functions show with their parameter names, `Runner.process_game(game)`: a binding like `%Game{} = game` reads as `game`, defaults stay visible (`opts \\ []`), and a pure pattern (`{:tick, _}`) shows only when no clause names that position.
- `+` new, `~` changed, `-` removed; `⇢` a call made asynchronously (`:timer.apply_after`, `apply/3`, `{Module, :fun, args}` tuples such as RPC casts and scheduled jobs); `⇉` a call through a variable (`tool.run(input, ctx)`) reaching a behaviour's implementations (`via Tool`) or a module the calling file names as a value (`via a module value`).
- Entry points that converge on the same code fold into one line (`+4 more entries`). A function reached twice is drawn once; later rows say `↪ … (see above)`.
- `⚠ N`: an entry point outside the change also reaches this function: existing callers of code the change modified. Only the frame where they cross in is marked.
- `◆ key`: a string key written by one changed function and read by another, in another file (heuristic, from added lines only).
- `<CR>` opens any function: changed code (and anything else in a changed file) as a diff at the function, a removed function on the base side, and a function in an unchanged file as the plain file at that line; `]s` / `[s` in the diff step through the changed functions in stack order, and `gS` jumps from the function under the cursor to its row in the stack view (building the view first if needed); `<Tab>` folds any frame with what it calls (the fold column shows `▾` open and `▸` folded, a folded frame keeps its line and adds `··· N frames`; every level folds, `zM`/`zr` collapse or open a level across all stacks, and folds survive redraws); the diff shows the same marks as virtual text.
- `P` moves the files list between the bottom and the left.
- After the change's own entry points come: changed functions with no callers found; other entry points into changed code, one row per place they cross in with the entries under it; compile-time module bodies; code reached only from tests.

The view needs the working tree to be the reviewed head: local scopes, or a PR opened with a checkout. Elixir is supported (needs the `elixir` tree-sitter parser). Lua support is basic: it follows `require`d modules and the file's returned table, but not functions passed around in tables (keymaps, callbacks), so callback-heavy Lua shows many entry points. Other files are listed under "Other changed files". Callers in test files are left out unless `stack.tests = true`, and the climb above changed code stops after `stack.max_context_hops` unchanged functions, so widely used helpers don't drag in the whole codebase.

## Quick start

```
:GHReview 123           Open PR #123
<CR>                    Open a file’s side-by-side diff
]t / [t                 Jump between review threads
gt                      View a thread
K                       Preview a thread (floating window)
gc                      Add a comment
gF                      Jump to the file with LSP (checkout only)
:GHReviewSubmit         Submit a review
:GHReviewClose          Close all review buffers
```

## Commands

| Command            | Description                                                   |
|--------------------|---------------------------------------------------------------|
| `:GHReview`        | Open a PR (auto-detect, by number, or by URL)                 |
| `:GHReviewFiles`   | Toggle the changed files list                                 |
| `:GHReviewStart`   | Start a pending review (optional — `:GHReviewSubmit` works without it) |
| `:GHReviewSubmit`  | Submit a review (Comment / Approve / Request changes)         |
| `:GHReviewDiscard` | Discard the pending review and all its pending comments       |
| `:GHReviewClose`   | Close all review buffers and reset state                      |
| `:GHReviewScope`   | Switch scope: `pr`, `branch [base]`, `uncommitted`, `turn`     |
| `:GHReviewSend`    | Send comments to a running coding agent                       |
| `:GHReviewCopy`    | Copy the comments `:GHReviewSend` would send                  |
| `:GHReviewTurn`    | Mark the last-turn baseline now                               |
| `:GHReviewHelp`    | Show every key and command (`?` in the files list, `g?` in the diff) |

## Files list mappings

| Key       | Action                                     |
|-----------|--------------------------------------------|
| `<CR>`    | Open the file’s side-by-side diff          |
| `<Space>` | Toggle the file’s reviewed state           |
| `R`       | Refresh review threads from GitHub (local scopes: re-read git and comments) |
| `gf`      | Close the files list                       |
| `q`       | Close the files list                       |
| `S`       | Send comments to a coding agent            |
| `p` `b` `u` `t` | Scope: PR / branch / uncommitted / last turn |
| `s`       | Toggle the stack view                      |
| `<Tab>`   | Fold or unfold a frame and what it calls (stack view; `zM`/`zr` work by level) |
| `P`       | Move the list between the bottom and the left |
| `?`       | Show every key (files list, diff, comment buffer) and command |
| `gu`      | Switch the diff between side-by-side and unified |

## Diff mappings

| Key   | Action                                               |
|-------|------------------------------------------------------|
| `gt`  | Open the review thread at the cursor line             |
| `gc`  | Create a new comment (visual mode: multi-line)        |
| `gs`  | Create a suggestion (right buffer only, visual: range)|
| `]t`  | Jump to the next review thread                        |
| `[t`  | Jump to the previous review thread                    |
| `K`   | Preview the thread at cursor (floating window)        |
| `gf`  | Toggle the files list                                 |
| `gF`  | Go to file at cursor line (checkout only)              |
| `q`   | Close the diff view                                   |

## Thread mappings

| Key      | Action                                        |
|----------|-----------------------------------------------|
| `Ctrl-S` | Submit the reply                              |
| `Ctrl-R` | Toggle resolved/unresolved                    |
| `q`      | Close the thread buffer                       |
| `Ctrl-Q` | Close the thread buffer (works in insert mode)|
| `Ctrl-X Ctrl-O` | Complete `@`-mention from thread participants |

## Signs and virtual text

| Sign | Meaning                          |
|------|----------------------------------|
| `CT` | Comment thread (blue)            |
| `CR` | Resolved thread (green)          |
| `CP` | Pending review comment (yellow)  |

Each sign is accompanied by virtual text at end-of-line showing the first comment’s author and a truncated body — giving at-a-glance context without opening the thread.

Comment reactions are displayed as emoji with counts after each comment body in the thread buffer and floating preview.

## `vim.ui` integration

All prompts (submit review, discard review, checkout, file reload) use `vim.ui.select` and `vim.ui.input`. Plugins like [dressing.nvim](https://github.com/stevearc/dressing.nvim) or [fzf-lua](https://github.com/ibhagwan/fzf-lua) that override these hooks will automatically provide their enhanced UIs.

## Statusline

```lua
require("gh_review").statusline()
```

Returns `""` when no review is active, or a summary like `PR #42 · reviewing · 4 threads`. Use it in lualine, heirline, or any statusline plugin.

## Comparison with other plugins

| Feature                          | gh-review.nvim      | [gh-review.vim][]   | [ghlite.nvim][]     | [gh.nvim][]         | [octo.nvim][]       |
|----------------------------------|---------------------|---------------------|---------------------|---------------------|---------------------|
| **Platform**                     | Neovim 0.10+        | Vim 9.0+            | Neovim 0.10+        | Neovim              | Neovim 0.10+        |
| **PR review: side-by-side diff** | Yes                 | Yes                 | Via diffview.nvim   | Yes                 | Yes                 |
| **PR review: comments/threads**  | Yes                 | Yes                 | Yes                 | Yes                 | Yes                 |
| **PR review: code suggestions**  | Yes                 | Yes                 | No                  | No                  | Yes                 |
| **PR review: submit review**     | Yes                 | Yes                 | Yes                 | Yes                 | Yes                 |
| **PR review: resolve threads**   | Yes                 | Yes                 | No                  | Yes                 | Yes                 |
| **PR review: thread signs**      | Yes (+ virtual text)| Yes (+ virtual text)| As diagnostics      | No                  | No                  |
| **Editable diff buffers**        | Yes                 | Yes                 | No                  | Yes (via checkout)  | No                  |
| **External change detection**    | Yes                 | Yes                 | No                  | No                  | No                  |
| **Fork PR push tracking**        | Yes                 | Yes                 | No                  | Yes                 | No                  |
| **PR listing/browsing**          | No (non-goal)       | No (non-goal)       | Yes                 | Yes                 | Yes                 |
| **Merge PRs**                    | No (non-goal)       | No (non-goal)       | Yes                 | No                  | Yes                 |
| **Labels/assignees/reviewers**   | No (non-goal)       | No (non-goal)       | No                  | No                  | Yes                 |
| **GitHub Issues**                | No (non-goal)       | No (non-goal)       | No                  | Yes                 | Yes                 |
| **Notifications**                | No (non-goal)       | No (non-goal)       | No                  | Yes                 | Yes                 |
| **Discussions**                  | No (non-goal)       | No (non-goal)       | No                  | No                  | Yes                 |
| **Actions/Workflows**            | No (non-goal)       | No (non-goal)       | No                  | No                  | Yes                 |
| **Reactions**                    | No (non-goal)       | No (non-goal)       | No                  | No                  | Yes                 |
| **Dependencies**                 | `gh` CLI            | `gh` CLI            | `gh` CLI            | `gh` CLI, litee.nvim| `gh` CLI, plenary.nvim, picker |

[gh-review.vim]: https://github.com/gh-tui-tools/gh-review.vim
[ghlite.nvim]: https://github.com/daliusd/ghlite.nvim
[gh.nvim]: https://github.com/ldelossa/gh.nvim
[octo.nvim]: https://github.com/pwntester/octo.nvim

## Documentation

See `:help gh-review` for full documentation.

See [DESIGN.md](DESIGN.md) for architecture and implementation details.
