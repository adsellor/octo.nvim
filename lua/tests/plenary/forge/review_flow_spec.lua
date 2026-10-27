---@diagnostic disable
---The review UI over a forge: thread buffers, saving, resolving, reacting and the review's
---lifecycle, all against the fake adapter.
local OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
local PullRequest = require "octo.model.pull-request"
local commands = require "octo.commands"
local constants = require "octo.constants"
local fake = require "octo.forge.fake"
local forge = require "octo.forge"
local reviews = require "octo.reviews"
local thread_buffer = require "octo.reviews.thread-buffer"
local utils = require "octo.utils"
local eq = assert.are.same

local host = "forge.test"
local repo = { host = host, owner = "owner", name = "repo" }
local ref = { repo = repo, number = 7 }

local function comment(id, overrides)
  return vim.tbl_extend("force", {
    id = id,
    author = { login = "author" },
    body = "comment " .. id,
    created_at = "2026-01-01T00:00:00Z",
    pending = false,
    viewer_is_author = false,
    viewer_can_edit = false,
    viewer_can_delete = false,
  }, overrides or {})
end

local function thread(id, comments, overrides)
  return vim.tbl_extend("force", {
    id = id,
    path = "a.lua",
    side = "RIGHT",
    lines = { first = 1, last = 1 },
    original_lines = { first = 1, last = 1 },
    original_commit = "head-sha",
    outdated = false,
    resolved = false,
    diff_hunk = "@@ -1 +1,2 @@\n-x\n+y\n+z",
    comments = comments,
  }, overrides or {})
end

local mine = { viewer_is_author = true, viewer_can_edit = true, viewer_can_delete = true }

local function wait(fn, what)
  assert(vim.wait(2000, fn, 10), what or "timed out")
end

---Errors the code under test reports, instead of notifications.
local function capture_errors()
  local errors = {}
  local original = utils.error
  utils.error = function(msg)
    table.insert(errors, msg)
  end
  return errors, function()
    utils.error = original
  end
end

