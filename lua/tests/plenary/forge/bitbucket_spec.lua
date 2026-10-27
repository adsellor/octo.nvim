---@diagnostic disable
local bitbucket = require "octo.forge.bitbucket"
local eq = assert.are.same

local api = "https://api.test/2.0"
local ref = { repo = { host = "bitbucket.org", owner = "ws", name = "repo" }, number = 7 }
local pr_path = "/repositories/ws/repo/pullrequests/7"

local me = { uuid = "{me}", nickname = "me", display_name = "Me" }
local them = { uuid = "{them}", nickname = "them", display_name = "Them" }

---A transport that answers from handlers keyed by "METHOD path?query" (relative to the API root)
---and records every request.
local function scripted(handlers)
  local calls = {}
  return {
    request = function(method, url, opts, cb)
      local request = method .. " " .. url:gsub("^" .. vim.pesc(api), "")
      table.insert(calls, { request = request, body = opts and opts.body })
      local handler = handlers[request]
      vim.schedule(function()
        if not handler then
          return cb("unexpected request " .. request)
        end
        local data, err = handler(opts)
        cb(err, data)
      end)
    end,
  },
    calls
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

local function requests(calls)
  return vim.tbl_map(function(c)
    return c.request
  end, calls)
end

local function node(id, overrides)
  return vim.tbl_extend("force", {
    id = id,
    content = { raw = "comment " .. id },
    user = them,
    created_on = "2026-09-08T12:06:30.123456+00:00",
    updated_on = "2026-09-08T12:06:30.123456+00:00",
    deleted = false,
    pending = false,
    links = { html = { href = "https://bitbucket.org/ws/repo/pull-requests/7#comment-" .. id } },
  }, overrides or {})
end

local function page(values, next_url)
  return { values = values, next = next_url }
end

local function new_forge(handlers)
  handlers["GET /user"] = handlers["GET /user"] or function()
    return me
  end
  local transport, calls = scripted(handlers)
  return bitbucket.new { host = "bitbucket.org", api = api, transport = transport }, calls
end

