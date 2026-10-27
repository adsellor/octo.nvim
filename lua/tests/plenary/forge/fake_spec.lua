---@diagnostic disable
local fake = require "octo.forge.fake"
local eq = assert.are.same

local ref = { repo = { host = "example.com", owner = "owner", name = "repo" }, number = 7 }

local function pull_request()
  return {
    ref = ref,
    id = "pr-7",
    title = "Add things",
    body = "",
    state = "open",
    draft = false,
    author = { login = "author" },
    url = "https://example.com/owner/repo/pull/7",
    base = { name = "main", sha = "base", repo = ref.repo },
    head = { name = "topic", sha = "head", repo = ref.repo },
    merge_base = "base",
  }
end

local function existing_thread()
  return {
    id = "t1",
    path = "a.lua",
    side = "RIGHT",
    lines = { first = 3, last = 3 },
    original_lines = { first = 3, last = 3 },
    original_commit = "head",
    outdated = false,
    resolved = false,
    comments = {
      {
        id = "c1",
        author = { login = "author" },
        body = "why?",
        created_at = "2026-01-01T00:00:00Z",
        pending = false,
        viewer_is_author = false,
        viewer_can_edit = false,
        viewer_can_delete = false,
      },
    },
  }
end

---Call a forge method and wait for its callback.
local function invoke(forge, method, subject, ...)
  local done, err, result = false, nil, nil
  local args, n = { ... }, select("#", ...)
  args[n + 1] = function(e, r)
    done, err, result = true, e, r
  end
  forge[method](forge, subject, unpack(args, 1, n + 1))
  assert(
    vim.wait(1000, function()
      return done
    end),
    method .. " never called back"
  )
  return err, result
end

local function call(forge, method, ...)
  return invoke(forge, method, ref, ...)
end

local function new_forge(seed)
  return fake.new(vim.tbl_extend("force", {
    pull_requests = {
      {
        pull_request = pull_request(),
        files = { { path = "a.lua", status = "M", additions = 1, deletions = 0, viewed = "unviewed" } },
        threads = { existing_thread() },
        contents = { ["head:a.lua"] = "return 1\n" },
      },
    },
  }, seed or {}))
end

