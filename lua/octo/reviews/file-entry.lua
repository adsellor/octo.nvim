-- Heavily derived from `diffview.nvim`:
-- https://github.com/sindrets/diffview.nvim/blob/main/lua/diffview/file-entry.lua

local config = require "octo.config"
local constants = require "octo.constants"
local signs = require "octo.ui.signs"
local utils = require "octo.utils"
local vim = vim

local M = {}

---@type table<string, integer>
M._null_buffer = {}

---@class GitStats
---@field additions integer
---@field deletions integer
---@field changes integer

---@class FileEntry
---@field path string
---@field previous_path string
---@field basename string
---@field extension? string
---@field pull_request PullRequest
---@field status string
---@field patch string
---@field stats GitStats
---@field left_binary boolean|nil
---@field right_binary boolean|nil
---@field left_bufid? integer
---@field right_bufid? integer
---@field left_lines string[]
---@field right_lines string[]
--- If either left_fetched or right_fetched is false,
--- the buffer is not ready to be displayed.
---@field left_fetched boolean
---@field right_fetched boolean
---@field left_winid? integer
---@field right_winid? integer
---@field left_comment_ranges? [integer, integer][]
---@field right_comment_ranges? [integer, integer][]
---@field left_fetching boolean
---@field right_fetching boolean
---@field associated_bufs integer[]
---@field diffhunks? string[]
---@field viewed_state octo.FileViewedState
local FileEntry = {}
FileEntry.__index = FileEntry

FileEntry.winopts = {
  foldmethod = "diff",
  foldlevel = 0,
  cursorlineopt = "number", -- disable cursorline due to Neovim bug https://github.com/neovim/neovim/issues/9800
}

---FileEntry constructor
---@param opt {
---  path: string,
---  previous_path: string,
---  patch: string,
---  pull_request: PullRequest,
---  status: string,
---  stats: { additions: integer, deletions: integer, changes: integer },
---  left_binary: boolean,
---  right_binary: boolean,
---  left_lines: string[],
---  right_lines: string[],
---  left_fetched: boolean,
---  right_fetched: boolean,
---  left_winid: integer,
---  right_winid: integer,
---  left_comment_ranges: [integer, integer][],
---  right_comment_ranges: [integer, integer][],
---  associated_bufs: integer[],
---  diffhunks: string[],
---  viewed_state: string,
---}
---@return FileEntry
function FileEntry:new(opt)
  local pr = opt.pull_request
  ---@type string[]?, [integer, integer][]?, [integer, integer][]?
  local diffhunks, left_ranges, right_ranges
  if opt.patch then
    diffhunks, left_ranges, right_ranges = utils.process_patch(opt.patch)
  end

  ---@type FileEntry
  local this = {
    path = opt.path,
    previous_path = opt.previous_path,
    patch = opt.patch,
    basename = utils.path_basename(opt.path),
    extension = utils.path_extension(opt.path),
    pull_request = pr,
    status = opt.status,
    stats = opt.stats,
    left_comment_ranges = left_ranges,
    right_comment_ranges = right_ranges,
    left_binary = opt.left_binary,
    right_binary = opt.right_binary,
    left_lines = {},
    right_lines = {},
    left_fetched = false,
    right_fetched = false,
    left_fetching = false,
    right_fetching = false,
    diffhunks = diffhunks,
    associated_bufs = {},
    viewed_state = pr.files[opt.path],
  }
  if not this.status then
    this.status = " "
  end

  setmetatable(this, self)

  return this
end

---FileEntry toggle_viewed
function FileEntry:toggle_viewed()
  local pr = self.pull_request
  if not pr.forge:supports "viewed" then
    utils.error "This forge doesn't track viewed files"
    return
  end
  local viewed = self.viewed_state ~= "VIEWED"
  pr.forge:set_viewed(pr.ref, self.path, viewed, function(err)
    if err then
      return utils.print_err(err)
    end
    self.viewed_state = viewed and "VIEWED" or "UNVIEWED"
    local current_review = require("octo.reviews").get_current_review()
    if current_review then
      current_review.layout.file_panel:render()
      current_review.layout.file_panel:redraw()
    end
  end)
end

---FileEntry finalizer
function FileEntry:destroy()
  self:detach_buffers()

  for _, bn in ipairs(self.associated_bufs) do
    if vim.api.nvim_buf_is_valid(bn) then
      if vim.api.nvim_buf_get_name(bn):match "octo://*" then
        pcall(vim.api.nvim_buf_delete, bn, { force = true })
      else
        signs.unplace(bn)
        vim.bo[bn].modifiable = true
        vim.api.nvim_buf_clear_namespace(bn, constants.OCTO_REVIEW_COMMENTS_NS, 0, -1)
      end
    end
  end
