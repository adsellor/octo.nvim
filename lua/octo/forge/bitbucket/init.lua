---Bitbucket Cloud adapter for the forge seam. Everything Bitbucket-specific about pull request
---review lives here: REST shapes, abbreviated hashes, the "head..base" revspec order, comment
---trees, per-comment drafts, and splitting one diff into per-file patches.

local async = require "octo.forge.async"

local M = {}

---What Bitbucket sends back, as far as the mapping reads it.
---@class octo.forge.bitbucket.Account
---@field uuid string
---@field nickname? string
---@field display_name? string

---@class octo.forge.bitbucket.Inline
---@field path string
---@field from? integer line on the old side
---@field to? integer line on the new side
---@field start_from? integer
---@field start_to? integer

---@class octo.forge.bitbucket.Comment
---@field id integer
---@field content { raw: string }
---@field user? octo.forge.bitbucket.Account
---@field created_on string
---@field updated_on? string
---@field deleted? boolean
---@field pending? boolean
---@field parent? { id: integer }
---@field inline? octo.forge.bitbucket.Inline
---@field resolution? { user?: octo.forge.bitbucket.Account }
---@field links? { html?: { href: string } }

---@class octo.forge.bitbucket.Endpoint
---@field branch { name: string }
---@field commit { hash: string } abbreviated
---@field repository { full_name: string }

---@class octo.forge.bitbucket.PullRequest
---@field id integer
---@field title string
---@field summary? { raw: string }
---@field state "OPEN"|"MERGED"|"DECLINED"|"SUPERSEDED"
---@field draft? boolean
---@field author? octo.forge.bitbucket.Account
---@field links { html: { href: string } }
---@field source octo.forge.bitbucket.Endpoint
---@field destination octo.forge.bitbucket.Endpoint
---@field queued? boolean
---@field created_on? string
---@field updated_on? string

---@class octo.forge.bitbucket.DiffStat
---@field status string
---@field lines_added? integer
---@field lines_removed? integer
---@field old? { path: string }
---@field new? { path: string }

---@class octo.forge.Bitbucket : octo.Forge
---@field host string
---@field package api string
---@field package transport octo.forge.bitbucket.Transport
---@field package account? octo.forge.bitbucket.Account the viewer, once known
---@field package sources table<string, octo.forge.RepoRef> each pull request's source repository, once known
local Bitbucket = {}
Bitbucket.__index = Bitbucket

---@param opts { host: string, api?: string, transport?: octo.forge.bitbucket.Transport }
---@return octo.forge.Bitbucket
function M.new(opts)
  return setmetatable({
    id = "bitbucket",
    host = opts.host,
    api = opts.api or "https://api.bitbucket.org/2.0",
    transport = opts.transport or require("octo.forge.bitbucket.transport").new(),
    sources = {},
  }, Bitbucket)
end

local features = { draft = true, viewed = false, resolve = true, commit_comments = false, reactions = false }

function Bitbucket:supports(feature)
  return features[feature] == true
end

---------------------------------------------------------------------------------------------------
-- Mapping Bitbucket shapes to forge types
---------------------------------------------------------------------------------------------------

local states = { OPEN = "open", MERGED = "merged", DECLINED = "closed", SUPERSEDED = "closed" }
local file_statuses = { added = "A", removed = "D", modified = "M", renamed = "R" }

---@param account? octo.forge.bitbucket.Account
---@return octo.forge.User
local function user(account)
  return { login = account and (account.nickname or account.display_name) or "unknown" }
end

---Bitbucket writes "2026-09-30T08:02:56.493651+00:00"; the forge contract wants "...Z".
---@param timestamp? string
---@return string?
local function utc(timestamp)
  if not timestamp then
    return nil
  end
  local stamp, zone = timestamp:match "^(%d+%-%d+%-%d+T%d+:%d+:%d+)%.?%d*(.*)$"
  if stamp and (zone == "" or zone == "Z" or zone == "+00:00") then
    return stamp .. "Z"
  end
  return timestamp
end

---@param pr octo.forge.PullRequestRef
local function key(pr)
  return string.format("%s/%s#%d", pr.repo.owner, pr.repo.name, pr.number)
