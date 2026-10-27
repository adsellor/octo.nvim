---GitHub adapter for the forge seam. Everything GitHub-specific about pull request review lives
---here: GraphQL and REST shapes, node ids, the pending review object, diff positions, pagination.

local async = require "octo.forge.async"
local documents = require "octo.forge.github.documents"

local M = {}

---@class octo.forge.GitHub : octo.Forge
---@field host string
---@field private transport octo.forge.github.Transport
---@field private node_ids table<string, string> pull request node ids, which never change
local GitHub = {}
GitHub.__index = GitHub

---@param opts { host: string, transport?: octo.forge.github.Transport }
---@return octo.forge.GitHub
function M.new(opts)
  return setmetatable({
    id = "github",
    host = opts.host,
    transport = opts.transport or require "octo.forge.github.transport",
    node_ids = {},
  }, GitHub)
end

---What GitHub sends back, as far as the mapping reads it.
---@class octo.forge.github.Actor
---@field login string

---@class octo.forge.github.ReactionGroup
---@field content string
---@field viewerHasReacted boolean
---@field reactors { totalCount: integer }

---Review comments, issue comments and reviews.
---@class octo.forge.github.Comment
---@field id string
---@field body string
---@field createdAt string
---@field lastEditedAt? string
---@field url string
---@field author? octo.forge.github.Actor null for deleted accounts
---@field viewerDidAuthor boolean
---@field viewerCanUpdate boolean
---@field viewerCanDelete boolean
---@field reactionGroups? octo.forge.github.ReactionGroup[]
---@field state? string reviews only
---@field diffHunk? string review comments only
---@field originalCommit? { oid: string } review comments only
---@field pullRequestReview? { state: string } review comments only

---@class octo.forge.github.Thread
---@field id string
---@field path string
---@field diffSide octo.forge.Side
---@field line? integer
---@field startLine? integer
---@field originalLine? integer
---@field originalStartLine? integer
---@field isOutdated boolean
---@field isResolved boolean
---@field resolvedBy? octo.forge.github.Actor
---@field comments { nodes: octo.forge.github.Comment[] }

---@class octo.forge.github.Repository
---@field owner octo.forge.github.Actor
---@field name string

---@class octo.forge.github.Connection<T>: { nodes: T[], pageInfo: { hasNextPage: boolean, endCursor: string } }

---The pull request, with whichever fields a query asked for.
---@class octo.forge.github.PullRequest
---@field id string
---@field title string
---@field body string
---@field state string
---@field isDraft boolean
---@field url string
---@field author? octo.forge.github.Actor
---@field baseRefName string
---@field baseRefOid string
---@field headRefName string
---@field headRefOid string
---@field baseRepository octo.forge.github.Repository
---@field headRepository? octo.forge.github.Repository null once the fork is deleted
---@field reviews { nodes: { id: string, viewerDidAuthor: boolean }[] }
---@field reviewThreads octo.forge.github.Connection<octo.forge.github.Thread>
---@field files octo.forge.github.Connection<{ path: string, viewerViewedState: string }>
---@field number integer
---@field createdAt string
---@field updatedAt string
---@field labels { nodes: { name: string }[] }
---@field isInMergeQueue? boolean github.com only
---@field stackEntry? { position: integer, stack?: { size: integer } } github.com only

---A changed file from the REST API.
---@class octo.forge.github.File
---@field filename string
---@field previous_filename? string
---@field status string
---@field additions integer
---@field deletions integer
---@field patch? string

local features = { draft = true, viewed = true, resolve = true, commit_comments = true, reactions = true }

function GitHub:supports(feature)
  return features[feature] == true
end

---@param pr octo.forge.PullRequestRef
local function key(pr)
  return string.format("%s/%s#%d", pr.repo.owner, pr.repo.name, pr.number)
end

---@param pr octo.forge.PullRequestRef
local function pr_variables(pr)
  return { owner = pr.repo.owner, name = pr.repo.name, number = pr.number }
end

---------------------------------------------------------------------------------------------------
-- Mapping GitHub shapes to forge types
---------------------------------------------------------------------------------------------------