end

---Get the window id for the alternative side of the provided buffer
---@param split OctoSplit
---@return integer
function FileEntry:get_alternative_win(split)
  if split:lower() == "left" then
    return self.right_winid
  end

  return self.left_winid
end

---Get the buffer id for the alternative side of the provided buffer
---@param split OctoSplit
---@return integer
function FileEntry:get_alternative_buf(split)
  if split:lower() == "left" then
    return self.right_bufid
  end

  return self.left_bufid
end

---Get the window id for the side of the provided buffer
---@param split OctoSplit
---@return integer
function FileEntry:get_win(split)
  if split:lower() == "left" then
    return self.left_winid
  end

  return self.right_winid
end

---Get the buffer id for the side of the provided buffer
---@param split OctoSplit
---@return integer
function FileEntry:get_buf(split)
  if split:lower() == "left" then
    return self.left_bufid
  end

  return self.right_bufid
end

---Fetch file content locally or from the forge.
---@param sync boolean
function FileEntry:fetch(sync)
  local right_path = self.path
  local left_path = self.path
  local current_review = require("octo.reviews").get_current_review()
  if not current_review then
    return
  end
  local conf = config.values
  if self.left_fetching or self.right_fetching then
    if sync then
      vim.wait(conf.timeout, function()
        return self:is_ready_to_render()
      end)
    end
    return
  end
  self.left_fetching = true
  self.right_fetching = true
  local right_sha = current_review.layout.right.commit
  local left_sha = current_review.layout.left.commit

  -- handle renamed files
  if self.status == "R" and self.previous_path then
    left_path = self.previous_path
  end

  local pr = self.pull_request
  ---@param is_local boolean
  ---@param path string
  ---@param sha string
  ---@param done fun(lines: string[])
  local function read(is_local, path, sha, done)
    if is_local then
      return utils.get_file_at_commit(path, sha, done)
    end
    pr.forge:contents(pr.ref, sha, path, function(err, text)
      if err then
        utils.error(err)
      end
      local lines = vim.split(text or "", "\n")
      -- a final newline ends the last line; git doesn't count an empty one after it
      if lines[#lines] == "" then
        table.remove(lines)
      end
      done(lines)
    end)
  end

  read(pr.local_right, right_path, right_sha, function(lines)
    self.right_lines = lines
    self.right_fetched = true
    self.right_fetching = false
  end)
  read(pr.local_left, left_path, left_sha, function(lines)
    self.left_lines = lines
    self.left_fetched = true
    self.left_fetching = false
  end)

  -- wait until we have both versions
  if sync then
    vim.wait(conf.timeout, function()
      return self:is_ready_to_render()
    end)
  end
end

---Determines whether the file content has been loaded and the file is ready to render
---@return boolean
function FileEntry:is_ready_to_render()
  return self.left_fetched and self.right_fetched
end

---Load the buffers.
---@param left_winid integer
---@param right_winid integer
function FileEntry:load_buffers(left_winid, right_winid)
  local current_review = require("octo.reviews").get_current_review()
  local empty_files = #self.left_lines == 0 and #self.right_lines == 0
  local splits = {
    {
      winid = left_winid,
      bufid = self.left_bufid,
      lines = self.left_lines,
      pos = "left",
      binary = self.left_binary == true or empty_files,
    },
    {
      winid = right_winid,
      bufid = self.right_bufid,
      lines = self.right_lines,
      pos = "right",
      binary = self.right_binary == true or empty_files,
    },
  }

  -- configure diff buffers
  for _, split in ipairs(splits) do
    if not split.bufid or not vim.api.nvim_buf_is_loaded(split.bufid) then
      local conf = config.values
      local use_local = conf.use_local_fs and split.pos == "right" and utils.in_pr_branch(self.pull_request)

      -- create buffer
      split.bufid = M._create_buffer {
        commit = current_review and current_review.layout[split.pos].commit,
        status = self.status,
        show_diff = self.patch ~= nil,
        path = self.path,
        split = split.pos,
        binary = split.binary,
        lines = split.lines,
        repo = self.pull_request.repo,
        use_local = use_local,
      }

      -- register new buffer
      table.insert(self.associated_bufs, split.bufid)
      ---@diagnostic disable-next-line: no-unknown
      self[split.pos .. "_bufid"] = split.bufid
      ---@diagnostic disable-next-line: no-unknown
      self[split.pos .. "_winid"] = split.winid
    end

    M._configure_buffer(split.bufid)
    vim.api.nvim_win_set_buf(split.winid, split.bufid)
  end

  -- Set this to disable LSPs from attempting to attach to this buffer
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = self.left_bufid })

  -- show thread signs and virtual text
  self:place_signs()

  -- configure windows
  M._configure_windows(left_winid, right_winid)

  self:show_diff()
