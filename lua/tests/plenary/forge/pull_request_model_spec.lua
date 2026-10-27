---@diagnostic disable
local fake = require "octo.forge.fake"
local forge = require "octo.forge"
local PullRequest = require "octo.model.pull-request"
local eq = assert.are.same

local host = "forge.test"
local repo = { host = host, owner = "owner", name = "repo" }
local ref = { repo = repo, number = 7 }

local function wait_for(fn)
  local value
  fn(function(v)
    value = v
  end)
  assert(
    vim.wait(1000, function()
      return value ~= nil
    end),
    "never called back"
  )
  return value
end

describe("review pull request model over a forge:", function()
  local backend

  before_each(function()
    backend = fake.new {
      pull_requests = {
        {
          pull_request = {
            ref = ref,
            id = "pr-7",
            title = "Add things",
            body = "",
            state = "open",
            draft = false,
            author = { login = "author" },
            url = "https://forge.test/owner/repo/pull/7",
            base = { name = "main", sha = "base-tip", repo = repo },
            head = { name = "topic", sha = "head-sha", repo = { host = host, owner = "fork", name = "repo" } },
            merge_base = "merge-base",
          },
          files = {
            {
              path = "a.lua",
              status = "M",
              additions = 2,
              deletions = 1,
              patch = "@@ -1 +1,2 @@\n-x\n+y\n+z",
              viewed = "viewed",
            },
            {
              path = "b.lua",
              status = "A",
              additions = 1,
              deletions = 0,
              patch = "@@ -0,0 +1 @@\n+new",
              viewed = "unviewed",
            },
          },
          ranges = {
            ["merge-base...c1"] = { { path = "a.lua", status = "M", additions = 1, deletions = 0 } },
          },
        },
      },
    }
    forge.set(host, backend)
  end)

  after_each(function()
    forge.set(host, nil)
  end)

  local function load()
    return wait_for(function(done)
      PullRequest.load({ repo = "owner/repo", number = 7, hostname = host }, done)
    end)
  end

  it("diffs from the merge base to the head", function()
    local pr = load()
    eq("merge-base", pr.left.commit)
    eq("head-sha", pr.right.commit)
    eq("fork/repo", pr.head_repo)
    eq("topic", pr.head_ref_name)
    eq("pr-7", pr.id)
  end)

  it("builds file entries carrying the viewer's viewed state", function()
    local pr = load()
    local files = wait_for(function(done)
      pr:get_changed_files(done)
    end)
    eq(
      { "a.lua", "b.lua" },
      vim.tbl_map(function(f)
        return f.path
      end, files)
    )
    eq("VIEWED", files[1].viewed_state)
    eq("UNVIEWED", files[2].viewed_state)
    eq({ additions = 2, deletions = 1, changes = 3 }, files[1].stats)
    eq("A", files[2].status)
  end)

  it("lists the files a range of commits changed", function()
    local pr = load()
    local Rev = require("octo.reviews.rev").Rev
    local files = wait_for(function(done)
      pr:get_commit_changed_files(Rev:new "merge-base", Rev:new "c1", done)
    end)
    eq(1, #files)
    eq("a.lua", files[1].path)
  end)

  it("toggles viewed state through the forge", function()
    local pr = load()
    local files = wait_for(function(done)
      pr:get_changed_files(done)
    end)
    files[2]:toggle_viewed()
    assert(vim.wait(1000, function()
      return files[2].viewed_state == "VIEWED"
    end))
    local changed = wait_for(function(done)
      backend:changes(ref, nil, function(_, result)
        done(result)
      end)
    end)
    eq("viewed", changed[2].viewed)
  end)
end)