local states = { OPEN = "open", CLOSED = "closed", MERGED = "merged" }
local file_statuses = { added = "A", removed = "D", modified = "M", renamed = "R", copied = "C", changed = "M" }
local viewed_states = { VIEWED = "viewed", UNVIEWED = "unviewed", DISMISSED = "dismissed" }
local events = { comment = "COMMENT", approve = "APPROVE", request_changes = "REQUEST_CHANGES" }

---@param author? octo.forge.github.Actor
---@return octo.forge.User
local function user(author)
  -- deleted accounts come back as null
  return { login = author and author.login or "ghost" }
end

---@param groups? octo.forge.github.ReactionGroup[]
---@return octo.forge.Reaction[]?
local function reactions(groups)
  if not groups then
    return nil
  end
  return vim.tbl_map(function(group) ---@param group octo.forge.github.ReactionGroup
    return { content = group.content, count = group.reactors.totalCount, viewer_reacted = group.viewerHasReacted }
  end, groups)
end

---Review comments, issue comments and reviews all map the same way.
---@param node octo.forge.github.Comment
---@param pending boolean
---@return octo.forge.Comment
local function comment(node, pending)
  return {
    id = node.id,
    author = user(node.author),
    body = node.body,
    created_at = node.createdAt,
    edited_at = node.lastEditedAt,
    url = node.url,
    pending = pending,
    viewer_is_author = node.viewerDidAuthor,
    viewer_can_edit = node.viewerCanUpdate,
    viewer_can_delete = node.viewerCanDelete,
    reactions = reactions(node.reactionGroups),
  }
end

---@param node octo.forge.github.Comment
---@return octo.forge.Comment
local function review_comment(node)
  return comment(node, node.pullRequestReview ~= nil and node.pullRequestReview.state == "PENDING")
end

---@param first? integer
---@param last? integer
---@return octo.forge.LineRange?
local function line_range(first, last)
  if not last then
    return nil
  end
  return { first = first or last, last = last }
end

---@param node octo.forge.github.Thread
---@return octo.forge.Thread
local function thread(node)
  local comments = vim.tbl_map(review_comment, node.comments.nodes)
  local root = node.comments.nodes[1] or {} ---@type octo.forge.github.Comment
  return {
    id = node.id,
    path = node.path,
    side = node.diffSide,
    lines = line_range(node.startLine, node.line),
    original_lines = line_range(node.originalStartLine, node.originalLine),
    original_commit = root.originalCommit and root.originalCommit.oid,
    outdated = node.isOutdated,
    resolved = node.isResolved,
    resolved_by = node.resolvedBy and user(node.resolvedBy) or nil,
    diff_hunk = root.diffHunk,
    comments = comments,
  }
end

---@param file octo.forge.github.File
---@return octo.forge.ChangedFile
local function changed_file(file)
  return {
    path = file.filename,
    previous_path = file.previous_filename,
    status = file_statuses[file.status] or "M",
    additions = file.additions,
    deletions = file.deletions,
    patch = file.patch,
  }
end

---The position GitHub's legacy comment API wants: lines below the patch's first "@@" header,
---counting later headers too.
---@param patch string
---@param side octo.forge.Side
---@param line integer
---@return integer?
function M.diff_position(patch, side, line)
  local position, old, new = -1, 0, 0
  for text in vim.gsplit(patch, "\n", { plain = true }) do
    local old_start, new_start = text:match "^@@ %-(%d+),?%d* %+(%d+),?%d* @@"
    if old_start then
      old, new = tonumber(old_start) or 0, tonumber(new_start) or 0
      position = position + 1
    elseif position >= 0 then
      position = position + 1
      local mark = text:sub(1, 1)
      if mark == "-" then
        if side == "LEFT" and old == line then
          return position
        end
        old = old + 1
      elseif mark == "+" then
        if side == "RIGHT" and new == line then
          return position
        end
        new = new + 1
      elseif mark ~= "\\" then
        if (side == "LEFT" and old == line) or (side == "RIGHT" and new == line) then
          return position
        end
        old, new = old + 1, new + 1
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------------------------------
-- Requests (only inside async.run)
---------------------------------------------------------------------------------------------------

---@async
---@private
---@param document string
---@param variables table
---@return any data
function GitHub:query(document, variables)
  return async.await(self.transport.graphql, self.host, document, variables)
end