describe("forge bitbucket adapter:", function()
  local function pull_request_handlers()
    return {
      ["GET " .. pr_path] = function()
        return {
          id = 7,
          title = "Bump things",
          summary = { raw = "Why" },
          state = "DECLINED",
          draft = true,
          author = them,
          links = { html = { href = "https://bitbucket.org/ws/repo/pull-requests/7" } },
          source = {
            branch = { name = "topic" },
            commit = { hash = "aaaaaaaaaaaa" },
            repository = { full_name = "fork/repo" },
          },
          destination = {
            branch = { name = "main" },
            commit = { hash = "bbbbbbbbbbbb" },
            repository = { full_name = "ws/repo" },
          },
        }
      end,
      ["GET /repositories/fork/repo/commit/aaaaaaaaaaaa?fields=hash"] = function()
        return { hash = "aaaaaaaaaaaa1111" }
      end,
      ["GET /repositories/ws/repo/commit/bbbbbbbbbbbb?fields=hash"] = function()
        return { hash = "bbbbbbbbbbbb2222" }
      end,
      ["GET /repositories/ws/repo/merge-base/aaaaaaaaaaaa..bbbbbbbbbbbb?fields=hash"] = function()
        return { hash = "cccc" }
      end,
    }
  end

  it("resolves abbreviated hashes and the merge base", function()
    local forge = new_forge(pull_request_handlers())
    local err, pr = call(forge, "pull_request")
    eq(nil, err)
    eq("closed", pr.state)
    eq(true, pr.draft)
    eq("Why", pr.body)
    eq(
      { name = "topic", sha = "aaaaaaaaaaaa1111", repo = { host = "bitbucket.org", owner = "fork", name = "repo" } },
      pr.head
    )
    eq("bbbbbbbbbbbb2222", pr.base.sha)
    eq("cccc", pr.merge_base)
    eq("7", pr.id)
  end)

  it("measures from the base when the merge base is unknown", function()
    local handlers = pull_request_handlers()
    handlers["GET /repositories/ws/repo/merge-base/aaaaaaaaaaaa..bbbbbbbbbbbb?fields=hash"] = nil
    local err, pr = call(new_forge(handlers), "pull_request")
    eq(nil, err)
    eq("bbbbbbbbbbbb2222", pr.merge_base)
  end)

  it("remembers the viewer only once the lookup succeeds", function()
    local up = false
    local forge, calls = new_forge {
      ["GET /user"] = function()
        if up then
          return me
        end
        return nil, "Could not resolve host"
      end,
      ["GET " .. pr_path .. "/comments?pagelen=100"] = function()
        return page {}
      end,
    }
    call(forge, "threads")
    up = true
    call(forge, "threads")
    call(forge, "threads")
    eq(2, #vim.tbl_filter(function(request)
      return request == "GET /user"
    end, requests(calls)))
  end)

  it("pairs the diffstat with patches split out of one diff", function()
    local diff = table.concat({
      "diff --git a/lua/a.lua b/lua/a.lua",
      "index 1..2 100644",
      "--- a/lua/a.lua",
      "+++ b/lua/a.lua",
      "@@ -1,2 +1,2 @@",
      "--- a removed Lua comment, not a header",
      "+-- its replacement",
      " end",
      "diff --git a/old.lua b/old.lua",
      "deleted file mode 100644",
      "--- a/old.lua",
      "+++ /dev/null",
      "@@ -1 +0,0 @@",
      "-gone",
      "diff --git a/img.png b/img.png",
      "Binary files a/img.png and b/img.png differ",
      "",
    }, "\n")
    local forge = new_forge {
      ["GET " .. pr_path .. "/diffstat?pagelen=100"] = function()
        return page({
          {
            status = "modified",
            lines_added = 1,
            lines_removed = 1,
            old = { path = "lua/a.lua" },
            new = { path = "lua/a.lua" },
          },
          { status = "removed", lines_added = 0, lines_removed = 1, old = { path = "old.lua" } },
        }, api .. pr_path .. "/diffstat?page=2")
      end,
      ["GET " .. pr_path .. "/diffstat?page=2"] = function()
        return page {
          { status = "renamed", old = { path = "was.png" }, new = { path = "img.png" } },
        }
      end,
      ["GET " .. pr_path .. "/diff"] = function()
        return diff
      end,
    }
    local err, files = call(forge, "changes", nil)
    eq(nil, err)
    eq(3, #files)
    eq({
      path = "lua/a.lua",
      status = "M",
      additions = 1,
      deletions = 1,
      patch = "@@ -1,2 +1,2 @@\n--- a removed Lua comment, not a header\n+-- its replacement\n end",
    }, files[1])
    eq("D", files[2].status)
    eq("@@ -1 +0,0 @@\n-gone", files[2].patch)
    eq({ path = "img.png", previous_path = "was.png", status = "R", additions = 0, deletions = 0 }, files[3])
    eq(nil, files[1].viewed)
  end)

  it("asks for a range head first, the reverse of git", function()
    local forge = new_forge {
      ["GET /repositories/ws/repo/diffstat/head..base?pagelen=100"] = function()
        return page {}
      end,
      ["GET /repositories/ws/repo/diff/head..base"] = function()
        return ""
      end,
    }
    local err, files = call(forge, "changes", { base = "base", head = "head" })
    eq(nil, err)
    eq({}, files)
  end)

  it("folds reply chains into inline threads and leaves out the rest", function()
    local inline = { path = "a.lua", to = 8 }
    local forge = new_forge {
      ["GET " .. pr_path .. "/comments?pagelen=100"] = function()
        return page {
          node(10, { inline = inline, resolution = { user = them } }),
          node(11, { parent = { id = 10 }, inline = inline, user = me, updated_on = "2026-09-09T00:00:00+00:00" }),
          node(12, { parent = { id = 11 }, inline = inline, deleted = true, content = { raw = "" } }),
          node(13, { parent = { id = 11 }, inline = inline, user = me, pending = true }),
          node(20, {}), -- a general comment
          node(21, { parent = { id = 20 } }),
          node(30, { inline = { path = "b.lua", from = 4, start_from = 2 } }),
        }
      end,
    }
    local err, threads = call(forge, "threads")
    eq(nil, err)
    eq(2, #threads)
    local first = threads[1]
    eq("10", first.id)
    eq("RIGHT", first.side)
    eq({ first = 8, last = 8 }, first.lines)
    eq(true, first.resolved)
    eq({ login = "them" }, first.resolved_by)
    eq(
      { "10", "11", "13" },
      vim.tbl_map(function(c)
        return c.id
      end, first.comments)
    )
    eq(false, first.comments[1].viewer_is_author)
    eq(true, first.comments[2].viewer_can_edit)
    eq("2026-09-08T12:06:30Z", first.comments[1].created_at)
    eq("2026-09-09T00:00:00Z", first.comments[2].edited_at)
    eq(true, first.comments[3].pending)
    eq({ side = "LEFT", lines = { first = 2, last = 4 } }, { side = threads[2].side, lines = threads[2].lines })
    eq(nil, first.original_commit)
    eq(nil, first.comments[1].reactions)
  end)

  it("posts drafts and replies with the fields Bitbucket expects", function()
    local forge, calls = new_forge {
      ["POST " .. pr_path .. "/comments"] = function(opts)
        local body = opts.body
        return node(
          99,
          { content = body.content, inline = body.inline, parent = body.parent, pending = body.pending, user = me }
        )
      end,
      ["GET " .. pr_path .. "/comments?pagelen=100"] = function()
        return page { node(10, { inline = { path = "a.lua", to = 3 } }), node(99, { parent = { id = 10 }, user = me }) }
      end,
    }
    local err, posted = call(forge, "comment", {
      body = "nit",
      anchor = { path = "a.lua", side = "RIGHT", lines = { first = 2, last = 4 } },
      draft = true,
    })
    eq(nil, err)
    eq(
      { content = { raw = "nit" }, pending = true, inline = { path = "a.lua", to = 4, start_to = 2 } },
      calls[#calls].body
    )
    eq(true, posted.comment.pending)
    eq({ first = 2, last = 4 }, posted.thread.lines)

    call(
      forge,
      "comment",
      { body = "old side", anchor = { path = "a.lua", side = "LEFT", lines = { first = 5, last = 5 } } }
    )
    eq({ content = { raw = "old side" }, inline = { path = "a.lua", from = 5 } }, calls[#calls].body)

    local reply_err, reply = call(forge, "comment", { body = "agreed", reply_to = "10" })
    eq(nil, reply_err)
    eq("10", reply.thread.id)
    eq(
      { "10", "99" },
      vim.tbl_map(function(c)
        return c.id
      end, reply.thread.comments)
    )

    assert.is_truthy(call(forge, "comment", { body = "x", draft = true }))
    assert.is_truthy(
      call(
        forge,
        "comment",
        { body = "x", anchor = { path = "a.lua", side = "RIGHT", lines = { first = 1, last = 1 }, commit = "c" } }
      )
    )
  end)

  it("submits by publishing only the viewer's drafts, then the summary and verdict", function()
    local forge, calls = new_forge {
      ["GET " .. pr_path .. "/comments?pagelen=100"] = function()
        return page {
          node(1, { inline = { path = "a.lua", to = 1 }, user = me, pending = true }),
          node(2, { inline = { path = "a.lua", to = 2 }, user = them, pending = true }),
          node(3, { inline = { path = "a.lua", to = 3 }, user = me }),
        }
      end,
      ["PUT " .. pr_path .. "/comments/1"] = function()
        return node(1)
      end,
      ["POST " .. pr_path .. "/comments"] = function()
        return node(4)
      end,
      ["POST " .. pr_path .. "/approve"] = function()
        return {}
      end,
    }
    eq(nil, call(forge, "submit", "approve", "lgtm"))
    eq({
      "GET /user",
      "GET " .. pr_path .. "/comments?pagelen=100",
      "PUT " .. pr_path .. "/comments/1",
      "POST " .. pr_path .. "/comments",
      "POST " .. pr_path .. "/approve",
    }, requests(calls))
    eq({ content = { raw = "comment 1" }, pending = false }, calls[3].body)
    eq({ content = { raw = "lgtm" } }, calls[4].body)
  end)

  it("discards drafts replies first", function()
    local forge, calls = new_forge {
      ["GET " .. pr_path .. "/comments?pagelen=100"] = function()
        return page {
          node(1, { inline = { path = "a.lua", to = 1 }, user = me, pending = true }),
          node(2, { parent = { id = 1 }, user = me, pending = true }),
          node(3, { parent = { id = 2 }, user = me, pending = true }),
        }
      end,
      ["DELETE " .. pr_path .. "/comments/1"] = function() end,
      ["DELETE " .. pr_path .. "/comments/2"] = function() end,
      ["DELETE " .. pr_path .. "/comments/3"] = function() end,
    }
    eq(nil, call(forge, "discard"))
    eq({
      "DELETE " .. pr_path .. "/comments/3",
      "DELETE " .. pr_path .. "/comments/2",
      "DELETE " .. pr_path .. "/comments/1",
    }, vim.list_slice(requests(calls), 3))
  end)

  it("resolves only what isn't resolved yet", function()
    local resolved = false
    local forge, calls = new_forge {
      ["GET " .. pr_path .. "/comments?pagelen=100"] = function()
        return page { node(10, { inline = { path = "a.lua", to = 1 }, resolution = resolved and {} or nil }) }
      end,
      ["POST " .. pr_path .. "/comments/10/resolve"] = function()
        resolved = true
        return { user = me }
      end,
    }
    local err, thread = call(forge, "resolve", "10", true)
    eq(nil, err)
    eq(true, thread.resolved)
    eq({ login = "me" }, thread.resolved_by)
    local before = #calls
    eq(nil, (call(forge, "resolve", "10", true)))
    eq({ "GET " .. pr_path .. "/comments?pagelen=100" }, vim.list_slice(requests(calls), before + 1))
  end)

  it("serves bitbucket.org remotes", function()
    local url = require("octo.utils").parse_remote_url("https://me@bitbucket.org/ws/repo.git", {})
    local owner, name = url.repo:match "^(.-)/(.+)$"
    eq("bitbucket", require("octo.forge").get({ host = url.host, owner = owner, name = name }).id)
  end)

  ---The request a listing makes: sorted, filtered by a BBQL query, 50 to a page.
  local function listing(sort, q)
    return "GET /repositories/ws/repo/pullrequests?sort="
      .. sort
      .. "&q="
      .. q:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
      end)
      .. "&pagelen=50"
  end

  ---A pull request as the listing returns it.
  local function listed(id, overrides)
    return vim.tbl_extend("force", {
      id = id,
      title = "PR " .. id,
      summary = { raw = "body " .. id },
      state = "OPEN",
      draft = false,
      author = them,
      links = { html = { href = "https://bitbucket.org/ws/repo/pull-requests/" .. id } },
      source = { branch = { name = "topic" }, repository = { full_name = "ws/repo" } },
      destination = { branch = { name = "main" }, repository = { full_name = "ws/repo" } },
      created_on = "2026-09-08T12:06:30.123456+00:00",
      updated_on = "2026-09-09T08:00:00+00:00",
    }, overrides or {})
  end

  it("lists open pull requests across pages, in the forge's terms", function()
    local forge = new_forge {
      [listing("-created_on", '(state="OPEN")')] = function()
        return page({ listed(3, { draft = true, queued = true }) }, api .. "/repositories/ws/repo/pullrequests?page=2")
      end,
      ["GET /repositories/ws/repo/pullrequests?page=2"] = function()
        return page {
          listed(4, { source = { branch = { name = "fix" }, repository = { full_name = "Fork/Repo" } } }),
        }
      end,
    }
    local err, prs = invoke(forge, "pull_requests", ref.repo, {})
    eq(nil, err)
    eq({
      ref = { repo = ref.repo, number = 3 },
      title = "PR 3",
      body = "body 3",
      state = "open",
      draft = true,
      author = { login = "them" },
      url = "https://bitbucket.org/ws/repo/pull-requests/3",
      base = { name = "main", repo = ref.repo },
      head = { name = "topic", repo = ref.repo },
      labels = {},
      created_at = "2026-09-08T12:06:30Z",
      updated_at = "2026-09-09T08:00:00Z",
      queued = true,
    }, prs[1])
    eq({ "fix", { host = "bitbucket.org", owner = "Fork", name = "Repo" } }, { prs[2].head.name, prs[2].head.repo })
  end)

  it("queries by state, branch and base, narrows to a fork, and has no labels", function()
    local q = '(state="MERGED" OR state="DECLINED" OR state="SUPERSEDED")'
      .. ' AND source.branch.name="feat/\\"x\\"" AND destination.branch.name="main"'
    local forge = new_forge {
      [listing("updated_on", q)] = function()
        return page {
          listed(3, {
            state = "DECLINED",
            source = { branch = { name = 'feat/"x"' }, repository = { full_name = "someone/repo" } },
          }),
          listed(
            4,
            { state = "MERGED", source = { branch = { name = 'feat/"x"' }, repository = { full_name = "Fork/Repo" } } }
          ),
        }
      end,
    }
    local fork = { host = "bitbucket.org", owner = "fork", name = "repo" }
    local err, prs = invoke(forge, "pull_requests", ref.repo, {
      states = { "merged", "closed" },
      head = { name = 'feat/"x"', repo = fork },
      base = "main",
      order = { field = "updated", direction = "asc" },
    })
    eq(nil, err)
    eq(
      { { 4, "merged" } },
      vim.tbl_map(function(pr)
        return { pr.ref.number, pr.state }
      end, prs)
    )
    eq(
      { "Bitbucket pull requests have no labels" },
      { invoke(forge, "pull_requests", ref.repo, { labels = { "bug" } }) }
    )
  end)

  it("reads a file from the destination, then the fork, then gives up quietly", function()
    local forge, calls = new_forge {
      ["GET /repositories/ws/repo/src/abc/dir/a%20b.lua"] = function()
        return "return 1"
      end,
      ["GET /repositories/ws/repo/src/fff/a.lua"] = function()
        return nil
      end,
      ["GET " .. pr_path .. "?fields=source.repository.full_name"] = function()
        return { source = { repository = { full_name = "fork/repo" } } }
      end,
      ["GET /repositories/fork/repo/src/fff/a.lua"] = function()
        return "from the fork"
      end,
      ["GET /repositories/ws/repo/src/fff/gone.lua"] = function()
        return nil
      end,
      ["GET /repositories/fork/repo/src/fff/gone.lua"] = function()
        return nil
      end,
    }
    eq({ nil, "return 1" }, { call(forge, "contents", "abc", "dir/a b.lua") })
    eq({ nil, "from the fork" }, { call(forge, "contents", "fff", "a.lua") })
    eq({ nil, "" }, { call(forge, "contents", "fff", "gone.lua") })
    eq(1, #vim.tbl_filter(function(r)
      return r:find("fields=source", 1, true) ~= nil
    end, requests(calls)))
  end)

  it("says what it can't do", function()
    local forge = new_forge {}
    eq(false, forge:supports "viewed")
    eq(false, forge:supports "commit_comments")
    eq(false, forge:supports "reactions")
    eq(true, forge:supports "draft")
    assert.is_truthy(call(forge, "set_viewed", "a.lua", true))
    assert.is_truthy(call(forge, "react", "1", "HEART", true))
  end)

  it("refuses to write without knowing the viewer, and says why", function()
    local forge, calls = new_forge {
      ["GET /user"] = function()
        return nil, "Bitbucket answered HTTP 401 (set BITBUCKET_EMAIL and BITBUCKET_API_TOKEN)"
      end,
    }
    local err = call(forge, "comment", { body = "hi" })
    assert.is_truthy(err:find("HTTP 401 (set BITBUCKET_EMAIL", 1, true))
    eq({ "GET /user" }, requests(calls))
  end)
end)

describe("forge bitbucket transport:", function()
  local transport = require "octo.forge.bitbucket.transport"

  it("keeps credentials and bodies in the curl config, quoted", function()
    local config = transport.curl_config(
      "POST",
      "https://api.test/2.0/x",
      { body = { content = { raw = 'say "hi"\nnow' } } },
      { basic = "me@example.com:tok" }
    )
    assert.is_truthy(config:find('user = "me@example.com:tok"', 1, true))
    assert.is_truthy(
      config:find('data-binary = "{\\"content\\":{\\"raw\\":\\"say \\\\\\"hi\\\\\\"\\\\nnow\\"}}"', 1, true)
    )
    assert.is_truthy(config:find("globoff", 1, true))
  end)

  it("turns error bodies into messages, with or without a message field", function()
    eq(
      "Bad request: path is required",
      transport.failure('{"type":"error","error":{"message":"Bad request","detail":"path is required"}}', 400)
    )
    eq(
      "Bitbucket answered HTTP 400: path is required",
      transport.failure('{"error":{"detail":"path is required"}}', 400)
    )
    eq("Bitbucket answered HTTP 502", transport.failure("<html>Bad gateway</html>", 502))
    assert.is_truthy(transport.failure("", 401):find("BITBUCKET_ACCESS_TOKEN", 1, true))
  end)
end)
