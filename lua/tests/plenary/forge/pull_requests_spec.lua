---@diagnostic disable
---What the pull request pickers do with a forge's listing: filters, opening, merging, previews
---and checking a branch out with git.
local fake = require "octo.forge.fake"
local forge = require "octo.forge"
local pull_requests = require "octo.pull-requests"
local reviews = require "octo.reviews"
local utils = require "octo.utils"
local eq = assert.are.same

local host = "forge.test"
local repo = { host = host, owner = "owner", name = "repo" }

---@return octo.forge.PullRequestSummary
local function summary(number, overrides)
  return vim.tbl_extend("force", {
    ref = { repo = repo, number = number },
    title = "PR " .. number,
    body = "first line\r\nsecond line",
    state = "open",
    draft = false,
    author = { login = "alice" },
    url = "https://forge.test/owner/repo/pull/" .. number,
    base = { name = "main", repo = repo },
    head = { name = "feature", repo = repo },
    labels = {},
    created_at = "2026-01-01T00:00:00Z",
    updated_at = "2026-01-02T00:00:00Z",
  }, overrides or {})
end

---Replace `t[key]` for the length of a test; the returned function puts it back.
local function stub(t, key, value)
  local original = t[key]
  t[key] = value
  return function()
    t[key] = original
  end
end

local function wait(fn, what)
  assert(vim.wait(5000, fn, 10), what or "timed out")
end

