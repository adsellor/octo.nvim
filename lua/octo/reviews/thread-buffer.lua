---The review thread buffer: forge threads written out for reading and replying, and every write a
---reviewer makes from it (reply, new thread, edit, delete, resolve, react) sent to the review's forge.
---
---In these buffers comment metadata means: `id` is the forge comment id (-1 until a new comment is
---saved), `replyTo` the forge id of the thread a reply goes to, and `path`, `diffSide`,
---`snippetStartLine` and `snippetEndLine` the anchor of a new thread. Thread metadata's `threadId`
---and `replyTo` are both the forge thread id (-1 for a thread not saved yet).

local ThreadMetadata = require("octo.model.thread-metadata").ThreadMetadata
local constants = require "octo.constants"
local folds = require "octo.folds"
local utils = require "octo.utils"
local writers = require "octo.ui.writers"

local M = {}

local reaction_contents = { "THUMBS_UP", "THUMBS_DOWN", "LAUGH", "HOORAY", "CONFUSED", "HEART", "ROCKET", "EYES" }

---The reaction groups the renderer and the reaction command read: every reaction, zero or not.
---@param reactions? octo.forge.Reaction[]
---@return { content: string, users: { totalCount: integer }, viewerHasReacted: boolean }[]
function M.reaction_groups(reactions)
  local by_content = {} ---@type table<string, octo.forge.Reaction>
  for _, reaction in ipairs(reactions or {}) do
    by_content[reaction.content] = reaction
  end
  return vim.tbl_map(function(content) ---@param content string
    local reaction = by_content[content]
    return {
      content = content,
      users = { totalCount = reaction and reaction.count or 0 },
      viewerHasReacted = reaction ~= nil and reaction.viewer_reacted,
    }
  end, reaction_contents)
end

---The lines a thread is shown at in the thread buffer: where it was written.
---@param thread octo.forge.Thread
---@return octo.forge.LineRange
local function shown_lines(thread)
  return thread.original_lines or thread.lines or { first = 1, last = 1 }
end

---@param path string
---@return string?
local function snippet_language(path)
  -- filetype detection needs a buffer sometimes: https://github.com/neovim/neovim/issues/27265
  local scratch = vim.api.nvim_create_buf(false, true)
  local filetype = vim.filetype.match { filename = path, buf = scratch }
  vim.api.nvim_buf_delete(scratch, { force = true })
  return filetype and vim.treesitter.language.get_lang(filetype)
end

---What `writers.write_comment` reads for a review comment, and what it keeps as comment metadata.
---@param comment octo.forge.Comment
---@param placement { path: string, side: octo.forge.Side, lines: octo.forge.LineRange, reply_to?: string }
local function renderable(comment, placement)
  return {
    id = comment.id,
    author = { login = comment.author.login },
    body = comment.body,
    createdAt = comment.created_at,
    lastEditedAt = comment.edited_at,
    state = comment.pending and "PENDING" or "SUBMITTED",
    viewerDidAuthor = comment.viewer_is_author,
    viewerCanUpdate = comment.viewer_can_edit,
    viewerCanDelete = comment.viewer_can_delete,
    reactionGroups = M.reaction_groups(comment.reactions),
    replyTo = placement.reply_to,
    path = placement.path,
    diffSide = placement.side,
    start_line = placement.lines.first,
    end_line = placement.lines.last,
  }
end

---@param bufnr integer
---@param opts { id: string|-1, path: string, side: octo.forge.Side, lines: octo.forge.LineRange, outdated: boolean, resolved: boolean, resolved_by?: octo.forge.User, commit?: string, diff_hunk?: string, comments: table[] }
---@return integer comment_end
local function write_thread(bufnr, opts)
  writers.write_review_thread_header(bufnr, {
    path = opts.path,
    start_line = opts.lines.first,
    end_line = opts.lines.last,
    isOutdated = opts.outdated,
    isResolved = opts.resolved,
    resolvedBy = opts.resolved_by,
    commit = opts.commit and opts.commit:sub(1, 7),
  })
  writers.write_block(bufnr, { "" })
  local thread_start, thread_end = writers.write_thread_snippet(
    bufnr,
    opts.diff_hunk,
    snippet_language(opts.path),
    nil,
    opts.lines.first,
    opts.lines.last,
    opts.side
  )
  local comment_end = thread_end
  for _, comment in ipairs(opts.comments) do
    local comment_start ---@type integer
    comment_start, comment_end = writers.write_comment(bufnr, comment, "PullRequestReviewComment")
    folds.create(bufnr, comment_start + 1, comment_end, true)
  end
  folds.create(bufnr, thread_start - 1, comment_end - 1, true)

  local mark = vim.api.nvim_buf_set_extmark(bufnr, constants.OCTO_THREAD_NS, thread_start - 1, 0, {
    end_line = comment_end,
    end_col = 0,
  })
  octo_buffers[bufnr].threadsMetadata[tostring(mark)] = ThreadMetadata:new {
    threadId = opts.id,
    replyTo = opts.id,
    path = opts.path,
    line = opts.lines.first,
  }
  return comment_end