describe("forge contract (fake):", function()
  it("never calls back synchronously", function()
    local forge = new_forge()
    local called = false
    forge:threads(ref, function()
      called = true
    end)
    eq(false, called)
  end)

  it("reports an unknown pull request as an error", function()
    local forge = new_forge()
    local done, err
    forge:pull_request({ repo = ref.repo, number = 99 }, function(e)
      done, err = true, e
    end)
    vim.wait(1000, function()
      return done
    end)
    assert.is_truthy(err:match "not found")
  end)

  it("hands out copies", function()
    local forge = new_forge()
    local _, threads = call(forge, "threads")
    threads[1].resolved = true
    local _, again = call(forge, "threads")
    eq(false, again[1].resolved)
  end)

  it("keeps draft comments pending until submit publishes them", function()
    local forge = new_forge()
    local err, posted = call(forge, "comment", {
      body = "nit",
      anchor = { path = "a.lua", side = "RIGHT", lines = { first = 1, last = 2 } },
      draft = true,
    })
    eq(nil, err)
    eq(true, posted.comment.pending)
    eq({ first = 1, last = 2 }, posted.thread.lines)

    eq(nil, call(forge, "submit", "approve", "lgtm"))

    local _, threads = call(forge, "threads")
    for _, thread in ipairs(threads) do
      for _, comment in ipairs(thread.comments) do
        eq(false, comment.pending)
      end
    end
    eq({ { verdict = "approve", body = "lgtm", published = 1 } }, forge:submitted(ref))
  end)

  it("replies into the existing thread", function()
    local forge = new_forge()
    local _, posted = call(forge, "comment", { body = "because", reply_to = "t1" })
    eq("t1", posted.thread.id)
    eq(2, #posted.thread.comments)
    eq(false, posted.comment.pending)
  end)

  it("rejects a comment that both replies and anchors", function()
    local forge = new_forge()
    local err = call(forge, "comment", {
      body = "x",
      reply_to = "t1",
      anchor = { path = "a.lua", side = "RIGHT", lines = { first = 1, last = 1 } },
    })
    assert.is_truthy(err)
  end)

  it("rejects draft top-level comments", function()
    local forge = new_forge()
    assert.is_truthy(call(forge, "comment", { body = "x", draft = true }))
  end)

  it("discard drops pending comments and the threads they started", function()
    local forge = new_forge()
    call(forge, "comment", {
      body = "nit",
      anchor = { path = "a.lua", side = "RIGHT", lines = { first = 1, last = 1 } },
      draft = true,
    })
    call(forge, "comment", { body = "pending reply", reply_to = "t1", draft = true })
    eq(nil, call(forge, "discard"))
    local _, threads = call(forge, "threads")
    eq(1, #threads)
    eq(1, #threads[1].comments)
  end)

  it("treats having nothing to do as success", function()
    local forge = new_forge()
    eq(nil, call(forge, "discard"))
    eq(nil, call(forge, "submit", "comment", ""))
    eq({}, forge:submitted(ref))
    eq(nil, (call(forge, "resolve", "t1", true)))
    eq(nil, (call(forge, "resolve", "t1", true)))
  end)

  it("edits and deletes only what the viewer may", function()
    local forge = new_forge()
    assert.is_truthy(call(forge, "edit", "c1", "changed"))
    local _, posted = call(forge, "comment", { body = "mine", reply_to = "t1" })
    local err, edited = call(forge, "edit", posted.comment.id, "mine, edited")
    eq(nil, err)
    eq("mine, edited", edited.body)
    eq(nil, call(forge, "delete", posted.comment.id))
    local _, threads = call(forge, "threads")
    eq(1, #threads[1].comments)
  end)

  it("tracks viewed state on the pull request's files", function()
    local forge = new_forge()
    eq(nil, call(forge, "set_viewed", "a.lua", true))
    local _, files = call(forge, "changes", nil)
    eq("viewed", files[1].viewed)
  end)

  it("lists pull requests by state, branch, base and labels, newest first", function()
    local fork = { host = ref.repo.host, owner = "fork", name = "repo" }
    local function other(number, overrides, listing)
      local pr = vim.tbl_extend("force", pull_request(), { ref = { repo = ref.repo, number = number } }, overrides)
      return { pull_request = pr, listing = listing }
    end
    local forge = fake.new {
      pull_requests = {
        { pull_request = pull_request(), listing = { labels = { "bug" }, created_at = "2026-01-02T00:00:00Z" } },
        other(8, { head = { name = "topic", sha = "h8", repo = fork } }, { created_at = "2026-01-03T00:00:00Z" }),
        other(9, { state = "merged", base = { name = "release", sha = "b9", repo = ref.repo } }),
      },
    }
    local function numbers(filter)
      local err, prs = invoke(forge, "pull_requests", ref.repo, filter)
      assert(not err, err)
      return vim.tbl_map(function(pr)
        return pr.ref.number
      end, prs)
    end
    eq({ 8, 7 }, numbers {})
    eq({ 7, 8 }, numbers { order = { field = "created", direction = "asc" } })
    eq({ 8, 7, 9 }, numbers { states = { "open", "merged" } })
    eq({ 7 }, numbers { head = { name = "topic", repo = ref.repo } })
    eq({ 8 }, numbers { head = { name = "topic", repo = fork } })
    eq({}, numbers { head = { name = "other" } })
    eq({ 9 }, numbers { states = { "merged" }, base = "release" })
    eq({ 7 }, numbers { labels = { "bug" } })

    local _, prs = invoke(forge, "pull_requests", ref.repo, { labels = { "bug" } })
    eq({
      ref = ref,
      title = "Add things",
      body = "",
      state = "open",
      draft = false,
      author = { login = "author" },
      url = "https://example.com/owner/repo/pull/7",
      base = { name = "main", repo = ref.repo },
      head = { name = "topic", repo = ref.repo },
      labels = { "bug" },
      created_at = "2026-01-02T00:00:00Z",
      updated_at = "2026-01-01T00:00:00Z",
    }, prs[1])
  end)

  it("reads a file at a commit, empty when it isn't there", function()
    local forge = new_forge()
    eq({ nil, "return 1\n" }, { call(forge, "contents", "head", "a.lua") })
    eq({ nil, "" }, { call(forge, "contents", "base", "a.lua") })
  end)

  it("adds and removes the viewer's reaction once", function()
    local forge = new_forge()
    local _, reactions = call(forge, "react", "c1", "HEART", true)
    eq({ { content = "HEART", count = 1, viewer_reacted = true } }, reactions)
    _, reactions = call(forge, "react", "c1", "HEART", true)
    eq(1, reactions[1].count)
    _, reactions = call(forge, "react", "c1", "HEART", false)
    eq({ { content = "HEART", count = 0, viewer_reacted = false } }, reactions)
  end)

  it("refuses features it was told it lacks", function()
    local forge = new_forge { unsupported = { "draft", "viewed" } }
    eq(false, forge:supports "draft")
    eq(true, forge:supports "resolve")
    assert.is_truthy(call(forge, "set_viewed", "a.lua", true))
    assert.is_truthy(call(forge, "comment", { body = "x", reply_to = "t1", draft = true }))
  end)
end)