describe("the pull request listing", function()
  local restores

  before_each(function()
    restores = {}
    forge.set(host, fake.new {})
  end)

  after_each(function()
    for _, restore in ipairs(restores) do
      restore()
    end
    forge.set(host, nil)
  end)

  ---Collect what utils.error and utils.info report instead of notifying.
  local function capture()
    local said = { errors = {}, info = {} }
    table.insert(
      restores,
      stub(utils, "error", function(msg)
        table.insert(said.errors, msg)
      end)
    )
    table.insert(
      restores,
      stub(utils, "info", function(msg)
        table.insert(said.info, msg)
      end)
    )
    return said
  end

  it("reads :Octo pr list arguments as a forge filter", function()
    eq(
      {
        states = { "open", "merged" },
        labels = { "bug", "ui" },
        base = "main",
        head = { name = "topic" },
        order = { field = "created", direction = "desc" },
      },
      pull_requests.filter {
        states = "OPEN,MERGED",
        labels = "bug,ui",
        baseRefName = "main",
        headRefName = "topic",
      }
    )
    eq({ "open" }, pull_requests.filter({}).states)
    eq({ "closed" }, pull_requests.filter({ states = { "CLOSED" } }).states)
    assert.has_error(function()
      pull_requests.filter { states = "OPEN,DRAFT" }
    end, 'Unknown pull request state "draft": use open, closed or merged')
  end)

  it("opens a pull request as a review where octo has no PR buffer for it", function()
    local reviewed
    table.insert(
      restores,
      stub(reviews, "review_pull_request", function(ref)
        reviewed = ref
      end)
    )
    pull_requests.open(summary(5))
    eq({ repo = repo, number = 5 }, reviewed)
    eq(nil, pull_requests.uri(summary(5)))
  end)

  it("opens GitHub pull requests in their buffer, split as asked", function()
    local gh_repo = { host = "github.com", owner = "owner", name = "repo" }
    forge.set("github.com", { id = "github" })
    table.insert(restores, function()
      forge.set("github.com", nil)
    end)
    local opened
    table.insert(
      restores,
      stub(utils, "get", function(...)
        opened = { ... }
      end)
    )
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    pull_requests.open(summary(5, { ref = { repo = gh_repo, number = 5 } }), "vertical")
    eq({ "pull_request", 5, "owner/repo" }, opened)
    eq(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
    vim.cmd "close"
    eq("octo://owner/repo/pull/5", pull_requests.uri(summary(5, { ref = { repo = gh_repo, number = 5 } })))
  end)

  it("refuses to merge where octo can't yet", function()
    local said = capture()
    pull_requests.merge(summary(5))
    eq({ "Merging from octo isn't supported on forge.test yet" }, said.errors)
  end)

  it("previews from the listing, with the state and labels picked out", function()
    local lines, highlights = pull_requests.preview_lines(summary(5, { draft = true, labels = { "bug" } }))
    eq({
      "PR 5",
      "",
      "#5 DRAFT by alice  feature → main",
      lines[4],
      "Labels: bug",
      "",
      "first line",
      "second line",
    }, lines)
    assert.is_truthy(lines[4]:match "^Created .+, updated .+$")
    eq({ 2, 3, 8, "OctoStateDraft" }, highlights[2])
    eq(nil, pull_requests.stack_indicator(summary(5)))
    eq("⧉ 2/3", pull_requests.stack_indicator(summary(5, { stack = { position = 2, size = 3 } })))
    eq(utils.icons.pull_request.queued, pull_requests.icon(summary(5, { queued = true })))
    eq(utils.icons.pull_request.merged, pull_requests.icon(summary(5, { state = "merged" })))
  end)

  describe("checkout", function()
    local root, cwd

    local function git(dir, ...)
      local res = vim.system(vim.list_extend({ "git", "-C", dir }, { ... }), { text = true }):wait()
      assert(res.code == 0, res.stderr)
      return vim.trim(res.stdout)
    end

    ---A bare repository at root/<owner>/repo.git whose `branch` has one commit beyond main.
    local function upstream(owner, branch)
      local bare = root .. "/" .. owner .. "/repo.git"
      local seed = root .. "/seed-" .. owner
      git(root, "init", "-q", "-b", "main", seed)
      git(seed, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base")
      git(seed, "checkout", "-q", "-b", branch)
      git(seed, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", branch)
      -- clones of it start on main, so `branch` isn't checked out until asked
      git(seed, "checkout", "-q", "main")
      git(root, "clone", "-q", "--bare", seed, bare)
      return bare, git(seed, "rev-parse", branch)
    end

    local function wait_for(said)
      wait(function()
        return #said.info > 0 or #said.errors > 0
      end, "checkout never finished")
    end

    before_each(function()
      root = vim.fn.resolve(vim.fn.tempname())
      vim.fn.mkdir(root, "p")
      local origin = upstream("owner", "feature")
      git(root, "clone", "-q", origin, root .. "/work")
      cwd = vim.fn.getcwd()
      vim.fn.chdir(root .. "/work")
      -- the remotes are local paths; tell octo which forge repository origin is
      table.insert(
        restores,
        stub(utils, "parse_git_remote", function()
          return { origin = { host = host, repo = "owner/repo" } }
        end)
      )
    end)

    after_each(function()
      vim.fn.chdir(cwd)
      vim.fn.delete(root, "rf")
    end)

    it("tracks a branch of the repository through its remote", function()
      local said = capture()
      pull_requests.checkout(summary(5))
      wait_for(said)
      eq({}, said.errors)
      eq({ "Switched to feature" }, said.info)
      eq("feature", git(".", "branch", "--show-current"))
      eq({ "origin", "refs/heads/feature" }, {
        git(".", "config", "branch.feature.remote"),
        git(".", "config", "branch.feature.merge"),
      })
    end)

    it("reaches a fork without a remote by its URL, and tracks it by URL", function()
      local fork_url, fork_head = upstream("fork", "fix")
      local said = capture()
      pull_requests.checkout(
        summary(6, { head = { name = "fix", repo = { host = host, owner = "fork", name = "repo" } } })
      )
      wait_for(said)
      eq({}, said.errors)
      eq({ "fix", fork_head }, { git(".", "branch", "--show-current"), git(".", "rev-parse", "HEAD") })
      eq({ fork_url, "refs/heads/fix" }, {
        git(".", "config", "branch.fix.remote"),
        git(".", "config", "branch.fix.merge"),
      })
    end)

    it("leaves a same-named local branch with its own commits as it was", function()
      git(".", "checkout", "-q", "--no-track", "-b", "feature", "origin/main")
      git(".", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "mine")
      local mine = git(".", "rev-parse", "HEAD")
      git(".", "checkout", "-q", "main")
      local said = capture()
      pull_requests.checkout(summary(5))
      wait_for(said)
      eq({}, said.errors)
      eq({ "Switched to feature; it has commits the pull request doesn't, so it was left as it was" }, said.info)
      eq({ "feature", mine }, { git(".", "branch", "--show-current"), git(".", "rev-parse", "HEAD") })
      assert.is_falsy(vim.system({ "git", "config", "branch.feature.merge" }):wait().code == 0)
    end)
  end)
end)
