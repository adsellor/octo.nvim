local Layout = require("octo.reviews.layout").Layout
local Rev = require("octo.reviews.rev").Rev
local config = require "octo.config"
local thread_panel = require "octo.reviews.thread-panel"
local window = require "octo.ui.window"
local utils = require "octo.utils"

---@alias ReviewLevel "COMMIT" | "PR"

---A pull request opened for review. While browsing, threads can be read but not added to; once
---started, new comments are drafts in the viewer's pending review on the forge.
---@class Review
---@field started boolean
---@field threads table<string, octo.forge.Thread> threads that aren't outdated, by id
---@field layout Layout
---@field pull_request PullRequest
local Review = {}
Review.__index = Review

---Review constructor.
---@param pull_request PullRequest
---@return Review
function Review:new(pull_request)
  local this = {
    pull_request = pull_request,
    started = false,
    threads = {},
  }
  setmetatable(this, self)
  return this
end

---Read the pull request's threads from the forge.
---@param cb fun(threads: octo.forge.Thread[])
function Review:fetch_threads(cb)
  local pr = self.pull_request
  pr.forge:threads(pr.ref, function(err, threads)
    if err then
      return utils.error(err)
    end
    cb(threads --[[@as octo.forge.Thread[] ]])
  end)
end

---Re-read the threads and redraw what shows them.
---@param cb? fun()
function Review:refresh_threads(cb)
  self:fetch_threads(function(threads)
    self:update_threads(threads)
    if cb then
      cb()
    end
  end)
end

---@param threads octo.forge.Thread[]
---@return integer count the viewer's pending comments with something in them
local function count_pending_comments(threads)
  local count = 0
  for _, thread in ipairs(threads) do
    for _, comment in ipairs(thread.comments) do
      if comment.pending and not utils.is_blank(utils.trim(comment.body)) then
        count = count + 1
      end
    end
  end
  return count
end

---@param started boolean
---@param on_threads? fun(threads: octo.forge.Thread[]): boolean? return false to not open the review
function Review:open(started, on_threads)
  self:fetch_threads(function(threads)
    if on_threads and on_threads(threads) == false then
      return
    end
    self.started = started
    self:update_threads(threads)
    self:initiate()
  end)
end

function Review:browse()
  self:open(false)
end

-- Starts a new review. Nothing is created on the forge until the first draft comment.
function Review:start()
  if self.layout then
    -- already browsing this pull request: start reviewing in place
    self.started = true
    utils.info "Review started"
    self:refresh_threads()
    return
  end
  self:open(true)
end

-- Resumes the viewer's pending review
function Review:resume()
  self:open(true, function(threads)
    if count_pending_comments(threads) == 0 then
      utils.error "No pending reviews found for viewer"
      return false
    end
  end)
end

-- Resumes a pending review if there is one, else starts one
function Review:start_or_resume()
  self:open(true, function(threads)
    if count_pending_comments(threads) == 0 then
      utils.info "No pending review, starting one"
    else
      utils.info "Resuming review"
    end
  end)
end

---Register freshly fetched files as this review's files
---Selects and fetches the first unread files
---Defaults to the first file if all files are VIEWED
---@param files FileEntry[]
function Review:set_files_and_select_first(files)
  local selected_file_idx ---@type integer?
  for idx, file in ipairs(files) do
    if file.viewed_state ~= "VIEWED" then
      selected_file_idx = idx
      break
    end
  end

  if not selected_file_idx and #files > 0 then
    selected_file_idx = 1
  end

  self.layout.files = files
  if selected_file_idx then
    files[selected_file_idx]:fetch(true)
    self.layout.selected_file_idx = selected_file_idx
  end
  for _, file in ipairs(files) do
    file:fetch(false)
  end
  self.layout:update_files()
end

---Updates layout to focus on a single commit
---@param right string
---@param left string
function Review:focus_commit(right, left)
  local pr = self.pull_request
  self.layout:close()
  self.layout = Layout:new {
    right = Rev:new(right),
    left = Rev:new(left),
    files = {},
  }
  self.layout:open(self)
  local function cb(files)
    self:set_files_and_select_first(files)
  end
  if right == self.pull_request.right.commit and left == self.pull_request.left.commit then
    pr:get_changed_files(cb)
  else
    pr:get_commit_changed_files(self.layout.left, self.layout.right, cb)
  end
end