---@async
---@private
---@param method string
---@param path string
---@param opts? octo.forge.github.RestOpts
---@return any
function GitHub:rest(method, path, opts)
  return async.await(self.transport.rest, self.host, method, path, opts)
end

---Follow a connection's pages. `connection(data)` picks the connection out of a response.
---@async
---@private
---@param document string
---@param variables table
---@param connection fun(data: any): { nodes: any[], pageInfo: { hasNextPage: boolean, endCursor: string } }
---@return any[]
function GitHub:query_all(document, variables, connection)
  local nodes, cursor = {}, nil ---@type any[], string?
  repeat
    local data = self:query(document, vim.tbl_extend("force", variables, { cursor = cursor }))
    local page = connection(data)
    vim.list_extend(nodes, page.nodes)
    cursor = page.pageInfo.endCursor
  until not page.pageInfo.hasNextPage
  return nodes
end

---@param repo octo.forge.RepoRef
local function repo_path(repo)
  return string.format("repos/%s/%s", repo.owner, repo.name)
end

---@param data any
---@return octo.forge.github.PullRequest
local function pull_request_node(data)
  local node = data.repository and data.repository.pullRequest ---@type octo.forge.github.PullRequest?
  if not node then
    error("Pull request not found", 0)
  end
  return node
end

---Fresh state a write needs. The pending review is looked up every time because it can be
---submitted or deleted from anywhere, including the website.
---@async
---@private
---@param pr octo.forge.PullRequestRef
---@return { id: string, head: string, pending_review?: string }
function GitHub:review_target(pr)
  local node = pull_request_node(self:query(documents.review_target, pr_variables(pr)))
  self.node_ids[key(pr)] = node.id
  local pending_review ---@type string?
  for _, review in ipairs(node.reviews.nodes) do
    if review.viewerDidAuthor then
      pending_review = review.id
    end
  end
  return { id = node.id, head = node.headRefOid, pending_review = pending_review }
end

---@async
---@private
---@param pr octo.forge.PullRequestRef
---@return string
function GitHub:node_id(pr)
  return self.node_ids[key(pr)] or self:review_target(pr).id
end

---The viewer's pending review. With `create`, starts one when there is none.
---@async
---@private
---@param pr octo.forge.PullRequestRef
---@param create boolean
---@return string?
function GitHub:pending_review(pr, create)
  local target = self:review_target(pr)
  if target.pending_review or not create then
    return target.pending_review
  end
  local data = self:query(documents.add_review, { input = { pullRequestId = target.id } })
  return data.addPullRequestReview.pullRequestReview.id
end

---@async
---@private
---@param pr octo.forge.PullRequestRef
---@param comment_id string
---@return octo.forge.Posted
function GitHub:posted(pr, comment_id)
  for _, t in ipairs(self:all_threads(pr)) do
    for _, c in ipairs(t.comments) do
      if c.id == comment_id then
        return { comment = c, thread = t }
      end
    end
  end
  error("Posted comment " .. comment_id .. " but could not find its thread", 0)
end

---@async
---@private
---@param pr octo.forge.PullRequestRef
---@return octo.forge.Thread[]
function GitHub:all_threads(pr)
  local nodes = self:query_all(documents.threads, pr_variables(pr), function(data)
    return pull_request_node(data).reviewThreads
  end)
  return vim.tbl_map(thread, nodes)
end

---@async
---@private
---@param pr octo.forge.PullRequestRef
---@param anchor octo.forge.Anchor
---@param body string
---@return octo.forge.Posted
function GitHub:add_commit_comment(pr, anchor, body)
  if anchor.lines.first ~= anchor.lines.last then
    error("GitHub can't place a multi-line comment on a single commit", 0)
  end
  local commit = self:rest("GET", string.format("%s/commits/%s", repo_path(pr.repo), anchor.commit))
  local patch ---@type string?
  local files = commit.files or {} ---@type octo.forge.github.File[]
  for _, file in ipairs(files) do
    if file.filename == anchor.path then
      patch = file.patch
    end
  end
  local position = patch and M.diff_position(patch, anchor.side, anchor.lines.last)
  if not position then
    error(string.format("Line %d of %s is not in commit %s's diff", anchor.lines.last, anchor.path, anchor.commit), 0)
  end
  local data = self:query(documents.add_commit_comment, {
    input = {
      pullRequestReviewId = self:pending_review(pr, true),
      commitOID = anchor.commit,
      path = anchor.path,
      position = position,
      body = body,
    },
  })
  return self:posted(pr, data.addPullRequestReviewComment.comment.id)
