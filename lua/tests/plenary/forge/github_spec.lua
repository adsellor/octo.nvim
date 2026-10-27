---@diagnostic disable
local github = require "octo.forge.github"
local eq = assert.are.same

local ref = { repo = { host = "github.com", owner = "owner", name = "repo" }, number = 7 }

---A transport that answers from handlers and records what was asked.
---GraphQL handlers are keyed by operation name, REST handlers by "METHOD path".
local function scripted(handlers)
  local calls = {}
  local transport = {
    graphql = function(_, query, variables, cb)
      local operation = query:match "^%s*%a+%s+([%w_]+)"
      table.insert(calls, { operation = operation, variables = variables, query = query })
      local handler = handlers[operation]
      if not handler then
        return vim.schedule(function()
          cb("unexpected operation " .. tostring(operation))
        end)
      end
      local data, err = handler(variables)
      vim.schedule(function()
        cb(err, data)
      end)
    end,
    rest = function(_, method, path, opts, cb)
      local request = method .. " " .. path
      table.insert(calls, { operation = request, body = opts and opts.body })
      local handler = handlers[request]
      if not handler then
        return vim.schedule(function()
          cb("unexpected request " .. request)
        end)
      end
      local data, err = handler(opts)
      vim.schedule(function()
        cb(err, data)
      end)
    end,
  }
  return transport, calls
end

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

local function operations(calls)
  return vim.tbl_map(function(c)
    return c.operation
  end, calls)
end

local function comment_node(overrides)
  return vim.tbl_extend("force", {
    id = "PRRC_1",
    body = "why?",
    createdAt = "2026-01-01T00:00:00Z",
    url = "https://github.com/owner/repo/pull/7#discussion_r1",
    author = { login = "reviewer" },
    viewerDidAuthor = false,
    viewerCanUpdate = false,
    viewerCanDelete = false,
    diffHunk = "@@ -1,2 +1,3 @@",
    originalCommit = { oid = "abc" },
    pullRequestReview = { state = "SUBMITTED" },
    reactionGroups = { { content = "HEART", viewerHasReacted = true, reactors = { totalCount = 2 } } },
  }, overrides or {})
end

local function thread_node(overrides)
  return vim.tbl_extend("force", {
    id = "PRRT_1",
    path = "a.lua",
    diffSide = "RIGHT",
    line = 5,
    originalLine = 4,
    isOutdated = false,
    isResolved = false,
    comments = { nodes = { comment_node() } },
  }, overrides or {})
end

local function review_target(pending)
  return function()
    return {
      repository = {
        pullRequest = {
          id = "PR_7",
          headRefOid = "head",
          reviews = { nodes = pending and { { id = "PRR_1", viewerDidAuthor = true } } or {} },
        },
      },
    }
  end
end