---Initiates (starts/resumes) a review
---@param opts? { left?: Rev, right?: Rev }
function Review:initiate(opts)
  opts = opts or {}
  local pr = self.pull_request
  local conf = config.values
  if conf.use_local_fs and not utils.in_pr_branch(pr) then
    local choice = vim.fn.confirm("Currently not in PR branch, would you like to checkout?", "&Yes\n&No", 2)
    if choice == 1 then
      utils.checkout_pr_sync { repo = pr.repo, pr_number = pr.number }
    end
  end

  -- create the layout
  self.layout = Layout:new {
    left = opts.left or pr.left,
    right = opts.right or pr.right,
    files = {},
  }
  self.layout:open(self)

  pr:get_changed_files(function(files)
    self:set_files_and_select_first(files)
  end)
end

---Discard the viewer's pending comments and close the review
---@param opts? { skip_confirm?: boolean } Options for discarding the review
function Review:discard(opts)
  opts = opts or {}
  local pr = self.pull_request
  self:fetch_threads(function(threads)
    local pending_count = count_pending_comments(threads)
    if pending_count > 0 and not opts.skip_confirm then
      local message = string.format(
        "%d pending comment%s will be deleted, are you sure?",
        pending_count,
        pending_count == 1 and "" or "s"
      )
      if vim.fn.confirm(message, "&Yes\n&No\n&Cancel", 2) ~= 1 then
        return
      end
    end
    pr.forge:discard(pr.ref, function(err)
      if err then
        return utils.error(err)
      end
      self.started = false
      self.threads = {}
      utils.info "Pending review discarded"
      vim.cmd [[tabclose]]
    end)
  end)
end

---Redraw the file panel and the current file's signs after threads changed.
function Review:redraw_threads()
  if self.layout then
    self.layout.file_panel:render()
    self.layout.file_panel:redraw()
    local file = self.layout:get_current_file()
    if file then
      file:place_signs()
    end
  end
end

---@param threads octo.forge.Thread[]
function Review:update_threads(threads)
  self.threads = {}
  for _, thread in ipairs(threads) do
    if not thread.outdated then
      self.threads[thread.id] = thread
    end
  end
  self:redraw_threads()
end

---Take in one thread the forge just returned.
---@param thread octo.forge.Thread
function Review:update_thread(thread)
  if not thread.outdated then
    self.threads[thread.id] = thread
  end
  self:redraw_threads()
end

---Take in one comment the forge just returned.
---@param comment octo.forge.Comment
function Review:update_comment(comment)
  for _, thread in pairs(self.threads) do
    for i, c in ipairs(thread.comments) do
      if c.id == comment.id then
        thread.comments[i] = comment
      end
    end
  end
  self:redraw_threads()
end

function Review:collect_submit_info()
  if not self.started then
    utils.error "No review in progress"
    return
  end

  local conf = config.values
  local winid, bufnr = window.create_centered_float {
    header = string.format(
      "Press %s to approve, %s to comment or %s to request changes",
      conf.mappings.submit_win.approve_review.lhs,
      conf.mappings.submit_win.comment_review.lhs,
      conf.mappings.submit_win.request_changes.lhs
    ),
  }
  vim.api.nvim_set_current_win(winid)
  vim.bo[bufnr].syntax = "octo"
  utils.apply_mappings("submit_win", bufnr)
  vim.cmd [[normal G]]
end

local verdicts = { APPROVE = "approve", COMMENT = "comment", REQUEST_CHANGES = "request_changes" }