end

---------------------------------------------------------------------------------------------------
-- octo.Forge
---------------------------------------------------------------------------------------------------

local list_states = { open = "OPEN", closed = "CLOSED", merged = "MERGED" }
local order_fields = { created = "CREATED_AT", updated = "UPDATED_AT" }

---@param node? octo.forge.github.Repository
---@param host string
---@return octo.forge.RepoRef?
local function repo_of(node, host)
  return node and { host = host, owner = node.owner.login, name = node.name }
end

function GitHub:pull_requests(repo, filter, cb)
  async.run( ---@async
    function()
      local order = filter.order or { field = "created", direction = "desc" }
      local document = documents.pull_requests:gsub(
        "{github_com}",
        self.host == "github.com" and documents.pull_requests_github_com or ""
      )
      ---@type octo.forge.github.PullRequest[]
      local nodes = self:query_all(document, {
        owner = repo.owner,
        name = repo.name,
        states = vim.tbl_map(
          ---@param state octo.forge.PullRequestState
          function(state)
            return list_states[state]
          end,
          filter.states or { "open" }
        ),
        head = filter.head and filter.head.name,
        base = filter.base,
        labels = filter.labels,
        orderBy = { field = order_fields[order.field], direction = order.direction:upper() },
      }, function(data)
        if not data.repository then
          error(string.format("Repository %s/%s not found", repo.owner, repo.name), 0)
        end
        return data.repository.pullRequests
      end)
      local wanted = filter.head and filter.head.repo
      local prs = {} ---@type octo.forge.PullRequestSummary[]
      for _, node in ipairs(nodes) do
        local base_repo = repo_of(node.baseRepository, self.host) or repo
        -- the head repository is null once a fork is deleted
        local head_repo = repo_of(node.headRepository, self.host) or base_repo
        -- GitHub compares owners and names without case
        if
          not wanted
          or head_repo.owner:lower() == wanted.owner:lower() and head_repo.name:lower() == wanted.name:lower()
        then
          local stack = node.stackEntry
          table.insert(prs, {
            ref = { repo = repo, number = node.number },
            title = node.title,
            body = node.body or "",
            state = states[node.state] or "closed",
            draft = node.isDraft == true,
            author = user(node.author),
            url = node.url,
            base = { name = node.baseRefName, repo = base_repo },
            head = { name = node.headRefName, repo = head_repo },
            labels = vim.tbl_map(
              ---@param label { name: string }
              function(label)
                return label.name
              end,
              node.labels and node.labels.nodes or {}
            ),
            created_at = node.createdAt,
            updated_at = node.updatedAt,
            queued = node.isInMergeQueue,
            stack = stack and stack.stack and { position = stack.position, size = stack.stack.size } or nil,
          })
        end
      end
      return prs
    end,
    cb
  )
end

function GitHub:pull_request(pr, cb)
  async.run( ---@async
    function()
      local node = pull_request_node(self:query(documents.pull_request, pr_variables(pr)))
      self.node_ids[key(pr)] = node.id
      local base_repo = { host = self.host, owner = node.baseRepository.owner.login, name = node.baseRepository.name }
      -- the head repository is null once a fork is deleted
      local head_repo = node.headRepository
          and { host = self.host, owner = node.headRepository.owner.login, name = node.headRepository.name }
        or base_repo

      local compare = async.attempt(
        self.transport.rest,
        self.host,
        "GET",
        string.format("%s/compare/%s...%s", repo_path(pr.repo), node.baseRefOid, node.headRefOid),
        nil
      )
      ---@cast compare { merge_base_commit?: { sha: string } }?
      local merge_base = compare and compare.merge_base_commit and compare.merge_base_commit.sha or node.baseRefOid

      ---@type octo.forge.PullRequest
      return {
        ref = pr,
        id = node.id,
        title = node.title,
        body = node.body,
        state = states[node.state],
        draft = node.isDraft,
        author = user(node.author),
        url = node.url,
        base = { name = node.baseRefName, sha = node.baseRefOid, repo = base_repo },
        head = { name = node.headRefName, sha = node.headRefOid, repo = head_repo },
        merge_base = merge_base,
      }
    end,
    cb
  )