describe("forge github adapter:", function()
  it("maps review threads, following pages", function()
    local transport = scripted {
      OctoForgeThreads = function(variables)
        local page = variables.cursor == nil and 1 or 2
        local outdated = thread_node { id = "PRRT_2", isOutdated = true }
        outdated.line = nil -- GitHub nulls the current line once a thread is outdated
        return {
          repository = {
            pullRequest = {
              reviewThreads = {
                pageInfo = { hasNextPage = page == 1, endCursor = "c" .. page },
                nodes = page == 1 and { thread_node() } or { outdated },
              },
            },
          },
        }
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    local err, threads = call(forge, "threads")
    eq(nil, err)
    eq(2, #threads)
    eq({
      id = "PRRT_1",
      path = "a.lua",
      side = "RIGHT",
      lines = { first = 5, last = 5 },
      original_lines = { first = 4, last = 4 },
      original_commit = "abc",
      outdated = false,
      resolved = false,
      diff_hunk = "@@ -1,2 +1,3 @@",
      comments = {
        {
          id = "PRRC_1",
          author = { login = "reviewer" },
          body = "why?",
          created_at = "2026-01-01T00:00:00Z",
          url = "https://github.com/owner/repo/pull/7#discussion_r1",
          pending = false,
          viewer_is_author = false,
          viewer_can_edit = false,
          viewer_can_delete = false,
          reactions = { { content = "HEART", count = 2, viewer_reacted = true } },
        },
      },
    }, threads[1])
    eq(nil, threads[2].lines)
    eq(true, threads[2].outdated)
  end)

  it("starts a pending review for the first draft and reuses it after", function()
    local pending = false
    local transport, calls = scripted {
      OctoForgeReviewTarget = function()
        return review_target(pending)()
      end,
      OctoForgeAddReview = function(variables)
        eq({ pullRequestId = "PR_7" }, variables.input)
        pending = true
        return { addPullRequestReview = { pullRequestReview = { id = "PRR_1" } } }
      end,
      OctoForgeAddThread = function(variables)
        eq("PRR_1", variables.input.pullRequestReviewId)
        local node = thread_node {
          id = "PRRT_9",
          startLine = variables.input.startLine,
          line = variables.input.line,
          comments = {
            nodes = {
              comment_node { id = "PRRC_9", body = variables.input.body, pullRequestReview = { state = "PENDING" } },
            },
          },
        }
        return { addPullRequestReviewThread = { thread = node } }
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    local anchor = { path = "a.lua", side = "RIGHT", lines = { first = 2, last = 4 } }

    local err, posted = call(forge, "comment", { body = "nit", anchor = anchor, draft = true })
    eq(nil, err)
    eq(true, posted.comment.pending)
    eq({ first = 2, last = 4 }, posted.thread.lines)
    eq({ "OctoForgeReviewTarget", "OctoForgeAddReview", "OctoForgeAddThread" }, operations(calls))
    eq(2, calls[3].variables.input.startLine)
    eq("RIGHT", calls[3].variables.input.startSide)

    call(forge, "comment", { body = "again", anchor = anchor, draft = true })
    eq({ "OctoForgeReviewTarget", "OctoForgeAddThread" }, vim.list_slice(operations(calls), 4))
  end)

  it("submits the pending review, or creates one only when there is something to say", function()
    local transport, calls = scripted {
      OctoForgeReviewTarget = review_target(false),
      OctoForgeAddReview = function()
        return { addPullRequestReview = { pullRequestReview = { id = "PRR_2" } } }
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    eq(nil, call(forge, "submit", "comment", "  "))
    eq({ "OctoForgeReviewTarget" }, operations(calls))

    eq(nil, call(forge, "submit", "approve", nil))
    eq({ pullRequestId = "PR_7", event = "APPROVE" }, calls[3].variables.input)

    local transport2, calls2 = scripted {
      OctoForgeReviewTarget = review_target(true),
      OctoForgeSubmitReview = function()
        return { submitPullRequestReview = { pullRequestReview = { id = "PRR_1" } } }
      end,
    }
    forge = github.new { host = "github.com", transport = transport2 }
    eq(nil, call(forge, "submit", "request_changes", "please fix"))
    eq({ pullRequestReviewId = "PRR_1", event = "REQUEST_CHANGES", body = "please fix" }, calls2[2].variables.input)
  end)

  it("discards nothing without complaint", function()
    local transport, calls = scripted { OctoForgeReviewTarget = review_target(false) }
    local forge = github.new { host = "github.com", transport = transport }
    eq(nil, call(forge, "discard"))
    eq({ "OctoForgeReviewTarget" }, operations(calls))
  end)

  it("places a commit comment by its position in that commit's diff", function()
    local transport, calls = scripted {
      ["GET repos/owner/repo/commits/c0ffee"] = function()
        return { files = { { filename = "a.lua", patch = "@@ -1,2 +1,3 @@\n one\n+two\n three" } } }
      end,
      OctoForgeReviewTarget = review_target(true),
      OctoForgeAddCommitComment = function()
        return { addPullRequestReviewComment = { comment = { id = "PRRC_5" } } }
      end,
      OctoForgeThreads = function()
        return {
          repository = {
            pullRequest = {
              reviewThreads = {
                pageInfo = { hasNextPage = false },
                nodes = { thread_node { id = "PRRT_5", comments = { nodes = { comment_node { id = "PRRC_5" } } } } },
              },
            },
          },
        }
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    local err, posted = call(forge, "comment", {
      body = "here",
      anchor = { path = "a.lua", side = "RIGHT", lines = { first = 2, last = 2 }, commit = "c0ffee" },
      draft = true,
    })
    eq(nil, err)
    eq("PRRT_5", posted.thread.id)
    local add = calls[3]
    eq("OctoForgeAddCommitComment", add.operation)
    eq(
      { pullRequestReviewId = "PRR_1", commitOID = "c0ffee", path = "a.lua", position = 2, body = "here" },
      add.variables.input
    )
  end)

  it("edits each kind of comment with its own mutation", function()
    local transport, calls = scripted {
      OctoForgeUpdateIssueComment = function(variables)
        return {
          updateIssueComment = { issueComment = comment_node { id = variables.input.id, body = variables.input.body } },
        }
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    local err, edited = call(forge, "edit", "IC_3", "new text")
    eq(nil, err)
    eq("new text", edited.body)
    eq(false, edited.pending)
    eq({ id = "IC_3", body = "new text" }, calls[1].variables.input)
    assert.is_truthy(call(forge, "edit", "XYZ", "nope"))
  end)

  it("passes GraphQL errors through as the callback's error", function()
    local transport = scripted {
      OctoForgeThreads = function()
        return nil, "Could not resolve to a PullRequest"
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    local err, threads = call(forge, "threads")
    eq("Could not resolve to a PullRequest", err)
    eq(nil, threads)
  end)

  ---A pull request as the listing query returns it.
  local function listed(number, overrides)
    return vim.tbl_extend("force", {
      number = number,
      title = "PR " .. number,
      body = "body " .. number,
      url = "https://github.com/owner/repo/pull/" .. number,
      state = "OPEN",
      isDraft = false,
      createdAt = "2026-01-02T00:00:00Z",
      updatedAt = "2026-01-03T00:00:00Z",
      author = { login = "alice" },
      baseRefName = "main",
      headRefName = "topic",
      baseRepository = { owner = { login = "owner" }, name = "repo" },
      headRepository = { owner = { login = "owner" }, name = "repo" },
      labels = { nodes = {} },
    }, overrides or {})
  end

  it("lists pull requests page by page, in the forge's terms", function()
    -- a deleted account and a deleted fork come back as null
    local orphan = listed(7, { state = "MERGED" })
    orphan.author, orphan.headRepository = nil, nil
    local pages = {
      {
        nodes = {
          listed(9, {
            isDraft = true,
            labels = { nodes = { { name = "bug" } } },
            isInMergeQueue = false,
            stackEntry = { position = 2, stack = { size = 3 } },
          }),
        },
        pageInfo = { hasNextPage = true, endCursor = "c1" },
      },
      {
        nodes = { orphan },
        pageInfo = { hasNextPage = false, endCursor = "c2" },
      },
    }
    local transport, calls = scripted {
      OctoForgePullRequests = function(variables)
        return { repository = { pullRequests = pages[variables.cursor and 2 or 1] } }
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    local err, prs = invoke(forge, "pull_requests", ref.repo, {
      states = { "open", "merged" },
      base = "main",
      labels = { "bug" },
      order = { field = "updated", direction = "asc" },
    })
    eq(nil, err)
    eq({
      owner = "owner",
      name = "repo",
      states = { "OPEN", "MERGED" },
      base = "main",
      labels = { "bug" },
      orderBy = { field = "UPDATED_AT", direction = "ASC" },
    }, calls[1].variables)
    eq("c1", calls[2].variables.cursor)
    eq({
      ref = { repo = ref.repo, number = 9 },
      title = "PR 9",
      body = "body 9",
      state = "open",
      draft = true,
      author = { login = "alice" },
      url = "https://github.com/owner/repo/pull/9",
      base = { name = "main", repo = ref.repo },
      head = { name = "topic", repo = ref.repo },
      labels = { "bug" },
      created_at = "2026-01-02T00:00:00Z",
      updated_at = "2026-01-03T00:00:00Z",
      queued = false,
      stack = { position = 2, size = 3 },
    }, prs[1])
    eq({ "merged", { login = "ghost" }, ref.repo }, { prs[2].state, prs[2].author, prs[2].head.repo })
  end)

  it("narrows a branch lookup to a fork, matching its owner without case", function()
    local transport, calls = scripted {
      OctoForgePullRequests = function()
        return {
          repository = {
            pullRequests = {
              nodes = {
                listed(9, { headRepository = { owner = { login = "someone" }, name = "repo" } }),
                listed(8, { headRepository = { owner = { login = "Forker" }, name = "Repo" } }),
              },
              pageInfo = { hasNextPage = false },
            },
          },
        }
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    local fork = { host = "github.com", owner = "forker", name = "repo" }
    local _, prs = invoke(forge, "pull_requests", ref.repo, { head = { name = "topic", repo = fork } })
    eq(
      { 8 },
      vim.tbl_map(function(pr)
        return pr.ref.number
      end, prs)
    )
    eq({ "topic", { "OPEN" } }, { calls[1].variables.head, calls[1].variables.states })
    eq({ field = "CREATED_AT", direction = "DESC" }, calls[1].variables.orderBy)
  end)

  it("asks for merge queue and stack fields only on github.com", function()
    local function query_on(host)
      local transport, calls = scripted {
        OctoForgePullRequests = function()
          return { repository = { pullRequests = { nodes = {}, pageInfo = { hasNextPage = false } } } }
        end,
      }
      invoke(github.new { host = host, transport = transport }, "pull_requests", ref.repo, {})
      return calls[1].query
    end
    assert.is_truthy(query_on("github.com"):find("isInMergeQueue stackEntry", 1, true))
    local enterprise = query_on "ghe.example.com"
    assert.is_falsy(enterprise:find("isInMergeQueue", 1, true))
    assert.is_falsy(enterprise:find("{github_com}", 1, true))
  end)

  it("reads blobs from the base repository, empty when there is none", function()
    local transport, calls = scripted {
      OctoForgeContents = function(variables)
        local text = variables.expression == "abc:a.lua" and "return 1" or nil
        return { repository = { object = text and { text = text } or nil } }
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    eq({ nil, "return 1" }, { call(forge, "contents", "abc", "a.lua") })
    eq({ owner = "owner", name = "repo", expression = "abc:a.lua" }, calls[1].variables)
    eq({ nil, "" }, { call(forge, "contents", "abc", "gone.lua") })
  end)

  it("reacts and returns the comment's reactions after", function()
    local groups = { { content = "HEART", viewerHasReacted = false, reactors = { totalCount = 1 } } }
    local transport, calls = scripted {
      OctoForgeAddReaction = function()
        return { addReaction = { reactionGroups = groups } }
      end,
      OctoForgeRemoveReaction = function()
        return { removeReaction = { reactionGroups = groups } }
      end,
    }
    local forge = github.new { host = "github.com", transport = transport }
    local err, reactions = call(forge, "react", "PRRC_1", "HEART", true)
    eq(nil, err)
    eq({ { content = "HEART", count = 1, viewer_reacted = false } }, reactions)
    eq({ input = { subjectId = "PRRC_1", content = "HEART" } }, calls[1].variables)
    call(forge, "react", "PRRC_1", "HEART", false)
    eq({ "OctoForgeAddReaction", "OctoForgeRemoveReaction" }, operations(calls))
  end)

  it("maps diff positions across hunks and sides", function()
    local patch = table.concat({
      "@@ -1,3 +1,3 @@",
      " a",
      "-b",
      "+B",
      " c",
      "@@ -10,2 +10,3 @@",
      " j",
      "+k",
      " l",
    }, "\n")
    eq(1, github.diff_position(patch, "RIGHT", 1))
    eq(2, github.diff_position(patch, "LEFT", 2))
    eq(3, github.diff_position(patch, "RIGHT", 2))
    eq(7, github.diff_position(patch, "RIGHT", 11))
    eq(nil, github.diff_position(patch, "RIGHT", 5))
  end)
end)