---@param event "APPROVE" | "COMMENT" | "REQUEST_CHANGES"
function Review:submit(event)
  if not self.started then
    utils.error "No review in progress"
    return
  end
  local pr = self.pull_request
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local body = utils.trim(table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"))
  pr.forge:submit(pr.ref, verdicts[event], body, function(err)
    if err then
      return utils.error(err)
    end
    utils.info "Review was submitted successfully!"
    pcall(vim.api.nvim_win_close, winid, false)
    self.layout:close()
  end)
end

---@return octo.forge.Thread[]
function Review:pending_threads()
  local pending = {} ---@type octo.forge.Thread[]
  for _, thread in pairs(self.threads) do
    for _, comment in ipairs(thread.comments) do
      if comment.pending and not utils.is_blank(utils.trim(comment.body)) then
        table.insert(pending, thread)
        break
      end
    end
  end
  return pending
end

function Review:show_pending_comments()
  local pending_threads = self:pending_threads()
  if #pending_threads == 0 then
    utils.error "No pending comments found"
    return
  else
    require("octo.picker").pending_threads(pending_threads)
  end
end

---@param isSuggestion boolean
function Review:add_comment(isSuggestion)
  -- check if we are on the diff layout and return early if not
  local bufnr = vim.api.nvim_get_current_buf()
  local split, path = utils.get_split_and_path(bufnr)
  if not split or not path then
    return
  end

  local file = self.layout:get_current_file()
  if not file then
    return
  end

  -- get visual selected line range, used if coming from a keymap where current
  -- mode can be evaluated.
  local line1, line2 = utils.get_lines_from_context "visual"
  -- if we came from the command line the command options will provide line
  -- range
  if OctoLastCmdOpts ~= nil then
    line1 = OctoLastCmdOpts.line1
    line2 = OctoLastCmdOpts.line2
  end
  if not line1 or not line2 then
    return
  end

  local current_bufnr = split == "RIGHT" and file.right_bufid or split == "LEFT" and file.left_bufid or nil
  if not current_bufnr then
    utils.error "Failed to create comment"
    return
  end

  local diff_hunk = file:hunk_at(split, line1, line2)
  if not diff_hunk then
    utils.error "Cannot place comments outside diff hunks"
    return
  end

  local forge = self.pull_request.forge
  if self:get_level() == "COMMIT" and not forge:supports "commit_comments" then
    utils.error "This forge can't comment on a single commit; review the whole pull request to comment"
    return
  end

  self.layout:ensure_layout()

  local alt_win = file:get_alternative_win(split)
  if vim.api.nvim_win_is_valid(alt_win) then
    local pr = file.pull_request
    ---@type octo.forge.LineRange
    local lines = { first = line1, last = line2 }

    -- Make sure review thread panel is visible if not already
    -- The thread panel could be hidden if user has `reviews.auto_show_threads` set to false in their config
    -- or, less likely, if the add comment command is invoked before the autocmd has concluded,
    thread_panel.show_review_threads(false)
    local thread_buffer = thread_panel.create_thread_buffer(pr.repo, pr.number, split, file.path, line1, function(bufnr)
      require("octo.reviews.thread-buffer").write_new(bufnr, {
        path = file.path,
        side = split --[[@as octo.forge.Side]],
        lines = lines,
        commit = split == "LEFT" and self.layout.left.commit or self.layout.right.commit,
        diff_hunk = diff_hunk,
      })
    end)
    if thread_buffer then
      table.insert(file.associated_bufs, thread_buffer.bufnr)
      vim.api.nvim_win_set_buf(alt_win, thread_buffer.bufnr)
      vim.api.nvim_set_current_win(alt_win)
      if isSuggestion then
        local code = vim.api.nvim_buf_get_lines(current_bufnr, line1 - 1, line2 --[[@as integer]], false)
        local suggestion = { "```suggestion" }
        vim.list_extend(suggestion, code)
        table.insert(suggestion, "```")
        vim.api.nvim_buf_set_lines(thread_buffer.bufnr, -3, -2, false, suggestion)
        vim.bo[thread_buffer.bufnr].modified = false
      end
      thread_buffer:configure()
      vim.cmd [[diffoff!]]
      vim.cmd [[normal! vvGk]]
      vim.cmd [[startinsert]]

      vim.keymap.set("n", "q", function()
        thread_panel.hide_thread_buffer(split, file)
        local file_win = file:get_win(split)
        if vim.api.nvim_win_is_valid(file_win) then
          vim.api.nvim_set_current_win(file_win)
        end
      end, { buffer = thread_buffer.bufnr })
    end
  else
    utils.error("Cannot find diff window " .. alt_win)
  end
end

---Get the review level, aka whether the review is at commit or PR level
---@return ReviewLevel
function Review:get_level()
  if
    self.layout.left.commit == self.pull_request.left.commit
    and self.layout.right.commit == self.pull_request.right.commit
  then
    return "PR"
  end
  return "COMMIT"
end

local M = {}

---@type table<string, Review>
M.reviews = {}

M.Review = Review

---@param isSuggestion boolean
function M.add_review_comment(isSuggestion)
  local review = M.get_current_review()

  if not review then
    error "Could not find review"
  end

  -- we maybe in browse mode, where no review has been started.
  if not review.started then
    utils.error "Please start or resume a review first"
    return
  end

  review:add_comment(isSuggestion)
end

---@param thread octo.forge.Thread
function M.jump_to_pending_review_thread(thread)
  local current_review = M.get_current_review()
  if not current_review then
    return
  end
  for _, file in ipairs(current_review.layout.files) do
    if thread.path == file.path then
      current_review.layout:ensure_layout()
      current_review.layout:set_current_file(file)
      local win = file:get_win(thread.side:lower() --[[@as OctoSplit]])
      if vim.api.nvim_win_is_valid(win) then
        local review_level = current_review:get_level()
        -- jumping to the original position in case we are reviewing any commit
        -- jumping to the PR position if we are reviewing the last commit
        -- This may result in a jump to the wrong line when the review is neither in the last commit or the original one
        local lines = review_level == "COMMIT" and thread.original_lines or thread.lines or thread.original_lines
        local line = lines and lines.first or 1
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { line, 0 })
      else
        utils.error "Cannot find diff window"
      end
      break
    end
  end