end

---Percent-encode everything but unreserved characters, and `/` when `keep_slashes`.
---@param value string
---@param keep_slashes? boolean
local function encode(value, keep_slashes)
  local pattern = keep_slashes and "[^%w%-%._~/]" or "[^%w%-%._~]"
  return (value:gsub(pattern, function(c)
    return string.format("%%%02X", c:byte())
  end))
end

---A string literal in Bitbucket's query language.
---@param value string
local function bbql_string(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---@param full_name string "workspace/repo"
---@param host string
---@return octo.forge.RepoRef
local function repo_ref(full_name, host)
  local owner, name = full_name:match "^([^/]+)/(.+)$"
  return { host = host, owner = owner, name = name }
end

---@param node octo.forge.bitbucket.Comment
---@param viewer? octo.forge.bitbucket.Account
---@return octo.forge.Comment
local function comment(node, viewer)
  local mine = viewer ~= nil and node.user ~= nil and node.user.uuid == viewer.uuid
  return {
    id = tostring(node.id),
    author = user(node.user),
    body = node.content.raw,
    created_at = utc(node.created_on) --[[@as string]],
    edited_at = node.updated_on ~= node.created_on and utc(node.updated_on) or nil,
    url = node.links and node.links.html and node.links.html.href,
    pending = node.pending == true,
    viewer_is_author = mine,
    viewer_can_edit = mine,
    viewer_can_delete = mine,
  }
end

---Where an inline comment sits. A comment on the new side has `to`, on the old side `from`.
---@param inline octo.forge.bitbucket.Inline
---@return octo.forge.Side, octo.forge.LineRange?
local function position(inline)
  if inline.to then
    return "RIGHT", { first = inline.start_to or inline.to, last = inline.to }
  elseif inline.from then
    return "LEFT", { first = inline.start_from or inline.from, last = inline.from }
  end
  return "RIGHT", nil
end

---Bitbucket returns a flat list in which each reply points at the comment it answers. A thread is
---an inline root comment and everything below it; general comments and deleted ones are left out.
---@param nodes octo.forge.bitbucket.Comment[]
---@param viewer? octo.forge.bitbucket.Account
---@return octo.forge.Thread[]
function M.threads(nodes, viewer)
  local by_id = {} ---@type table<integer, octo.forge.bitbucket.Comment>
  for _, node in ipairs(nodes) do
    by_id[node.id] = node
  end
  ---@param node octo.forge.bitbucket.Comment
  local function root(node)
    while node.parent and by_id[node.parent.id] do
      node = by_id[node.parent.id]
    end
    return node
  end

  local ordered = vim.list_slice(nodes)
  table.sort(ordered, function(a, b)
    return a.id < b.id
  end)
  local threads, by_root = {}, {} ---@type octo.forge.Thread[], table<integer, octo.forge.Thread>
  for _, node in ipairs(ordered) do
    local top = root(node)
    if top.inline and not node.deleted then
      local thread = by_root[top.id]
      if not thread then
        local side, lines = position(top.inline)
        thread = {
          id = tostring(top.id),
          path = top.inline.path,
          side = side,
          lines = lines,
          original_lines = lines and vim.deepcopy(lines),
          outdated = false,
          resolved = top.resolution ~= nil,
          resolved_by = top.resolution and top.resolution.user and user(top.resolution.user) or nil,
          comments = {},
        }
        by_root[top.id] = thread
        table.insert(threads, thread)
      end
      table.insert(thread.comments, comment(node, viewer))
    end
  end
  return threads
end

---@param quoted string a path from a diff header, possibly quoted, with its a/ or b/ prefix
---@return string?
local function header_path(quoted)
  local path = quoted:match '^"(.*)"$' or quoted
  if path == "/dev/null" then
    return nil
  end
  return (path:gsub("^[ab]/", ""))
end

---Split a git diff into each file's hunks (from its first "@@"), keyed by the file's path on the
---new side, or the old side for deletions. Files without hunks (binary, excluded) are absent.
---@param diff string
---@return table<string, string>
function M.split_diff(diff)
  local patches = {} ---@type table<string, string>
  local old, new, hunks ---@type string?, string?, string[]?
  local function flush()
    local path = new or old
    if path and hunks then
      while #hunks > 0 and hunks[#hunks] == "" do
        table.remove(hunks)
      end
      patches[path] = table.concat(hunks, "\n")
    end
    old, new, hunks = nil, nil, nil
  end
  for line in vim.gsplit(diff, "\n", { plain = true }) do
    if vim.startswith(line, "diff --git ") then
      flush()
    elseif hunks then
      table.insert(hunks, line)
    elseif vim.startswith(line, "--- ") then
      old = header_path(line:sub(5))
    elseif vim.startswith(line, "+++ ") then
      new = header_path(line:sub(5))
    elseif vim.startswith(line, "@@") then
      hunks = { line }
    end
  end
  flush()
  return patches
end

---------------------------------------------------------------------------------------------------
-- Requests (only inside async.run)
---------------------------------------------------------------------------------------------------

---@param repo octo.forge.RepoRef
---@param suffix string
function Bitbucket:repo_url(repo, suffix)
  return string.format("%s/repositories/%s/%s%s", self.api, repo.owner, repo.name, suffix)
end

---@param pr octo.forge.PullRequestRef
---@param suffix string
function Bitbucket:pr_url(pr, suffix)
  return self:repo_url(pr.repo, string.format("/pullrequests/%d%s", pr.number, suffix))
end

---@async
---@param method string
---@param url string
---@param body? table
---@return any
function Bitbucket:send(method, url, body)
  return async.await(self.transport.request, method, url, { body = body })
end

---Every item of a paginated collection, following `next` links.
---@async
---@param url string
---@param pagelen? integer items per page, 100 unless the endpoint allows fewer
---@return any[]
function Bitbucket:get_all(url, pagelen)
  local items = {} ---@type any[]
  local next_url = url .. (url:find("?", 1, true) and "&" or "?") .. "pagelen=" .. (pagelen or 100) ---@type string?
  while next_url do
    local page = self:send("GET", next_url) ---@type { values: any[], next?: string }
    vim.list_extend(items, page.values)
    next_url = page.next
  end
  return items
end

---The signed-in account, or nil when requests are anonymous. Only a successful lookup is kept, so
---one failed request doesn't leave the session anonymous.
---@async
---@return octo.forge.bitbucket.Account?
---@return string? err why the lookup failed
function Bitbucket:viewer()
  if self.account then
    return self.account
  end
  local account, err = async.attempt(self.transport.request, "GET", self.api .. "/user", nil)
  self.account = account
  return account, err
end

---@async
---@return octo.forge.bitbucket.Account
function Bitbucket:signed_in()
  local account, err = self:viewer()
  return account or error("Couldn't tell who you are on Bitbucket: " .. tostring(err), 0)
end

---@async
---@param pr octo.forge.PullRequestRef
---@return octo.forge.bitbucket.Comment[]
function Bitbucket:comment_nodes(pr)
  return self:get_all(self:pr_url(pr, "/comments"))
end

---@async
---@param pr octo.forge.PullRequestRef
---@return octo.forge.Thread[]
function Bitbucket:all_threads(pr)
  local nodes = self:comment_nodes(pr)
  return M.threads(nodes, self:viewer())
end

---The viewer's pending comments, replies before the comments they answer.
---@async
---@param pr octo.forge.PullRequestRef
---@return octo.forge.bitbucket.Comment[]
function Bitbucket:pending_comments(pr)
  local viewer = self:signed_in()
  local nodes = self:comment_nodes(pr)
  local by_id, depth = {}, {} ---@type table<integer, octo.forge.bitbucket.Comment>, table<integer, integer>
  for _, node in ipairs(nodes) do
    by_id[node.id] = node
  end
  local pending = vim.tbl_filter(function(node) ---@param node octo.forge.bitbucket.Comment
    return node.pending == true and not node.deleted and node.user ~= nil and node.user.uuid == viewer.uuid
  end, nodes)
  for _, node in ipairs(pending) do
    local d, at = 0, node
    while at.parent and by_id[at.parent.id] do
      d, at = d + 1, by_id[at.parent.id]
    end
    depth[node.id] = d
  end
  table.sort(pending, function(a, b)
    return depth[a.id] > depth[b.id]
  end)
  return pending
end

---The repository a pull request's source branch lives in, which differs from its own for forks.
---@async
---@param pr octo.forge.PullRequestRef
---@return octo.forge.RepoRef
function Bitbucket:source_repo(pr)
  if not self.sources[key(pr)] then
    local node = self:send("GET", self:pr_url(pr, "?fields=source.repository.full_name"))
    self.sources[key(pr)] = repo_ref(node.source.repository.full_name, self.host)
  end
  return self.sources[key(pr)]
end

---------------------------------------------------------------------------------------------------
-- octo.Forge
---------------------------------------------------------------------------------------------------

local list_states = { open = { "OPEN" }, merged = { "MERGED" }, closed = { "DECLINED", "SUPERSEDED" } }
local order_fields = { created = "created_on", updated = "updated_on" }

function Bitbucket:pull_requests(repo, filter, cb)
  async.run( ---@async
    function()
      if filter.labels and #filter.labels > 0 then
        error("Bitbucket pull requests have no labels", 0)
      end
      local wanted_states = {} ---@type string[]
      for _, state in ipairs(filter.states or { "open" }) do
        for _, name in ipairs(list_states[state]) do
          table.insert(wanted_states, "state=" .. bbql_string(name))
        end
      end
      -- without a state in the query Bitbucket lists only open pull requests
      local q = { "(" .. table.concat(wanted_states, " OR ") .. ")" }
      if filter.head then
        table.insert(q, "source.branch.name=" .. bbql_string(filter.head.name))
      end
      if filter.base then
        table.insert(q, "destination.branch.name=" .. bbql_string(filter.base))
      end
      local order = filter.order or { field = "created", direction = "desc" }
      local sort = (order.direction == "desc" and "-" or "") .. order_fields[order.field]
      local url = self:repo_url(repo, "/pullrequests?sort=" .. sort .. "&q=" .. encode(table.concat(q, " AND ")))
      -- 50 is the most this endpoint pages by
      local nodes = self:get_all(url, 50) ---@type octo.forge.bitbucket.PullRequest[]
      local wanted = filter.head
        and filter.head.repo
        and (filter.head.repo.owner .. "/" .. filter.head.repo.name):lower()
      local prs = {} ---@type octo.forge.PullRequestSummary[]
      for _, node in ipairs(nodes) do
        local base_repo = repo_ref(node.destination.repository.full_name, self.host)
        -- the source repository is null once a fork is deleted
        local source = node.source.repository
        local head_repo = source and repo_ref(source.full_name, self.host) or base_repo
        if not wanted or source and source.full_name:lower() == wanted then
          local ref = { repo = repo, number = node.id }
          self.sources[key(ref)] = head_repo
          table.insert(prs, {
            ref = ref,
            title = node.title,
            body = node.summary and node.summary.raw or "",
            state = states[node.state] or "closed",
            draft = node.draft == true,
            author = user(node.author),
            url = node.links.html.href,
            base = { name = node.destination.branch.name, repo = base_repo },
            head = { name = node.source.branch.name, repo = head_repo },
            labels = {},
            created_at = utc(node.created_on),
            updated_at = utc(node.updated_on),
            queued = node.queued,
          })
        end
      end
      return prs
    end,
    cb
  )
end

function Bitbucket:pull_request(pr, cb)
  async.run( ---@async
    function()
      local node = self:send("GET", self:pr_url(pr, "")) ---@type octo.forge.bitbucket.PullRequest
      local base_repo = repo_ref(node.destination.repository.full_name, self.host)
      local head_repo = repo_ref(node.source.repository.full_name, self.host)
      -- pull requests carry abbreviated hashes; the diff base is the merge base
      local function full_hash(repo, hash)
        return function(done)
          self.transport.request("GET", self:repo_url(repo, "/commit/" .. hash .. "?fields=hash"), nil, done)
        end
      end
      local source, destination = node.source.commit.hash, node.destination.commit.hash
      local results = async.all {
        full_hash(head_repo, source),
        full_hash(base_repo, destination),
        function(done)
          local url = self:repo_url(base_repo, string.format("/merge-base/%s..%s?fields=hash", source, destination))
          self.transport.request("GET", url, nil, function(_, merge_base)
            -- unknown across some forks; fall back to the base below
            done(nil, merge_base or false)
          end)
        end,
      }
      local head_sha, base_sha = results[1].hash, results[2].hash ---@type string, string
      self.sources[key(pr)] = head_repo

      ---@type octo.forge.PullRequest
      return {
        ref = pr,
        id = tostring(node.id),
        title = node.title,
        body = node.summary and node.summary.raw or "",
        state = states[node.state] or "closed",
        draft = node.draft == true,
        author = user(node.author),
        url = node.links.html.href,
        base = { name = node.destination.branch.name, sha = base_sha, repo = base_repo },
        head = { name = node.source.branch.name, sha = head_sha, repo = head_repo },
        merge_base = results[3] and results[3].hash or base_sha,
      }
    end,
    cb
  )
end

function Bitbucket:changes(pr, range, cb)
  async.run( ---@async
    function()
      -- Bitbucket's revspec puts the head first, the reverse of git
      local stat_url = range and self:repo_url(pr.repo, string.format("/diffstat/%s..%s", range.head, range.base))
        or self:pr_url(pr, "/diffstat")
      local diff_url = range and self:repo_url(pr.repo, string.format("/diff/%s..%s", range.head, range.base))
        or self:pr_url(pr, "/diff")
      local results = async.all {
        function(done)
          async.run( ---@async
            function()
              return self:get_all(stat_url)
            end,
            done
          )
        end,
        function(done)
          self.transport.request("GET", diff_url, { raw = true }, done)
        end,
      }
      local stats = results[1] ---@type octo.forge.bitbucket.DiffStat[]
      local patches = M.split_diff(results[2] or "")
      return vim.tbl_map(function(stat) ---@param stat octo.forge.bitbucket.DiffStat
        local path = stat.new and stat.new.path or stat.old.path
        ---@type octo.forge.ChangedFile
        return {
          path = path,
          previous_path = stat.status == "renamed" and stat.old and stat.old.path or nil,
          status = file_statuses[stat.status] or "M",
          additions = stat.lines_added or 0,
          deletions = stat.lines_removed or 0,
          patch = patches[path],
        }
      end, stats)
    end,
    cb
  )
end

function Bitbucket:contents(pr, commit, path, cb)
  async.run( ---@async
    function()
      ---@async
      ---@param repo octo.forge.RepoRef
      ---@return string?
      local function at(repo)
        local url = self:repo_url(repo, string.format("/src/%s/%s", commit, encode(path, true)))
        return async.await(self.transport.request, "GET", url, { raw = true, allow_missing = true })
      end
      local text = at(pr.repo)
      -- a fork's commits live in the fork
      local source = text == nil and self:source_repo(pr)
      if source and (source.owner ~= pr.repo.owner or source.name ~= pr.repo.name) then
        text = at(source)
      end
      return text or ""
    end,
    cb
  )
end

function Bitbucket:threads(pr, cb)
  async.run( ---@async
    function()
      return self:all_threads(pr)
    end,
    cb
  )
end

function Bitbucket:comment(pr, new, cb)
  async.run( ---@async
    function()
      if new.reply_to and new.anchor then
        error("A comment can't both reply to a thread and start one", 0)
      end
      local payload = { content = { raw = new.body } } ---@type table<string, any>
      if new.draft then
        if not (new.reply_to or new.anchor) then
          error("Top-level comments can't be drafts; pass the text to submit instead", 0)
        end
        payload.pending = true
      end
      if new.reply_to then
        payload.parent = { id = tonumber(new.reply_to) }
      elseif new.anchor then
        local anchor = new.anchor --[[@as octo.forge.Anchor]]
        if anchor.commit then
          error("Bitbucket can't anchor a comment to a single commit", 0)
        end
        local multiline = anchor.lines.first ~= anchor.lines.last
        local inline = { path = anchor.path } ---@type table<string, any>
        if anchor.side == "RIGHT" then
          inline.to = anchor.lines.last
          inline.start_to = multiline and anchor.lines.first or nil
        else
          inline.from = anchor.lines.last
          inline.start_from = multiline and anchor.lines.first or nil
        end
        payload.inline = inline
      end

      local viewer = self:signed_in()
      local created = self:send("POST", self:pr_url(pr, "/comments"), payload) ---@type octo.forge.bitbucket.Comment
      local posted = comment(created, viewer)
      if new.anchor then
        return { comment = posted, thread = M.threads({ created }, viewer)[1] }
      end
      if new.reply_to then
        for _, thread in ipairs(self:all_threads(pr)) do
          if thread.id == new.reply_to then
            return { comment = posted, thread = thread }
          end
        end
        error("Posted comment " .. posted.id .. " but could not find its thread", 0)
      end
      return { comment = posted }
    end,
    cb
  )
end

function Bitbucket:edit(pr, comment_id, body, cb)
  async.run( ---@async
    function()
      local viewer = self:signed_in()
      local url = self:pr_url(pr, "/comments/" .. comment_id)
      return comment(self:send("PUT", url, { content = { raw = body } }), viewer)
    end,
    cb
  )
end

function Bitbucket:delete(pr, comment_id, cb)
  async.run( ---@async
    function()
      self:send("DELETE", self:pr_url(pr, "/comments/" .. comment_id))
    end,
    cb
  )
end

function Bitbucket:react(_, _, _, _, cb)
  vim.schedule(function()
    cb "Bitbucket has no reactions"
  end)
end

function Bitbucket:resolve(pr, thread_id, resolved, cb)
  async.run( ---@async
    function()
      local thread ---@type octo.forge.Thread?
      for _, t in ipairs(self:all_threads(pr)) do
        if t.id == thread_id then
          thread = t
        end
      end
      if not thread then
        error("Thread not found: " .. thread_id, 0)
      end
      if thread.resolved == resolved then
        return thread
      end
      local url = self:pr_url(pr, "/comments/" .. thread_id .. "/resolve")
      if resolved then
        local resolution = self:send("POST", url) ---@type { user?: octo.forge.bitbucket.Account }?
        thread.resolved_by = resolution and resolution.user and user(resolution.user) or nil
      else
        self:send("DELETE", url)
        thread.resolved_by = nil
      end
      thread.resolved = resolved
      return thread
    end,
    cb
  )
end

local verdict_paths = { comment = false, approve = "/approve", request_changes = "/request-changes" }

function Bitbucket:submit(pr, verdict, body, cb)
  async.run( ---@async
    function()
      local verdict_path = verdict_paths[verdict]
      if verdict_path == nil then
        error("Unknown verdict: " .. tostring(verdict), 0)
      end
      -- Bitbucket has no review object: publishing a draft means clearing its pending flag
      local publish = vim.tbl_map(function(node) ---@param node octo.forge.bitbucket.Comment
        return function(done)
          local url = self:pr_url(pr, "/comments/" .. node.id)
          self.transport.request("PUT", url, { body = { content = { raw = node.content.raw }, pending = false } }, done)
        end
      end, self:pending_comments(pr))
      async.all(publish)
      if body and vim.trim(body) ~= "" then
        self:send("POST", self:pr_url(pr, "/comments"), { content = { raw = body } })
      end
      if verdict_path then
        self:send("POST", self:pr_url(pr, verdict_path))
      end
    end,
    cb
  )
end

function Bitbucket:discard(pr, cb)
  async.run( ---@async
    function()
      for _, node in ipairs(self:pending_comments(pr)) do
        self:send("DELETE", self:pr_url(pr, "/comments/" .. node.id))
      end
    end,
    cb
  )
end

function Bitbucket:set_viewed(_, _, _, cb)
  vim.schedule(function()
    cb "Bitbucket doesn't track viewed files"
  end)
end

return M
