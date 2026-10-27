---In-memory forge: the full octo.Forge contract over tables you seed it with, so UI code can run
---without a network. Like a real adapter, it answers on a later tick and hands out copies.

local M = {}

---@class octo.forge.FakePullRequest
---@field pull_request octo.forge.PullRequest
---@field files? octo.forge.ChangedFile[]
---@field ranges? table<string, octo.forge.ChangedFile[]> keyed by "base...head"
---@field threads? octo.forge.Thread[]
---@field contents? table<string, string> file text keyed by "commit:path"
---@field listing? table summary fields a pull request doesn't carry: labels, created_at, updated_at, queued, stack

---@class octo.forge.FakeSeed
---@field viewer? string login of the signed-in user, default "viewer"
---@field unsupported? octo.forge.Feature[]
---@field pull_requests? octo.forge.FakePullRequest[]

---@class octo.forge.FakeReview
---@field verdict octo.forge.Verdict
---@field body? string
---@field published integer number of pending comments it published

---@class octo.forge.FakeState
---@field pull_request octo.forge.PullRequest
---@field files octo.forge.ChangedFile[]
---@field ranges table<string, octo.forge.ChangedFile[]>
---@field threads octo.forge.Thread[]
---@field contents table<string, string>
---@field listing table
---@field comments octo.forge.Comment[] top-level comments
---@field reviews octo.forge.FakeReview[]

---@class octo.forge.Fake : octo.Forge
---@field viewer string
---@field package unsupported table<string, boolean>
---@field package prs table<string, octo.forge.FakeState>
---@field package next_id integer
local Fake = {}
Fake.__index = Fake

---@param pr octo.forge.PullRequestRef
local function key(pr)
  return string.format("%s/%s/%s#%d", pr.repo.host, pr.repo.owner, pr.repo.name, pr.number)
end

---@param cb function
local function reply(cb, ...)
  local args, n = { ... }, select("#", ...)
  vim.schedule(function()
    cb(unpack(args, 1, n))
  end)
end

---@param seed? octo.forge.FakeSeed
---@return octo.forge.Fake
function M.new(seed)
  seed = seed or {}
  local self = setmetatable({
    id = "fake",
    viewer = seed.viewer or "viewer",
    unsupported = {},
    prs = {},
    next_id = 1,
  }, Fake)
  for _, feature in ipairs(seed.unsupported or {}) do
    self.unsupported[feature] = true
  end
  for _, entry in ipairs(seed.pull_requests or {}) do
    self.prs[key(entry.pull_request.ref)] = {
      pull_request = vim.deepcopy(entry.pull_request),
      files = vim.deepcopy(entry.files or {}),
      ranges = vim.deepcopy(entry.ranges or {}),
      threads = vim.deepcopy(entry.threads or {}),
      contents = vim.deepcopy(entry.contents or {}),
      listing = vim.deepcopy(entry.listing or {}),
      comments = {},
      reviews = {},
    }
  end
  return self
end

function Fake:supports(feature)
  return not self.unsupported[feature]
end

---@private
---@param pr octo.forge.PullRequestRef
---@return octo.forge.FakeState?, string?
function Fake:state(pr)
  local state = self.prs[key(pr)]
  if not state then
    return nil, "Pull request not found: " .. key(pr)
  end
  return state
end

---@private
---@param body string
---@param pending boolean
---@return octo.forge.Comment
function Fake:new_comment(body, pending)
  local id = tostring(self.next_id)
  self.next_id = self.next_id + 1
  return {
    id = id,
    author = { login = self.viewer },
    body = body,
    created_at = os.date "!%Y-%m-%dT%H:%M:%SZ" --[[@as string]],
    pending = pending,
    viewer_is_author = true,
    viewer_can_edit = true,
    viewer_can_delete = true,
  }
end

---@private
---@param state octo.forge.FakeState
---@param id string
---@return octo.forge.Comment?, octo.forge.Thread?
function Fake:find_comment(state, id)
  for _, thread in ipairs(state.threads) do
    for _, comment in ipairs(thread.comments) do
      if comment.id == id then
        return comment, thread
      end
    end
  end
  for _, comment in ipairs(state.comments) do
    if comment.id == id then
      return comment
    end
  end
end

---@param state octo.forge.FakeState
local function drop_empty_threads(state)
  state.threads = vim.tbl_filter(function(thread) ---@param thread octo.forge.Thread
    return #thread.comments > 0
  end, state.threads)
end

