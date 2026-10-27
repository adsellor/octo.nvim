---A repository's pull requests as the pickers list them, and what can be done with one.
---Pickers only lay out octo.forge.PullRequestSummary values; fetching, opening, checking out and
---the rest go through here, so they work the same on every forge.
local async = require "octo.forge.async"
local config = require "octo.config"
local forge = require "octo.forge"
local utils = require "octo.utils"

local M = {}

local known_states = { open = true, closed = true, merged = true }

---@param value? string|string[] "a,b" from the command line, or a list
---@return string[]?
local function list(value)
  if type(value) == "string" then
    return vim.split(value, ",", { trimempty = true })
  end
  return value
end

---`:Octo pr list` arguments as a forge filter. Raises on states the forge doesn't know.
---@param opts { states?: string|string[], labels?: string|string[], baseRefName?: string, headRefName?: string }
---@return octo.forge.PullRequestFilter
function M.filter(opts)
  local states = vim.tbl_map(string.lower, list(opts.states) or { "open" }) ---@type string[]
  for _, state in ipairs(states) do
    if not known_states[state] then
      error(string.format("Unknown pull request state %q: use open, closed or merged", state), 0)
    end
  end
  local labels = list(opts.labels)
  local order = config.values.pull_requests.order_by
  return {
    states = states,
    labels = labels and #labels > 0 and labels or nil,
    base = not utils.is_blank(opts.baseRefName) and opts.baseRefName or nil,
    head = not utils.is_blank(opts.headRefName) and { name = opts.headRefName } or nil,
    order = {
      field = order.field == "UPDATED_AT" and "updated" or "created",
      direction = order.direction == "ASC" and "asc" or "desc",
    },
  }
end

---Fetch the pull requests `opts` asks for. Reports failures and empty results itself, so `cb`
---only ever gets a non-empty list.
---@param opts { repo?: string, states?: string|string[], labels?: string|string[], baseRefName?: string, headRefName?: string }
---@param cb fun(prs: octo.forge.PullRequestSummary[])
function M.list(opts, cb)
  local name_with_owner = not utils.is_blank(opts.repo) and opts.repo or utils.get_remote_name()
  if utils.is_blank(name_with_owner) then
    utils.error "Cannot find repo"
    return
  end
  local ok, filter = pcall(M.filter, opts)
  if not ok then
    utils.error(filter --[[@as string]])
    return
  end
  local repo = forge.repo(name_with_owner --[[@as string]])
  utils.info "Fetching pull requests (this may take a while) ..."
  forge.get(repo):pull_requests(repo, filter, function(err, prs)
    if err then
      utils.error(err)
    elseif not prs or #prs == 0 then
      utils.error(string.format("There are no matching pull requests in %s.", name_with_owner))
    else
      cb(prs)
    end
  end)
end

---"owner/name" of the repository the pull request belongs to.
---@param pr octo.forge.PullRequestSummary
function M.repo_name(pr)
  return pr.ref.repo.owner .. "/" .. pr.ref.repo.name
end

---Only GitHub pull requests have a PR buffer so far; elsewhere a pull request opens as a review.
---@param pr octo.forge.PullRequestSummary
local function has_buffer(pr)
  return forge.get(pr.ref.repo).id == "github"
end

---The octo:// buffer name the pull request opens in, for pickers that open files; nil when it
---opens as a review instead.
---@param pr octo.forge.PullRequestSummary
---@return string?
function M.uri(pr)
  return has_buffer(pr) and utils.get_pull_request_uri(pr.ref.number, M.repo_name(pr)) or nil
end

local split_commands = { horizontal = "split", vertical = "vsplit", tab = "tabnew" }

---Open the pull request's buffer, in a split when `split` says so; where there is no buffer,
---start or resume a review of it instead.
---@param pr octo.forge.PullRequestSummary
---@param split? "default"|"horizontal"|"vertical"|"tab"
function M.open(pr, split)
  if not has_buffer(pr) then
    require("octo.reviews").review_pull_request(pr.ref)
    return
  end
  if split_commands[split] then
    vim.cmd(split_commands[split])
  end
  utils.get("pull_request", pr.ref.number, M.repo_name(pr))
end

---@param pr octo.forge.PullRequestSummary
function M.browse(pr)
  require("octo.navigation").open_in_browser_raw(pr.url)
end

---@param pr octo.forge.PullRequestSummary
function M.copy_url(pr)
  utils.copy_url(pr.url)
end

---Copy the head commit's full sha, which listings don't carry.
---@param pr octo.forge.PullRequestSummary
function M.copy_sha(pr)
  utils.info "Fetching PR details for SHA..."
  forge.get(pr.ref.repo):pull_request(pr.ref, function(err, full)
    if err or not full then
      utils.error(err or "Pull request not found")
      return
    end
    utils.copy_sha(full.head.sha)
  end)
end

---@param pr octo.forge.PullRequestSummary
function M.merge(pr)
  if not has_buffer(pr) then
    utils.error(string.format("Merging from octo isn't supported on %s yet", pr.ref.repo.host))
    return
  end
  utils.merge_pr(pr.ref.number)
end

---Run git in the working directory; `done(err, stdout)` on the main loop, err being git's stderr.
---@param args string[]
---@param done fun(err?: string, stdout?: string)
local function git(args, done)
  vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = vim.fn.getcwd() }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local stderr = vim.trim(res.stderr or "")
        done(stderr ~= "" and stderr or ("git " .. args[1] .. " failed"))
      else
        done(nil, res.stdout or "")
      end
    end)
  end)
end