end

---Write threads at the end of an OctoBuffer.
---@param bufnr integer
---@param threads octo.forge.Thread[]
function M.write(bufnr, threads)
  for _, thread in ipairs(threads) do
    local lines = shown_lines(thread)
    write_thread(bufnr, {
      id = thread.id,
      path = thread.path,
      side = thread.side,
      lines = lines,
      outdated = thread.outdated,
      resolved = thread.resolved,
      resolved_by = thread.resolved_by,
      commit = thread.original_commit,
      diff_hunk = thread.diff_hunk,
      comments = vim.tbl_map(function(comment) ---@param comment octo.forge.Comment
        return renderable(comment, { path = thread.path, side = thread.side, lines = lines, reply_to = thread.id })
      end, thread.comments),
    })
  end
end

---Write a thread that isn't saved yet: its header and snippet, and an empty comment to type into.
---@param bufnr integer
---@param anchor { path: string, side: octo.forge.Side, lines: octo.forge.LineRange, commit?: string, diff_hunk: string }
function M.write_new(bufnr, anchor)
  local comment = renderable({
    id = "",
    author = { login = vim.g.octo_viewer or "you" },
    body = " ",
    created_at = os.date "!%Y-%m-%dT%H:%M:%SZ" --[[@as string]],
    pending = true,
    viewer_is_author = true,
    viewer_can_edit = true,
    viewer_can_delete = true,
  }, anchor)
  comment.id = -1
  write_thread(bufnr, {
    id = -1,
    path = anchor.path,
    side = anchor.side,
    lines = anchor.lines,
    outdated = false,
    resolved = false,
    commit = anchor.commit,
    diff_hunk = anchor.diff_hunk,
    comments = { comment },
  })
end

---@return Review?
local function current_review()
  local review = require("octo.reviews").get_current_review()
  if not review then
    utils.error "No review in progress"
  end
  return review
end

---Point a thread's extmark past its new last comment.
---@param buffer OctoBuffer
---@param thread_id string
---@param comment_end integer
local function extend_thread_mark(buffer, thread_id, comment_end)
  for mark_id, thread in pairs(buffer.threadsMetadata) do
    if thread.threadId == thread_id then
      local id = tonumber(mark_id) --[[@as integer]]
      local mark = vim.api.nvim_buf_get_extmark_by_id(buffer.bufnr, constants.OCTO_THREAD_NS, id, {})
      vim.api.nvim_buf_del_extmark(buffer.bufnr, constants.OCTO_THREAD_NS, id)
      local new_id = vim.api.nvim_buf_set_extmark(buffer.bufnr, constants.OCTO_THREAD_NS, mark[1], 0, {
        end_line = comment_end + 2,
        end_col = 0,
      })
      buffer.threadsMetadata[tostring(new_id)] = thread
      buffer.threadsMetadata[mark_id] = nil
      return
    end
  end
end