end

-- activate the diff between right and left panels
function FileEntry:show_diff()
  for _, bufid in ipairs { self.left_bufid, self.right_bufid } do
    vim.api.nvim_buf_call(bufid, function()
      -- Only trigger ft detect event for non local files to avoid triggering ftplugins for nothing
      if vim.fn.bufname(bufid):match "octo://*" then
        pcall(vim.cmd.filetype, [[detect]])
      end
      pcall(vim.cmd.doau, [[BufEnter]])
      pcall(vim.cmd.diffthis)
      -- Scroll to trigger the scrollbind and sync the windows. This works more
      -- consistently than calling `:syncbind`.
      pcall(vim.cmd.exec, [["normal! \<c-y>"]])
    end)
  end
end

function FileEntry:attach_buffers()
  if self.left_bufid then
    M._configure_buffer(self.left_bufid)
  end
  if self.right_bufid then
    M._configure_buffer(self.right_bufid)
  end
end

function FileEntry:detach_buffers()
  if self.left_bufid then
    M._detach_buffer(self.left_bufid)
  end
  if self.right_bufid then
    M._detach_buffer(self.right_bufid)
  end
end

---Compare against another FileEntry.
---@param other FileEntry
---@return boolean
function FileEntry:compare(other)
  if self.stats and not other.stats then
    return false
  end
  if not self.stats and other.stats then
    return false
  end
  if self.stats and other.stats then
    if self.stats.additions ~= other.stats.additions or self.stats.deletions ~= other.stats.deletions then
      return false
    end
  end

  return (self.path == other.path and self.status == other.status)
end

---Update thread signs in diff buffers.
---The diff hunk that holds lines `first` to `last` on `split`, starting with its "@@" header.
---@param split string "LEFT" or "RIGHT"
---@param first integer
---@param last integer
---@return string?
function FileEntry:hunk_at(split, first, last)
  local ranges = split == "RIGHT" and self.right_comment_ranges or split == "LEFT" and self.left_comment_ranges or nil
  for i, range in ipairs(ranges or {}) do
    if range[1] <= first and range[2] >= last then
      local hunk = self.diffhunks[i]
      return vim.startswith(hunk, "@@") and hunk or "@@ " .. hunk
    end
  end
end

function FileEntry:place_signs()
  self:_place_signs_with_virtual_text(config.values.reviews.show_virtual_text)
end

function FileEntry:_place_signs_with_virtual_text(show_virtual_text)
  local current_review = require("octo.reviews").get_current_review()
  if not current_review then
    return
  end
  local review_level = current_review:get_level()
  local splits = {
    {
      bufnr = self.left_bufid,
      comment_ranges = self.left_comment_ranges,
      commit = current_review.layout.left:abbrev(),
    },
    {
      bufnr = self.right_bufid,
      comment_ranges = self.right_comment_ranges,
      commit = current_review.layout.right:abbrev(),
    },
  }
  for _, split in ipairs(splits) do
    signs.unplace(split.bufnr)
    vim.api.nvim_buf_clear_namespace(split.bufnr, constants.OCTO_REVIEW_COMMENTS_NS, 0, -1)

    -- place comment range signs
    if split.comment_ranges then
      for _, range in ipairs(split.comment_ranges) do
        for line = range[1], range[2] do
          signs.place("octo_comment_range", split.bufnr, line - 1)
        end
      end
    end

    -- place thread comments signs and virtual text
    for _, thread in pairs(current_review.threads) do
      local lines = thread.lines or thread.original_lines or { first = 1, last = 1 }
      local startLine, endLine = lines.first, lines.last
      if review_level == "COMMIT" then
        local original = thread.original_lines or lines
        startLine = original.last
        endLine = original.last
      end

      local sign = "octo_thread"
      if thread.outdated then
        sign = sign .. "_outdated"
      elseif thread.resolved then
        sign = sign .. "_resolved"
      end

      for _, comment in ipairs(thread.comments) do
        if comment.pending then
          sign = sign .. "_pending"
        end
        if
          (review_level == "PR" and utils.is_thread_placed_in_buffer(thread, split.bufnr))
          or (
            review_level == "COMMIT"
            and current_review.layout.right.commit == thread.original_commit
            and utils.is_thread_placed_in_buffer(thread, split.bufnr)
          )
        then
          -- for lines between startLine and endLine, place the sign
          for line = startLine, endLine do
            signs.place(sign, split.bufnr, line - 1)
          end

          -- place the virtual text only on first line
          if show_virtual_text then
            local last_date = comment.edited_at or comment.created_at
            local comments_count = #thread.comments
            local comments_word = comments_count == 1 and "comment" or "comments"
            local vt_msg = string.format("    %d %s (%s)", comments_count, comments_word, utils.format_date(last_date))
            local opts = {
              virt_text = { { vt_msg, "Comment" } },
              virt_text_pos = "right_align",
              -- adding the extmark below can fail if we are in the `COMMIT` review level and the commit contains thread comments
              -- that is why we set strict to `false` here to ignore this possible error
              strict = false,
            }
            vim.api.nvim_buf_set_extmark(split.bufnr, constants.OCTO_REVIEW_COMMENTS_NS, startLine - 1, -1, opts)
          else
            -- still place the sign without virtual text
            local opts = {
              strict = false,
            }
            vim.api.nvim_buf_set_extmark(split.bufnr, constants.OCTO_REVIEW_COMMENTS_NS, startLine - 1, -1, opts)
          end
          -- break out to prevent duplicate extmarks for the current comment thread
          break
        end
      end
    end
  end