end

function GitHub:changes(pr, range, cb)
  async.run( ---@async
    function()
      local path = repo_path(pr.repo)
      if range then
        local compare = self:rest("GET", string.format("%s/compare/%s...%s", path, range.base, range.head))
        return vim.tbl_map(changed_file, compare.files or {})
      end

      local results = async.all {
        function(done)
          self.transport.rest(self.host, "GET", string.format("%s/pulls/%d/files", path, pr.number), {
            paginate = true,
          }, done)
        end,
        function(done)
          async.run( ---@async
            function()
              return self:query_all(documents.viewed_files, pr_variables(pr), function(data)
                return pull_request_node(data).files
              end)
            end,
            done
          )
        end,
      }
      local viewed = {} ---@type table<string, octo.forge.ViewedState>
      local viewed_nodes = results[2] ---@type { path: string, viewerViewedState: string }[]
      for _, node in ipairs(viewed_nodes) do
        viewed[node.path] = viewed_states[node.viewerViewedState]
      end
      return vim.tbl_map(function(file) ---@param file octo.forge.github.File
        local changed = changed_file(file)
        changed.viewed = viewed[changed.path] or "unviewed"
        return changed
      end, results[1])
    end,
    cb
  )
end

function GitHub:contents(pr, commit, path, cb)
  async.run( ---@async
    function()
      -- the base repository serves every commit of a pull request, forks' included
      local data = self:query(
        documents.contents,
        { owner = pr.repo.owner, name = pr.repo.name, expression = commit .. ":" .. path }
      )
      local blob = data.repository and data.repository.object ---@type { text?: string }?
      return blob and blob.text or ""
    end,
    cb
  )
end

function GitHub:threads(pr, cb)
  async.run( ---@async
    function()
      return self:all_threads(pr)
    end,
    cb
  )
end