end

--- Get the current review according to the tab page
--- @return Review | nil
function M.get_current_review()
  local current_tabpage = vim.api.nvim_get_current_tabpage()
  return M.reviews[tostring(current_tabpage)]
end

--- Get the diff Layout of the review if any
--- @return Layout | nil
function M.get_current_layout()
  local current_review = M.get_current_review()
  if current_review then
    return M.get_current_review().layout
  end
end

function M.on_tab_enter()
  local current_review = M.get_current_review()
  if current_review and current_review.layout then
    current_review.layout:on_enter()
  end
end

function M.on_tab_leave()
  local current_review = M.get_current_review()
  if current_review and current_review.layout then
    current_review.layout:on_leave()
  end
end

function M.on_win_leave()
  local current_review = M.get_current_review()
  if current_review and current_review.layout then
    current_review.layout:on_win_leave()
  end
end

function M.close(tabpage)
  if tabpage then
    local review = M.reviews[tostring(tabpage)]
    if review and review.layout then
      review.layout:close()
    end
    M.reviews[tostring(tabpage)] = nil
  end
end

--- Get the pull request associated with current buffer.
--- Fall back to pull request associated with the current branch if not in an Octo buffer.
--- @param cb fun(pull_request: PullRequest?): nil
local function get_pr_from_buffer_or_current_branch(cb)
  local buffer = utils.get_current_buffer()

  if not buffer then
    -- We are not in an octo buffer, try and fallback to the current branch's pr
    utils.get_pull_request_for_current_branch(cb)
    return
  end

  if buffer:isPullRequest() then
    buffer:get_pr(cb)
  else
    utils.get_pull_request_for_current_branch(cb)
  end
end

function M.browse_review()
  local current_review = M.get_current_review()

  if current_review and current_review.started then
    utils.error "Cannot browse when a review has been started"
    return
  end

  get_pr_from_buffer_or_current_branch(function(pull_request)
    current_review = Review:new(pull_request)
    current_review:browse()
  end)
end

function M.start_review()
  -- its possible we are already browsing a review with 'Octo review browse'
  local current_review = M.get_current_review()
  if current_review then
    current_review:start()
    return
  end

  get_pr_from_buffer_or_current_branch(function(pull_request)
    current_review = Review:new(pull_request)
    current_review:start()
  end)
end

function M.resume_review()
  get_pr_from_buffer_or_current_branch(function(pull_request)
    local current_review = Review:new(pull_request)
    current_review:resume()
  end)
end

function M.start_or_resume_review()
  get_pr_from_buffer_or_current_branch(function(pull_request)
    local current_review = Review:new(pull_request)
    current_review:start_or_resume()
  end)
end

---Start or resume a review of a pull request picked by number; it needn't be checked out.
---@param ref octo.forge.PullRequestRef
function M.review_pull_request(ref)
  local PullRequest = require "octo.model.pull-request"
  local name_with_owner = ref.repo.owner .. "/" .. ref.repo.name
  PullRequest.load({ repo = name_with_owner, number = ref.number, hostname = ref.repo.host }, function(pull_request)
    Review:new(pull_request):start_or_resume()
  end)
end

function M.discard_review()
  local current_review = M.get_current_review()
  if current_review and current_review.started then
    current_review:discard()
  else
    utils.error "Please start or resume a review first"
  end
end

function M.submit_review()
  local current_review = M.get_current_review()
  if current_review and current_review.started then
    current_review:collect_submit_info()
  else
    utils.error "Please start or resume a review first"
  end
end

return M
