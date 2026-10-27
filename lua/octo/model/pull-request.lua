local FileEntry = require("octo.reviews.file-entry").FileEntry
local utils = require "octo.utils"

local M = {}

---https://docs.github.com/en/graphql/reference/enums#fileviewedstate
---@alias octo.FileViewedState "DISMISSED" | "VIEWED" | "UNVIEWED"

---@class PullRequest
---@field forge octo.Forge
---@field ref octo.forge.PullRequestRef
---@field repo string
---@field head_repo string
---@field head_ref_name string
---@field owner string
---@field name string
---@field number integer
---@field id string
---@field bufnr integer
---@field left Rev
---@field right Rev
---@field local_right boolean
---@field local_left boolean
---@field files {[string]: octo.FileViewedState} viewed state per path, filled by get_changed_files
local PullRequest = {}
PullRequest.__index = PullRequest

---@class PullRequestOpts
---@field forge octo.Forge
---@field ref octo.forge.PullRequestRef
---@field repo string
---@field head_repo string
---@field head_ref_name string
---@field number integer
---@field id string
---@field left Rev
---@field right Rev
---@field bufnr? integer

---PullRequest constructor.
---@param opts PullRequestOpts
---@return PullRequest
function PullRequest:new(opts)
  ---@type PullRequest
  local this = {
    forge = opts.forge,
    ref = opts.ref,
    repo = opts.repo,
    head_repo = opts.head_repo,
    head_ref_name = opts.head_ref_name,
    number = opts.number,
    owner = "",
    name = "",
    id = opts.id,
    left = opts.left,
    right = opts.right,
    local_right = false,
    local_left = false,
    bufnr = opts.bufnr,
    files = {},
  }
  this.owner, this.name = utils.split_repo(this.repo)
  utils.commit_exists(this.right.commit, function(exists)
    this.local_right = exists
  end)
  utils.commit_exists(this.left.commit, function(exists)
    this.local_left = exists
  end)

  setmetatable(this, self)

  return this
end

M.PullRequest = PullRequest

---@type table<octo.forge.ViewedState, octo.FileViewedState>
local viewed_states = { viewed = "VIEWED", unviewed = "UNVIEWED", dismissed = "DISMISSED" }

---@param pr PullRequest
---@param changed octo.forge.ChangedFile[]
---@return FileEntry[]
local function file_entries(pr, changed)
  return vim.tbl_map(function(file) ---@param file octo.forge.ChangedFile
    return FileEntry:new {
      path = file.path,
      previous_path = file.previous_path,
      patch = file.patch,
      pull_request = pr,
      status = file.status,
      stats = {
        additions = file.additions,
        deletions = file.deletions,
        changes = file.additions + file.deletions,
      },
    }
  end, changed)
end

---Fetch the files changed by the whole pull request
---@param callback fun(files: FileEntry[]): nil
function PullRequest:get_changed_files(callback)
  self.forge:changes(self.ref, nil, function(err, changed)
    if err then
      return utils.error("Failed to fetch changed files: " .. err)
    end
    for _, file in ipairs(changed) do
      self.files[file.path] = file.viewed and viewed_states[file.viewed] or nil
    end
    callback(file_entries(self, changed))
  end)
end

---Fetch the files changed between two commits of the pull request
---@param left Rev
---@param right Rev
---@param callback fun(files: FileEntry[]): nil
function PullRequest:get_commit_changed_files(left, right, callback)
  self.forge:changes(self.ref, { base = left.commit, head = right.commit }, function(err, changed)
    if err then
      return utils.error("Failed to fetch changed files: " .. err)
    end
    callback(file_entries(self, changed))
  end)
end

---Load a pull request for review: its diff runs from the merge base to the head.
---@param opts { repo: string, number: integer, hostname?: string, bufnr?: integer }
---@param cb fun(pull_request: PullRequest)
function M.load(opts, cb)
  local forge = require "octo.forge"
  local Rev = require("octo.reviews.rev").Rev
  local ref = forge.ref(opts.repo, opts.number, opts.hostname)
  local f = forge.get(ref.repo)
  f:pull_request(ref, function(err, pr)
    if err then
      return utils.error("Failed to load pull request: " .. err)
    end
    cb(PullRequest:new {
      forge = f,
      ref = ref,
      repo = opts.repo,
      head_repo = pr.head.repo.owner .. "/" .. pr.head.repo.name,
      head_ref_name = pr.head.name,
      number = opts.number,
      id = pr.id,
      bufnr = opts.bufnr,
      left = Rev:new(pr.merge_base),
      right = Rev:new(pr.head.sha),
    })
  end)
end

return M