function GitHub:comment(pr, new, cb)
  async.run( ---@async
    function()
      if new.reply_to and new.anchor then
        error("A comment can't both reply to a thread and start one", 0)
      end

      if new.reply_to then
        local input = { pullRequestReviewThreadId = new.reply_to, body = new.body } ---@type table<string, any>
        if new.draft then
          input.pullRequestReviewId = self:pending_review(pr, true)
        end
        local data = self:query(documents.add_reply, { input = input })
        local id = data.addPullRequestReviewThreadReply.comment.id ---@type string
        local t = thread(self:query(documents.thread, { id = new.reply_to }).node)
        for _, c in ipairs(t.comments) do
          if c.id == id then
            return { comment = c, thread = t }
          end
        end
        error("Posted comment " .. id .. " but could not find it in its thread", 0)
      end

      if new.anchor then
        local anchor = new.anchor --[[@as octo.forge.Anchor]]
        if anchor.commit then
          if not new.draft then
            error("On GitHub, comments on a single commit must be part of a review", 0)
          end
          return self:add_commit_comment(pr, anchor, new.body)
        end
        local multiline = anchor.lines.first ~= anchor.lines.last
        if new.draft then
          local data = self:query(documents.add_thread, {
            input = {
              pullRequestReviewId = self:pending_review(pr, true),
              body = new.body,
              path = anchor.path,
              side = anchor.side,
              line = anchor.lines.last,
              startLine = multiline and anchor.lines.first or nil,
              startSide = multiline and anchor.side or nil,
            },
          })
          local t = thread(data.addPullRequestReviewThread.thread)
          return { comment = t.comments[#t.comments], thread = t }
        end
        local created = self:rest("POST", string.format("%s/pulls/%d/comments", repo_path(pr.repo), pr.number), {
          body = {
            body = new.body,
            commit_id = self:review_target(pr).head,
            path = anchor.path,
            side = anchor.side,
            line = anchor.lines.last,
            start_line = multiline and anchor.lines.first or nil,
            start_side = multiline and anchor.side or nil,
          },
        })
        return self:posted(pr, created.node_id)
      end

      if new.draft then
        error("Top-level comments can't be drafts; pass the text to submit instead", 0)
      end
      local data = self:query(documents.add_comment, { input = { subjectId = self:node_id(pr), body = new.body } })
      return { comment = comment(data.addComment.commentEdge.node, false) }
    end,
    cb
  )
end

---@class octo.forge.github.CommentKind
---@field update string
---@field input fun(id: string, body: string): table
---@field updated fun(data: any): octo.forge.Comment
---@field delete? string

---How to edit and delete each kind of comment, by node id prefix.
---@type table<string, octo.forge.github.CommentKind>
local comment_kinds = {
  PRRC = {
    update = documents.update_review_comment,
    input = function(id, body)
      return { pullRequestReviewCommentId = id, body = body }
    end,
    updated = function(data)
      return review_comment(data.updatePullRequestReviewComment.pullRequestReviewComment)
    end,
    delete = documents.delete_review_comment,
  },
  IC = {
    update = documents.update_issue_comment,
    input = function(id, body)
      return { id = id, body = body }
    end,
    updated = function(data)
      return comment(data.updateIssueComment.issueComment, false)
    end,
    delete = documents.delete_issue_comment,
  },
  PRR = {
    update = documents.update_review,
    input = function(id, body)
      return { pullRequestReviewId = id, body = body }
    end,
    updated = function(data)
      local review = data.updatePullRequestReview.pullRequestReview ---@type octo.forge.github.Comment
      return comment(review, review.state == "PENDING")
    end,
  },
}

---@param id string
---@return octo.forge.github.CommentKind
local function comment_kind(id)
  local kind = comment_kinds[id:match "^(%u+)_" or ""]
  if not kind then
    error("Not a comment id GitHub's adapter knows: " .. id, 0)
  end
  return kind
end

function GitHub:edit(_, comment_id, body, cb)
  async.run( ---@async
    function()
      local kind = comment_kind(comment_id)
      return kind.updated(self:query(kind.update, { input = kind.input(comment_id, body) }))
    end,
    cb
  )
end

function GitHub:delete(_, comment_id, cb)
  async.run( ---@async
    function()
      local kind = comment_kind(comment_id)
      if not kind.delete then
        error("This comment can't be deleted, only edited", 0)
      end
      self:query(kind.delete, { input = { id = comment_id } })
    end,
    cb
  )
end

function GitHub:react(_, comment_id, content, add, cb)
  async.run( ---@async
    function()
      local variables = { input = { subjectId = comment_id, content = content } }
      if add then
        return reactions(self:query(documents.add_reaction, variables).addReaction.reactionGroups)
      end
      return reactions(self:query(documents.remove_reaction, variables).removeReaction.reactionGroups)
    end,
    cb
  )
end

function GitHub:resolve(_, thread_id, resolved, cb)
  async.run( ---@async
    function()
      if resolved then
        return thread(
          self:query(documents.resolve_thread, { input = { threadId = thread_id } }).resolveReviewThread.thread
        )
      end
      return thread(
        self:query(documents.unresolve_thread, { input = { threadId = thread_id } }).unresolveReviewThread.thread
      )
    end,
    cb
  )
end

function GitHub:submit(pr, verdict, body, cb)
  async.run( ---@async
    function()
      local event = events[verdict]
      if not event then
        error("Unknown verdict: " .. tostring(verdict), 0)
      end
      if body and vim.trim(body) == "" then
        body = nil
      end
      local review_id = self:pending_review(pr, false)
      if review_id then
        self:query(documents.submit_review, { input = { pullRequestReviewId = review_id, event = event, body = body } })
      elseif verdict ~= "comment" or body then
        self:query(documents.add_review, { input = { pullRequestId = self:node_id(pr), event = event, body = body } })
      end
    end,
    cb
  )
end

function GitHub:discard(pr, cb)
  async.run( ---@async
    function()
      local review_id = self:pending_review(pr, false)
      if review_id then
        self:query(documents.delete_review, { input = { pullRequestReviewId = review_id } })
      end
    end,
    cb
  )
end

function GitHub:set_viewed(pr, path, viewed, cb)
  async.run( ---@async
    function()
      local input = { pullRequestId = self:node_id(pr), path = path }
      self:query(viewed and documents.mark_viewed or documents.unmark_viewed, { input = input })
    end,
    cb
  )
end

return M