---@param a octo.forge.RepoRef
---@param b octo.forge.RepoRef
local function same_repo(a, b)
  return a.host == b.host and a.owner == b.owner and a.name == b.name
end

---@param state octo.forge.FakeState
---@return octo.forge.PullRequestSummary
local function summary(state)
  local pr = vim.deepcopy(state.pull_request)
  return vim.tbl_extend("force", {
    ref = pr.ref,
    title = pr.title,
    body = pr.body,
    state = pr.state,
    draft = pr.draft,
    author = pr.author,
    url = pr.url,
    base = { name = pr.base.name, repo = pr.base.repo },
    head = { name = pr.head.name, repo = pr.head.repo },
    labels = {},
    created_at = "2026-01-01T00:00:00Z",
    updated_at = "2026-01-01T00:00:00Z",
  }, vim.deepcopy(state.listing))
end

---@param pr octo.forge.PullRequestSummary
---@param filter octo.forge.PullRequestFilter
local function passes(pr, filter)
  if not vim.tbl_contains(filter.states or { "open" }, pr.state) then
    return false
  end
  local head = filter.head
  if head and (pr.head.name ~= head.name or head.repo and not same_repo(pr.head.repo, head.repo)) then
    return false
  end
  if filter.base and pr.base.name ~= filter.base then
    return false
  end
  for _, label in ipairs(filter.labels or {}) do
    if not vim.tbl_contains(pr.labels, label) then
      return false
    end
  end
  return true
end

function Fake:pull_requests(repo, filter, cb)
  local found = {} ---@type octo.forge.PullRequestSummary[]
  for _, state in pairs(self.prs) do
    local pr = summary(state)
    if same_repo(pr.ref.repo, repo) and passes(pr, filter) then
      table.insert(found, pr)
    end
  end
  local order = filter.order or { field = "created", direction = "desc" }
  local field = order.field == "updated" and "updated_at" or "created_at"
  table.sort(found, function(a, b)
    local x = a[field] .. string.format("%09d", a.ref.number) ---@type string
    local y = b[field] .. string.format("%09d", b.ref.number) ---@type string
    if order.direction == "asc" then
      return x < y
    end
    return x > y
  end)
  reply(cb, nil, found)
end

function Fake:pull_request(pr, cb)
  local state, err = self:state(pr)
  reply(cb, err, state and vim.deepcopy(state.pull_request))
end