end

---@param opts {
---  use_local: boolean,
---  commit?: string,
---  path: string,
---  status: string,
---  show_diff: boolean,
---  binary: boolean,
---  lines: string[],
---  repo: string,
---  split: string,
---}
function M._create_buffer(opts)
  local current_review = require("octo.reviews").get_current_review()
  if not current_review then
    return
  end
  local bufnr ---@type integer
  if opts.use_local then
    -- Use the file from the file system
    -- Pros: LSP powered
    -- Cons: we need to change to the commit branch
    bufnr = vim.fn.bufadd(opts.path)
    -- vim.fn.bufadd creates the buffer as unlisted by default
    vim.bo[bufnr].buflisted = true
  else
    local bufname =
      -- what a buffer shows is fixed by repo, commit and path, so a buffer by that name can be reused
      string.format("octo://%s/review/%s/file/%s/%s", opts.repo, opts.commit or "", string.upper(opts.split), opts.path)
    local existing_bufnr = utils.find_named_buffer(bufname)
    if existing_bufnr then
      -- Buffer already exists, most likely because review is already opened
      return existing_bufnr
    end

    bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, bufname)
    if opts.binary then
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Binary file" })
    elseif opts.status == "R" and not opts.show_diff then
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Renamed" })
    elseif opts.lines then
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, opts.lines)
    end
  end
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_set_var(bufnr, "octo_diff_props", {
    path = opts.path,
    split = string.upper(opts.split),
  })
  return bufnr
end

---@param left_winid integer
---@param right_winid integer
function M.load_null_buffers(left_winid, right_winid)
  M.load_null_buffer(left_winid)
  M.load_null_buffer(right_winid)
end

---@param winid integer
function M.load_null_buffer(winid)
  local bn = M._get_null_buffer()
  if vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_buf(winid, bn)
  end
  M._configure_buffer(bn)
end

function M._get_null_buffer()
  local msg = "Loading ..."
  local bn = M._null_buffer[msg]

  if bn and vim.api.nvim_buf_is_valid(bn) then
    -- Null buffer already exists and is loaded
    return bn
  end

  -- Create the null buffer
  local nbn = vim.api.nvim_create_buf(false, false)

  vim.api.nvim_buf_set_lines(nbn, 0, -1, false, { msg })
  local bufname = utils.path_join { "octo", "null" }
  vim.bo[nbn].modified = false
  vim.bo[nbn].modifiable = false

  local ok = pcall(vim.api.nvim_buf_set_name, nbn, bufname)
  if not ok then
    utils.wipe_named_buffer(bufname)
    vim.api.nvim_buf_set_name(nbn, bufname)
  end

  M._null_buffer[msg] = nbn

  return M._null_buffer[msg]
end

function M._configure_windows(left_winid, right_winid)
  for _, id in ipairs { left_winid, right_winid } do
    for k, v in pairs(FileEntry.winopts) do
      vim.api.nvim_set_option_value(k, v, { win = id, scope = "local" })
    end
  end
end

function M._configure_buffer(bufid)
  utils.apply_mappings("review_diff", bufid)
end

function M._detach_buffer(bufid)
  local conf = config.values
  for _, mapping in pairs(conf.mappings.review_diff) do
    pcall(vim.keymap.del, "n", mapping.lhs, { buffer = bufid })
  end
end

M.FileEntry = FileEntry

return M