---The name of the git remote that points at `repo`, if there is one.
---@param repo octo.forge.RepoRef
---@return string?
local function remote_for(repo)
  local wanted = (repo.owner .. "/" .. repo.name):lower()
  for name, remote in pairs(utils.parse_git_remote()) do
    if remote.host == repo.host and remote.repo and remote.repo:lower() == wanted then
      return name
    end
  end
end

---Fetch the head branch and switch to it, tracking where it lives so `:Octo review` can find
---the pull request again. Forks without a remote are tracked by URL.
---@async
---@param pr octo.forge.PullRequestSummary
---@return string branch
---@return string? note what the user should know beyond the switch
local function checkout_with_git(pr)
  local branch = pr.head.name
  local exists = async.attempt(git, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }) ~= nil
  local remote = remote_for(pr.head.repo)
  local source, fetched ---@type string, string
  if remote then
    source, fetched = remote, "refs/remotes/" .. remote .. "/" .. branch
    async.await(git, { "fetch", remote, "+refs/heads/" .. branch .. ":" .. fetched })
  else
    -- a fork nobody added as a remote: reach it through the base remote's URL
    local base_remote = remote_for(pr.base.repo)
    if not base_remote then
      error("No git remote points at " .. M.repo_name(pr), 0)
    end
    local base_url = vim.trim(async.await(git, { "remote", "get-url", base_remote }))
    local base_path = pr.base.repo.owner .. "/" .. pr.base.repo.name
    local at = base_url:lower():find(base_path:lower(), 1, true)
    if not at then
      error("Can't tell the fork's URL from " .. base_url, 0)
    end
    source = base_url:sub(1, at - 1) .. pr.head.repo.owner .. "/" .. pr.head.repo.name .. base_url:sub(at + #base_path)
    fetched = "FETCH_HEAD"
    async.await(git, { "fetch", source, "refs/heads/" .. branch })
  end
  if exists then
    async.await(git, { "checkout", branch })
    local _, err = async.attempt(git, { "merge", "--ff-only", fetched })
    if err then
      -- not the pull request's history, or ahead of it: leave the branch and its tracking alone
      return branch, "it has commits the pull request doesn't, so it was left as it was"
    end
  else
    async.await(git, { "checkout", "-b", branch, fetched })
  end
  async.await(git, { "config", "branch." .. branch .. ".remote", source })
  async.await(git, { "config", "branch." .. branch .. ".merge", "refs/heads/" .. branch })
  return branch
end

---Check the pull request's branch out locally.
---@param pr octo.forge.PullRequestSummary
function M.checkout(pr)
  if has_buffer(pr) then
    -- gh knows GitHub's fork and maintainer-edit setups
    utils.checkout_pr(pr.ref.number)
    return
  end
  async.run( ---@async
    function()
      return { checkout_with_git(pr) }
    end,
    function(err, result)
      if err then
        utils.error(err)
      else
        utils.info("Switched to " .. result[1] .. (result[2] and "; " .. result[2] or ""))
      end
    end
  )
end

---The icon and highlight for the pull request's state.
---@param pr octo.forge.PullRequestSummary
---@return [string, string]
function M.icon(pr)
  local icons = utils.icons.pull_request
  if pr.state == "merged" then
    return icons.merged
  elseif pr.state == "closed" then
    return icons.closed
  elseif pr.draft then
    return icons.draft
  elseif pr.queued then
    return icons.queued
  end
  return icons.open
end

---"⧉ 2/3" for a pull request in a stack, else nil.
---@param pr octo.forge.PullRequestSummary
---@return string?
function M.stack_indicator(pr)
  return pr.stack and string.format("⧉ %d/%d", pr.stack.position, pr.stack.size) or nil
end

local state_highlights = {
  open = "OctoStateOpen",
  closed = "OctoStateClosed",
  merged = "OctoStateMerged",
  draft = "OctoStateDraft",
}

---A preview of the pull request from what the listing already holds: its lines, and the
---highlights to lay over them as { row, start_col, end_col, group } (0-based, end exclusive).
---@param pr octo.forge.PullRequestSummary
---@return string[] lines
---@return [integer, integer, integer, string][] highlights
function M.preview_lines(pr)
  local state = pr.state == "open" and pr.draft and "draft" or pr.state
  local details =
    string.format("#%d %s by %s  %s → %s", pr.ref.number, state:upper(), pr.author.login, pr.head.name, pr.base.name)
  local state_at = #string.format("#%d ", pr.ref.number)
  local lines = { pr.title, "", details }
  local highlights = {
    { 0, 0, #pr.title, "OctoIssueTitle" },
    { 2, state_at, state_at + #state, state_highlights[state] },
  }
  local dates =
    string.format("Created %s, updated %s", utils.format_date(pr.created_at), utils.format_date(pr.updated_at))
  table.insert(lines, dates)
  table.insert(highlights, { #lines - 1, 0, #dates, "Comment" })
  if #pr.labels > 0 then
    table.insert(lines, "Labels: " .. table.concat(pr.labels, ", "))
    table.insert(highlights, { #lines - 1, 0, #lines[#lines], "Comment" })
  end
  table.insert(lines, "")
  vim.list_extend(lines, vim.split((pr.body:gsub("\r", "")), "\n"))
  return lines, highlights
end

---Write the pull request's preview into `bufnr`.
---@param bufnr integer
---@param pr octo.forge.PullRequestSummary
function M.preview(bufnr, pr)
  local lines, highlights = M.preview_lines(pr)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace "octo_pull_request_preview"
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, hl[1], hl[2], { end_col = hl[3], hl_group = hl[4] })
  end
  vim.bo[bufnr].filetype = "markdown"
end

return M