describe("review UI over a forge:", function()
  local backend, review, tab, restore_errors, errors

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
            head = { name = "topic", sha = "head-sha", repo = repo },
            merge_base = "merge-base",
          },
          threads = {
            thread("t1", { comment "c1" }),
            thread(
              "t2",
              { comment("c2", mine) },
              { lines = { first = 5, last = 6 }, original_lines = { first = 5, last = 6 } }
            ),
            thread("t3", { comment "c3" }, { outdated = true }),
          },
          contents = { ["merge-base:a.lua"] = "x\n", ["head-sha:a.lua"] = "y\nz" },
        },
      },
    }
    forge.set(host, backend)
    errors, restore_errors = capture_errors()

    local pr
    PullRequest.load({ repo = "owner/repo", number = 7, hostname = host }, function(loaded)
      pr = loaded
    end)
    wait(function()
      return pr ~= nil
    end, "pull request never loaded")

    vim.cmd.tabnew()
    tab = vim.api.nvim_get_current_tabpage()
    review = reviews.Review:new(pr)
    -- the diff layout needs real windows; these tests only need what review code reads from it
    review.layout = {
      left = pr.left,
      right = pr.right,
      file_panel = { render = function() end, redraw = function() end },
      get_current_file = function() end,
      on_enter = function() end,
      on_leave = function() end,
      on_win_leave = function() end,
      close = function()
        review.closed = true
      end,
    }
    reviews.reviews[tostring(tab)] = review
    review:refresh_threads()
    wait(function()
      return review.threads.t1 ~= nil
    end, "threads never loaded")
  end)

  after_each(function()
    restore_errors()
    reviews.reviews[tostring(tab)] = nil
    if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd.tabclose { args = { vim.api.nvim_tabpage_get_number(tab) } }
    end
    forge.set(host, nil)
  end)

  ---A thread buffer showing `threads`, current in this tab.
  local function open_buffer(threads)
    local bufnr = vim.api.nvim_create_buf(false, true)
    local buffer = OctoBuffer:new { bufnr = bufnr, number = 7, repo = "owner/repo" }
    vim.api.nvim_win_set_buf(0, bufnr)
    thread_buffer.write(bufnr, threads)
    buffer.ready = true
    vim.bo[bufnr].modified = false
    return buffer
  end

  local function backend_threads()
    local result
    backend:threads(ref, function(_, threads)
      result = threads
    end)
    wait(function()
      return result ~= nil
    end)
    local by_id = {}
    for _, t in ipairs(result) do
      by_id[t.id] = t
    end
    return by_id
  end

  ---Type `text` into a comment, as a user would.
  local function type_into(buffer, metadata, text)
    local mark = vim.api.nvim_buf_get_extmark_by_id(buffer.bufnr, constants.OCTO_COMMENT_NS, metadata.extmark, {})
    -- comment marks start on the line above the text
    local row = mark[1] + 1
    local old = vim.api.nvim_buf_get_lines(buffer.bufnr, row, row + 1, false)[1]
    vim.api.nvim_buf_set_text(buffer.bufnr, row, 0, row, #old, { text })
  end

  it("keeps outdated threads out of the review", function()
    eq({ "t1", "t2" }, vim.fn.sort(vim.tbl_keys(review.threads)))
  end)

  it("reads files the checkout lacks from the forge, as git would split them", function()
    local FileEntry = require("octo.reviews.file-entry").FileEntry
    local file = FileEntry:new { path = "a.lua", status = "M", pull_request = review.pull_request }
    file:fetch(true)
    -- a final newline ends the last line rather than starting an empty one
    eq({ "x" }, file.left_lines)
    eq({ "y", "z" }, file.right_lines)
  end)

  it("writes threads with metadata in the forge's terms", function()
    local buffer = open_buffer { review.threads.t1, review.threads.t2 }
    eq(
      { "c1", "c2" },
      vim.tbl_map(function(m)
        return m.id
      end, buffer.commentsMetadata)
    )
    local thread_ids = vim.tbl_map(function(m)
      return m.threadId
    end, vim.tbl_values(buffer.threadsMetadata))
    eq({ "t1", "t2" }, vim.fn.sort(thread_ids))
    local text = table.concat(vim.api.nvim_buf_get_lines(buffer.bufnr, 0, -1, false), "\n")
    assert.is_truthy(text:find("comment c1", 1, true))
    assert.is_truthy(text:find("comment c2", 1, true))
  end)

  it("saves a reply typed under a thread as a draft", function()
    review.started = true
    local buffer = open_buffer { review.threads.t1 }
    local first_line = vim.api.nvim_buf_get_lines(buffer.bufnr, 0, -1, false)
    vim.api.nvim_win_set_cursor(0, { #first_line, 0 })
    commands.add_pr_issue_or_review_thread_comment()
    vim.cmd.stopinsert()
    local reply = buffer.commentsMetadata[#buffer.commentsMetadata]
    eq({ -1, "t1" }, { reply.id, reply.replyTo })
    type_into(buffer, reply, "agreed")

    buffer:save()
    wait(function()
      return reply.id ~= -1
    end, "reply never saved")
    eq({}, errors)
    local saved = backend_threads().t1.comments
    eq({ "comment c1", "agreed" }, { saved[1].body, saved[2].body })
    eq(true, saved[2].pending)
    eq(saved[2].id, reply.id)
    eq(false, reply.dirty)
    eq(2, #review.threads.t1.comments)
  end)

  it("saves a new thread where the stub was anchored", function()
    review.started = true
    local bufnr = vim.api.nvim_create_buf(false, true)
    local buffer = OctoBuffer:new { bufnr = bufnr, number = 7, repo = "owner/repo" }
    vim.api.nvim_win_set_buf(0, bufnr)
    thread_buffer.write_new(bufnr, {
      path = "a.lua",
      side = "LEFT",
      lines = { first = 2, last = 3 },
      diff_hunk = "@@ -1,3 +1,1 @@\n x\n-y\n-z",
    })
    buffer.ready = true
    local stub = buffer.commentsMetadata[1]
    type_into(buffer, stub, "why remove these?")

    buffer:save()
    wait(function()
      return stub.id ~= -1
    end, "thread never saved")
    eq({}, errors)
    local created
    for _, t in pairs(backend_threads()) do
      if t.comments[1].id == stub.id then
        created = t
      end
    end
    eq({ "a.lua", "LEFT", { first = 2, last = 3 } }, { created.path, created.side, created.original_lines })
    eq({ true, "why remove these?" }, { created.comments[1].pending, created.comments[1].body })
    eq(
      { created.id },
      vim.tbl_map(function(m)
        return m.threadId
      end, vim.tbl_values(buffer.threadsMetadata))
    )
    assert.is_truthy(review.threads[created.id])
  end)

  it("saves edits to the viewer's own comment", function()
    local buffer = open_buffer { review.threads.t2 }
    type_into(buffer, buffer.commentsMetadata[1], "reworded")
    buffer:save()
    wait(function()
      return backend_threads().t2.comments[1].body == "reworded"
    end, "edit never saved")
    eq("reworded", review.threads.t2.comments[1].body)
  end)

  it("resolves the thread under the cursor and redraws it", function()
    open_buffer { review.threads.t1 }
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    commands.resolve_thread()
    wait(function()
      return review.threads.t1.resolved
    end, "never resolved")
    eq(true, backend_threads().t1.resolved)
  end)

  it("reacts to the comment under the cursor through the forge, or says the forge can't", function()
    local buffer = open_buffer { review.threads.t1 }
    local mark = vim.api.nvim_buf_get_extmark_by_id(
      buffer.bufnr,
      constants.OCTO_COMMENT_NS,
      buffer.commentsMetadata[1].extmark,
      {}
    )
    vim.api.nvim_win_set_cursor(0, { mark[1] + 2, 0 })
    commands.reaction_action "heart"
    wait(function()
      local reactions = backend_threads().t1.comments[1].reactions
      return reactions ~= nil and reactions[1].count == 1
    end, "reaction never sent")
    local heart = vim.tbl_filter(function(g)
      return g.content == "HEART"
    end, buffer.commentsMetadata[1].reactionGroups)[1]
    eq({ content = "HEART", users = { totalCount = 1 }, viewerHasReacted = true }, heart)

    backend.unsupported.reactions = true
    thread_buffer.react("c1", "HEART", true, function() end)
    eq({ "This forge has no reactions" }, errors)
  end)

  it("drops a deleted thread's last comment and the thread with it", function()
    local buffer = open_buffer { review.threads.t2 }
    local removed = false
    thread_buffer.delete(buffer, buffer.commentsMetadata[1], "t2", function()
      removed = true
    end)
    wait(function()
      return removed and review.threads.t2 == nil
    end, "thread never went away")
    eq(nil, backend_threads().t2)
  end)

  it("submits with the verdict and the text of the submit window", function()
    review.started = true
    backend:comment(ref, { body = "nit", reply_to = "t1", draft = true }, function() end)
    vim.wait(100)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "", "looks good", "" })
    review:submit "APPROVE"
    wait(function()
      return review.closed
    end, "review never closed")
    eq({ { verdict = "approve", body = "looks good", published = 1 } }, backend:submitted(ref))
  end)

  it("resumes only when the viewer has something pending", function()
    local opened = 0
    review.initiate = function()
      opened = opened + 1
    end
    review:resume()
    vim.wait(100)
    eq({ 0, false }, { opened, review.started })
    eq({ "No pending reviews found for viewer" }, errors)

    backend:comment(ref, { body = "nit", reply_to = "t1", draft = true }, function() end)
    vim.wait(50)
    review:resume()
    wait(function()
      return opened == 1
    end, "never resumed")
    eq(true, review.started)
  end)

  it("discards pending comments and leaves the review", function()
    review.started = true
    backend:comment(ref, { body = "nit", reply_to = "t1", draft = true }, function() end)
    vim.wait(50)
    review:discard { skip_confirm = true }
    wait(function()
      return not vim.api.nvim_tabpage_is_valid(tab)
    end, "review tab never closed")
    eq(1, #backend_threads().t1.comments)
    eq(false, review.started)
  end)
end)

describe("finding the current branch's pull request:", function()
  local backend, dir, cwd, restore_errors

  local function git(...)
    local out = vim.fn.system(vim.list_extend({ "git", "-C", dir }, { ... }))
    assert(vim.v.shell_error == 0, out)
  end

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
            head = { name = "feature", sha = "head-sha", repo = { host = host, owner = "fork", name = "repo" } },
            merge_base = "merge-base",
          },
        },
      },
    }
    forge.set(host, backend)
    _, restore_errors = capture_errors()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    git("init", "-q", "-b", "local-name")
    git("remote", "add", "origin", "https://forge.test/owner/repo.git")
    git("remote", "add", "fork", "git@forge.test:fork/repo.git")
    git("config", "branch.local-name.remote", "fork")
    git("config", "branch.local-name.merge", "refs/heads/feature")
    cwd = vim.fn.getcwd()
    vim.fn.chdir(dir)
  end)

  after_each(function()
    vim.fn.chdir(cwd)
    vim.fn.delete(dir, "rf")
    restore_errors()
    forge.set(host, nil)
  end)

  it("asks the forge by the tracked branch and the fork it lives in", function()
    local asked
    local list = backend.pull_requests
    backend.pull_requests = function(self, r, filter, cb)
      asked = { repo = r, filter = filter }
      return list(self, r, filter, cb)
    end
    local found
    utils.get_pull_request_for_current_branch(function(pr)
      found = pr
    end)
    wait(function()
      return found ~= nil
    end, "no pull request found")
    eq({ ref, "feature" }, { found.ref, found.head_ref_name })
    eq(
      { repo = repo, filter = { head = { name = "feature", repo = { host = host, owner = "fork", name = "repo" } } } },
      asked
    )
  end)

  it("skips the lookup when the branch tracks a pull request ref", function()
    git("config", "branch.local-name.merge", "refs/pull/7/head")
    git("config", "branch.local-name.remote", "origin")
    backend.pull_requests = function()
      error "should not be asked"
    end
    local found
    utils.get_pull_request_for_current_branch(function(pr)
      found = pr
    end)
    wait(function()
      return found ~= nil
    end, "no pull request found")
    eq(7, found.number)
  end)
end)
