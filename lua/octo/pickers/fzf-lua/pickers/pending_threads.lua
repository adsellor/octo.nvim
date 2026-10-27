---@diagnostic disable
local entry_maker = require "octo.pickers.fzf-lua.entry_maker"
local fzf = require "fzf-lua"
local navigation = require "octo.navigation"
local previewers = require "octo.pickers.fzf-lua.previewers"
local reviews = require "octo.reviews"

return function(threads)
  local max_linenr_length = -1
  for _, thread in ipairs(threads) do
    local lines = thread.lines or thread.original_lines or { first = 1, last = 1 }
    max_linenr_length = math.max(max_linenr_length, #tostring(lines.first), #tostring(lines.last))
  end

  local formatted_threads = {}
  local titles = {}

  for _, thread in ipairs(threads) do
    local entry = entry_maker.gen_from_review_thread(max_linenr_length, thread)

    if entry ~= nil then
      formatted_threads[entry.ordinal] = entry
      table.insert(titles, entry.ordinal)
    end
  end

  fzf.fzf_exec(titles, {
    prompt = nil,
    fzf_opts = {
      ["--no-multi"] = "", -- TODO this can support multi, maybe.
    },
    previewer = previewers.review_thread(formatted_threads),
    actions = {
      ["default"] = function(selected)
        local entry = formatted_threads[selected[1]]
        reviews.jump_to_pending_review_thread(entry.thread)
      end,
      ["ctrl-b"] = function(selected)
        local entry = formatted_threads[selected[1]]
        navigation.open_in_browser_raw(entry.thread.comments[1].url)
      end,
    },
  })
end