function Fake:changes(pr, range, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  if not range then
    return reply(cb, nil, vim.deepcopy(state.files))
  end
  local files = state.ranges[range.base .. "..." .. range.head]
  if not files then
    return reply(cb, string.format("Unknown range %s...%s", range.base, range.head))
  end
  reply(cb, nil, vim.deepcopy(files))
end

function Fake:contents(pr, commit, path, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  reply(cb, nil, state.contents[commit .. ":" .. path] or "")
end

function Fake:threads(pr, cb)
  local state, err = self:state(pr)
  reply(cb, err, state and vim.deepcopy(state.threads))
end

function Fake:comment(pr, new, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  if new.reply_to and new.anchor then
    return reply(cb, "A comment can't both reply to a thread and start one")
  end
  if new.draft and not self:supports "draft" then
    return reply(cb, "Draft comments are not supported")
  end

  local comment = self:new_comment(new.body, new.draft or false)

  if new.reply_to then
    for _, thread in ipairs(state.threads) do
      if thread.id == new.reply_to then
        table.insert(thread.comments, comment)
        return reply(cb, nil, { comment = vim.deepcopy(comment), thread = vim.deepcopy(thread) })
      end
    end
    return reply(cb, "Thread not found: " .. new.reply_to)
  end

  if new.anchor then
    local anchor = new.anchor --[[@as octo.forge.Anchor]]
    if anchor.commit and not self:supports "commit_comments" then
      return reply(cb, "Comments on a single commit are not supported")
    end
    ---@type octo.forge.Thread
    local thread = {
      id = "thread-" .. comment.id,
      path = anchor.path,
      side = anchor.side,
      lines = not anchor.commit and vim.deepcopy(anchor.lines) or nil,
      original_lines = vim.deepcopy(anchor.lines),
      original_commit = anchor.commit or state.pull_request.head.sha,
      outdated = false,
      resolved = false,
      comments = { comment },
    }
    table.insert(state.threads, thread)
    return reply(cb, nil, { comment = vim.deepcopy(comment), thread = vim.deepcopy(thread) })
  end

  if new.draft then
    return reply(cb, "Top-level comments can't be drafts; pass the text to submit instead")
  end
  table.insert(state.comments, comment)
  reply(cb, nil, { comment = vim.deepcopy(comment) })
end

function Fake:edit(pr, comment_id, body, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  local comment = self:find_comment(state, comment_id)
  if not comment then
    return reply(cb, "Comment not found: " .. comment_id)
  end
  if not comment.viewer_can_edit then
    return reply(cb, "You can't edit this comment")
  end
  comment.body = body
  comment.edited_at = os.date "!%Y-%m-%dT%H:%M:%SZ" --[[@as string]]
  reply(cb, nil, vim.deepcopy(comment))
end

function Fake:delete(pr, comment_id, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  local comment, thread = self:find_comment(state, comment_id)
  if not comment then
    return reply(cb, "Comment not found: " .. comment_id)
  end
  if not comment.viewer_can_delete then
    return reply(cb, "You can't delete this comment")
  end
  local list = thread and thread.comments or state.comments
  for i, c in ipairs(list) do
    if c.id == comment_id then
      table.remove(list, i)
      break
    end
  end
  drop_empty_threads(state)
  reply(cb)
end

function Fake:react(pr, comment_id, content, add, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  if not self:supports "reactions" then
    return reply(cb, "Reactions are not supported")
  end
  local comment = self:find_comment(state, comment_id)
  if not comment then
    return reply(cb, "Comment not found: " .. comment_id)
  end
  comment.reactions = comment.reactions or {}
  local group ---@type octo.forge.Reaction?
  for _, r in ipairs(comment.reactions) do
    if r.content == content then
      group = r
    end
  end
  if not group then
    group = { content = content, count = 0, viewer_reacted = false }
    table.insert(comment.reactions, group)
  end
  if group.viewer_reacted ~= add then
    group.viewer_reacted = add
    group.count = group.count + (add and 1 or -1)
  end
  reply(cb, nil, vim.deepcopy(comment.reactions))
end

function Fake:resolve(pr, thread_id, resolved, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  if not self:supports "resolve" then
    return reply(cb, "Resolving threads is not supported")
  end
  for _, thread in ipairs(state.threads) do
    if thread.id == thread_id then
      thread.resolved = resolved
      thread.resolved_by = resolved and { login = self.viewer } or nil
      return reply(cb, nil, vim.deepcopy(thread))
    end
  end
  reply(cb, "Thread not found: " .. thread_id)
end

local verdicts = { comment = true, approve = true, request_changes = true }

function Fake:submit(pr, verdict, body, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  if not verdicts[verdict] then
    return reply(cb, "Unknown verdict: " .. tostring(verdict))
  end
  local published = 0
  for _, thread in ipairs(state.threads) do
    for _, comment in ipairs(thread.comments) do
      if comment.pending then
        comment.pending = false
        published = published + 1
      end
    end
  end
  local has_body = body ~= nil and vim.trim(body) ~= ""
  if verdict ~= "comment" or published > 0 or has_body then
    table.insert(state.reviews, { verdict = verdict, body = has_body and body or nil, published = published })
  end
  reply(cb)
end

function Fake:discard(pr, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  for _, thread in ipairs(state.threads) do
    thread.comments = vim.tbl_filter(function(comment) ---@param comment octo.forge.Comment
      return not comment.pending
    end, thread.comments)
  end
  drop_empty_threads(state)
  reply(cb)
end

function Fake:set_viewed(pr, path, viewed, cb)
  local state, err = self:state(pr)
  if not state then
    return reply(cb, err)
  end
  if not self:supports "viewed" then
    return reply(cb, "Viewed state is not supported")
  end
  for _, file in ipairs(state.files) do
    if file.path == path then
      file.viewed = viewed and "viewed" or "unviewed"
      return reply(cb)
    end
  end
  reply(cb, "File not in pull request: " .. path)
end

---Test inspection, outside the forge interface: reviews submitted so far.
---@param pr octo.forge.PullRequestRef
---@return octo.forge.FakeReview[]
function Fake:submitted(pr)
  local state = assert(self:state(pr))
  return vim.deepcopy(state.reviews)
end

---Test inspection, outside the forge interface: top-level comments posted so far.
---@param pr octo.forge.PullRequestRef
---@return octo.forge.Comment[]
function Fake:top_level_comments(pr)
  local state = assert(self:state(pr))
  return vim.deepcopy(state.comments)
end

return M
