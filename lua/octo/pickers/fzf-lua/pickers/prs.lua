---@diagnostic disable
local fzf = require "fzf-lua"
local octo_config = require "octo.config"
local picker_utils = require "octo.pickers.fzf-lua.pickers.utils"
local previewers = require "octo.pickers.fzf-lua.previewers"
local pull_requests = require "octo.pull-requests"
local utils = require "octo.utils"

return function(opts)
  opts = opts or {}
  local cb = utils.pop_key(opts, "cb")
  local window_title = utils.pop_key(opts, "window_title") or "Pull Requests"
  local prompt_title = utils.pop_key(opts, "prompt_title")
  local cfg = octo_config.values

  pull_requests.list(opts, function(prs)
    local by_number = {} ---@type table<integer, octo.forge.PullRequestSummary>
    local lines = {} ---@type string[]
    for _, pr in ipairs(prs) do
      by_number[pr.ref.number] = pr
      local title = pr.title
      local stack_indicator = pull_requests.stack_indicator(pr)
      if stack_indicator then
        title = title .. "  " .. fzf.utils.ansi_from_hl("Comment", stack_indicator)
      end
      local icon = pull_requests.icon(pr)
      table.insert(lines, fzf.utils.ansi_from_hl(icon[2], tostring(pr.ref.number)) .. " " .. title)
    end

    ---@param selected string[]
    local function picked(selected)
      return by_number[tonumber(selected[1]:match "^(%d+)")]
    end
    ---@param split "default"|"horizontal"|"vertical"|"tab"
    local function open(split)
      return function(selected)
        if cb then
          cb(picked(selected))
        else
          pull_requests.open(picked(selected), split)
        end
      end
    end
    ---@param action fun(pr: octo.forge.PullRequestSummary)
    local function on_picked(action)
      return function(selected)
        action(picked(selected))
      end
    end

    local mappings = cfg.picker_config.mappings
    fzf.fzf_exec(lines, {
      prompt = picker_utils.get_prompt(prompt_title),
      previewer = previewers.pull_request(by_number),
      fzf_opts = {
        ["--no-multi"] = "", -- TODO this can support multi, maybe.
        ["--info"] = "default",
      },
      winopts = {
        title = window_title,
        title_pos = "center",
      },
      actions = {
        ["default"] = open "default",
        ["ctrl-v"] = open "vertical",
        ["ctrl-s"] = open "horizontal",
        ["ctrl-t"] = open "tab",
        [utils.convert_vim_mapping_to_fzf(mappings.open_in_browser.lhs)] = on_picked(pull_requests.browse),
        [utils.convert_vim_mapping_to_fzf(mappings.copy_url.lhs)] = on_picked(pull_requests.copy_url),
        [utils.convert_vim_mapping_to_fzf(mappings.checkout_pr.lhs)] = on_picked(pull_requests.checkout),
      },
    })
  end)
end
