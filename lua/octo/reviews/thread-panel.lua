local OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
local utils = require "octo.utils"
local vim = vim

local M = {}

---Show review threads under cursor if there are any
---@param jump_to_buffer boolean
function M.show_review_threads(jump_to_buffer)
  -- This function is called from a very broad CursorHold event
  -- Check if we are in a diff buffer and otherwise return early
  local bufnr = vim.api.nvim_get_current_buf()
  local split, path = utils.get_split_and_path(bufnr)
  if not split or not path then
    -- not on a diff buffer
    return
  end

  local review = require("octo.reviews").get_current_review()
  if not review then
    -- cant find an active review
    return
  end

  local file = review.layout:get_current_file()
  if not file then
    -- cant find the changed file metadata
    return
  end

  local pr = file.pull_request
  local review_level = review:get_level()
  local line = vim.api.nvim_win_get_cursor(0)[1]

  -- get threads associated with current line
  local threads_at_cursor = {} ---@type octo.forge.Thread[]
  for _, thread in pairs(review.threads) do
    local lines = review_level == "PR" and thread.lines
      or review_level == "COMMIT" and review.layout.right.commit == thread.original_commit and thread.original_lines
    if
      lines
      and utils.is_thread_placed_in_buffer(thread, bufnr)
      and (review_level == "PR" and lines.first <= line and lines.last >= line or lines.last == line)
    then
      table.insert(threads_at_cursor, thread)
    end
  end
  table.sort(threads_at_cursor, function(a, b)
    local a_line = (a.original_lines or a.lines).first
    local b_line = (b.original_lines or b.lines).first
    if a_line ~= b_line then
      return a_line < b_line
    end
    return a.id < b.id
  end)

  -- render thread buffer if there are threads at the current line
  if #threads_at_cursor > 0 then
    review.layout:ensure_layout()
    local alt_win = file:get_alternative_win(split)
    if vim.api.nvim_win_is_valid(alt_win) then
      for _, thread in ipairs(threads_at_cursor) do
        -- forges that don't send the hunk around a thread get the one from this file's diff
        if not thread.diff_hunk then
          local lines = thread.original_lines or thread.lines --[[@as octo.forge.LineRange]]
          thread.diff_hunk = file:hunk_at(thread.side, lines.first, lines.last)
        end
      end
      local first = threads_at_cursor[1].original_lines or threads_at_cursor[1].lines --[[@as octo.forge.LineRange]]
      local thread_buffer = M.create_thread_buffer(pr.repo, pr.number, split, file.path, first.first, function(bufnr)
        require("octo.reviews.thread-buffer").write(bufnr, threads_at_cursor)
      end)
      if thread_buffer then
        table.insert(file.associated_bufs, thread_buffer.bufnr)
        vim.api.nvim_win_set_buf(alt_win, thread_buffer.bufnr)
        thread_buffer:configure()

        vim.keymap.set("n", "q", function()
          M.hide_thread_buffer(split, file)
          local file_win = file:get_win(split)
          if vim.api.nvim_win_is_valid(file_win) then
            vim.api.nvim_set_current_win(file_win)
          end
        end, { buffer = thread_buffer.bufnr })

        if jump_to_buffer then
          vim.api.nvim_set_current_win(alt_win)
        end
        vim.api.nvim_buf_call(thread_buffer.bufnr, function()
          vim.cmd [[diffoff!]]
          pcall(vim.cmd.normal, "]c")
        end)
      end
    end
  else
    -- no threads at the current line, hide the thread buffer
    M.hide_thread_buffer(split, file)
  end
end

---@param split OctoSplit
---@param file FileEntry
function M.hide_thread_buffer(split, file)
  local alt_buf = file:get_alternative_buf(split)
  local alt_win = file:get_alternative_win(split)
  if vim.api.nvim_win_is_valid(alt_win) and vim.api.nvim_buf_is_valid(alt_buf) then
    local current_alt_bufnr = vim.api.nvim_win_get_buf(alt_win)
    if current_alt_bufnr ~= alt_buf then
      -- if we are not showing the corresponding alternative diff buffer, do so
      vim.api.nvim_win_set_buf(alt_win, alt_buf)

      -- Save cursor position before show_diff (which scrolls to sync windows)
      local current_win = vim.api.nvim_get_current_win()
      local cursor_pos = vim.api.nvim_win_get_cursor(current_win)

      -- show the diff
      file:show_diff()

      -- Restore cursor position (show_diff scrolls which can disrupt cursor)
      if vim.api.nvim_win_is_valid(current_win) then
        pcall(vim.api.nvim_win_set_cursor, current_win, cursor_pos)
      end
    end
  end
end

---Create a thread buffer, or return the one already open for that place
---@param repo string
---@param number integer
---@param side string
---@param path string
---@param line integer
---@param write fun(bufnr: integer) writes the threads into the new buffer
---@return OctoBuffer | nil
function M.create_thread_buffer(repo, number, side, path, line, write)
  local current_review = require("octo.reviews").get_current_review()
  if not current_review then
    return
  end

  if not vim.startswith(path, "/") then
    path = "/" .. path
  end
  local bufname = string.format("octo://%s/review/%d/threads/%s%s:%d", repo, number, side, path, line)
  local existing_bufnr = vim.fn.bufnr(bufname)

  if existing_bufnr ~= -1 then
    if vim.api.nvim_buf_is_loaded(existing_bufnr) then
      return octo_buffers[existing_bufnr]
    end

    -- Weird situation, force delete buffer and start from scratch
    vim.api.nvim_buf_delete(existing_bufnr, { force = true })
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, bufname)
  local buffer = OctoBuffer:new {
    bufnr = bufnr,
    number = number,
    repo = repo,
  }
  buffer:clear()
  write(bufnr)
  vim.bo[bufnr].modified = false
  buffer.ready = true
  buffer:render_signs()
  vim.api.nvim_buf_call(bufnr, function()
    utils.clear_history()
  end)
  return buffer
end

return M