---Send every new or changed comment in the buffer to the forge.
---@param buffer OctoBuffer
function M.save(buffer)
  local review = current_review()
  if not review then
    return
  end
  local pr = review.pull_request
  buffer:update_metadata()

  for _, metadata in ipairs(buffer.commentsMetadata) do
    if metadata.body ~= metadata.savedBody then
      local body = metadata.body
      local function saved(comment_id)
        metadata.id = comment_id
        metadata.savedBody = body
        metadata.dirty = false
        buffer:render_signs()
      end

      if metadata.id ~= -1 then
        pr.forge:edit(pr.ref, metadata.id, body, function(err, comment)
          if err then
            return utils.error(err)
          end
          saved(metadata.id)
          review:update_comment(comment --[[@as octo.forge.Comment]])
        end)
      else
        ---@type octo.forge.NewComment
        local new = { body = body, draft = review.started and pr.forge:supports "draft" }
        if not utils.is_blank(metadata.replyTo) then
          new.reply_to = metadata.replyTo --[[@as string]]
        else
          new.anchor = {
            path = metadata.path,
            side = metadata.diffSide --[[@as octo.forge.Side]],
            lines = { first = metadata.snippetStartLine, last = metadata.snippetEndLine },
            commit = review:get_level() == "COMMIT" and review.layout.right.commit or nil,
          }
        end
        pr.forge:comment(pr.ref, new, function(err, posted)
          if err or not posted then
            return utils.error(err or "Failed to post the comment")
          end
          local thread = posted.thread --[[@as octo.forge.Thread]]
          if new.reply_to then
            extend_thread_mark(buffer, thread.id, metadata.endLine)
          else
            for _, thread_metadata in pairs(buffer.threadsMetadata) do
              if thread_metadata.threadId == -1 then
                thread_metadata.threadId = thread.id
                thread_metadata.replyTo = thread.id
              end
            end
          end
          saved(posted.comment.id)
          review:update_thread(thread)
        end)
      end
    end
  end

  vim.bo[buffer.bufnr].modified = false
end

---Delete a comment, then close the buffer if that emptied its thread.
---@param buffer OctoBuffer
---@param comment CommentMetadata
---@param thread_id string
---@param removed fun() takes the comment out of the buffer
function M.delete(buffer, comment, thread_id, removed)
  local review = current_review()
  if not review then
    return
  end
  local pr = review.pull_request
  pr.forge:delete(pr.ref, comment.id, function(err)
    if err then
      return utils.error(err)
    end
    removed()
    review:refresh_threads(function()
      if review.threads[thread_id] then
        return
      end
      -- that was the thread's last comment: put the diff back where the thread buffer was
      local split = vim.api.nvim_buf_get_name(buffer.bufnr):match "octo://.+/review/[^/]+/threads/([^/]+)/.*"
      local file = review.layout:get_current_file()
      if split and file then
        vim.api.nvim_win_set_buf(file:get_alternative_win(split), file:get_alternative_buf(split))
        pcall(vim.api.nvim_buf_delete, buffer.bufnr, { force = true })
        file:place_signs()
        file:show_diff()
      end
    end)
  end)
end

---Resolve or reopen the thread under the cursor and redraw its header.
---@param buffer OctoBuffer
---@param thread ThreadMetadata
---@param resolved boolean
function M.resolve(buffer, thread, resolved)
  local review = current_review()
  if not review then
    return
  end
  local pr = review.pull_request
  if not pr.forge:supports "resolve" then
    return utils.error "This forge can't resolve threads"
  end
  local header_line = thread.bufferStartLine - 2
  pr.forge:resolve(pr.ref, thread.threadId, resolved, function(err, updated)
    if err or not updated then
      return utils.error(err or "Failed to update the thread")
    end
    local lines = shown_lines(updated)
    writers.write_review_thread_header(buffer.bufnr, {
      path = updated.path,
      start_line = lines.first,
      end_line = lines.last,
      isOutdated = updated.outdated,
      isResolved = updated.resolved,
      resolvedBy = updated.resolved_by,
      commit = updated.original_commit and updated.original_commit:sub(1, 7),
    }, header_line)
    review:update_thread(updated)
  end)
end

---Add or remove the viewer's reaction to a comment.
---@param comment_id string
---@param content string
---@param add boolean
---@param cb fun(reaction_groups: table[])
function M.react(comment_id, content, add, cb)
  local review = current_review()
  if not review then
    return
  end
  local pr = review.pull_request
  if not pr.forge:supports "reactions" then
    return utils.error "This forge has no reactions"
  end
  pr.forge:react(pr.ref, comment_id, content --[[@as octo.forge.ReactionContent]], add, function(err, reactions)
    if err then
      return utils.error(err)
    end
    cb(M.reaction_groups(reactions))
  end)
end

return M
