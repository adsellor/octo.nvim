---The forge seam: everything the UI may ask of a code-hosting service.
---Data types: octo.forge.types.
---
---Contract every adapter honours:
---  * Each method takes a callback `cb(err, result)` and calls it exactly once, on the main loop,
---    never synchronously. `err` is a message fit to show the user; `result` is nil when `err` is set.
---  * Reads never change forge state. Writes return the affected entity, so callers can patch
---    their view without re-reading everything.
---  * Asking for an unsupported feature fails with an error rather than silently doing less.
---  * Having nothing to do is not an error: submitting an empty review, discarding when nothing is
---    pending and resolving a resolved thread all succeed.
---
---@class octo.Forge
---@field id string adapter id, e.g. "github"
---Whether the forge can do `feature`; the UI hides what it can't.
---@field supports fun(self: octo.Forge, feature: octo.forge.Feature): boolean
---The pull requests in `repo` that pass `filter`, every page of them, in the filter's order.
---@field pull_requests fun(self: octo.Forge, repo: octo.forge.RepoRef, filter: octo.forge.PullRequestFilter, cb: fun(err?: string, prs?: octo.forge.PullRequestSummary[]))
---The pull request, including the merge base its changes are measured from.
---@field pull_request fun(self: octo.Forge, pr: octo.forge.PullRequestRef, cb: fun(err?: string, pull_request?: octo.forge.PullRequest))
---Files changed by the whole pull request, or only within `range`.
---@field changes fun(self: octo.Forge, pr: octo.forge.PullRequestRef, range: octo.forge.Range?, cb: fun(err?: string, files?: octo.forge.ChangedFile[]))
---A file's text at one of the pull request's commits; "" when the file isn't there or is binary.
---@field contents fun(self: octo.Forge, pr: octo.forge.PullRequestRef, commit: string, path: string, cb: fun(err?: string, text?: string))
---Every review thread, including the viewer's pending comments.
---@field threads fun(self: octo.Forge, pr: octo.forge.PullRequestRef, cb: fun(err?: string, threads?: octo.forge.Thread[]))
---Post a top-level comment, a reply, or a new thread. Drafts join the viewer's pending review,
---which is created on demand.
---@field comment fun(self: octo.Forge, pr: octo.forge.PullRequestRef, new: octo.forge.NewComment, cb: fun(err?: string, posted?: octo.forge.Posted))
---Replace a comment's body.
---@field edit fun(self: octo.Forge, pr: octo.forge.PullRequestRef, comment_id: string, body: string, cb: fun(err?: string, comment?: octo.forge.Comment))
---Delete a comment; a thread whose last comment goes is gone too.
---@field delete fun(self: octo.Forge, pr: octo.forge.PullRequestRef, comment_id: string, cb: fun(err?: string))
---Add or remove the viewer's reaction to a comment; returns the comment's reactions after (feature "reactions").
---@field react fun(self: octo.Forge, pr: octo.forge.PullRequestRef, comment_id: string, content: octo.forge.ReactionContent, add: boolean, cb: fun(err?: string, reactions?: octo.forge.Reaction[]))
---Resolve or reopen a thread (feature "resolve").
---@field resolve fun(self: octo.Forge, pr: octo.forge.PullRequestRef, thread_id: string, resolved: boolean, cb: fun(err?: string, thread?: octo.forge.Thread))
---Publish the viewer's pending comments with a verdict and an optional summary.
---@field submit fun(self: octo.Forge, pr: octo.forge.PullRequestRef, verdict: octo.forge.Verdict, body: string?, cb: fun(err?: string))
---Delete the viewer's pending comments.
---@field discard fun(self: octo.Forge, pr: octo.forge.PullRequestRef, cb: fun(err?: string))
---Mark a file viewed or unviewed for the viewer (feature "viewed").
---@field set_viewed fun(self: octo.Forge, pr: octo.forge.PullRequestRef, path: string, viewed: boolean, cb: fun(err?: string))

local M = {}

---@type table<string, fun(host: string): octo.Forge>
local factories = {
  github = function(host)
    return require("octo.forge.github").new { host = host }
  end,
  bitbucket = function(host)
    return require("octo.forge.bitbucket").new { host = host }
  end,
}

---Hosts served by something other than the GitHub adapter.
---@type table<string, string>
local adapter_by_host = {
  ["bitbucket.org"] = "bitbucket",
}

---@type table<string, octo.Forge>
local instances = {}

---Make an adapter available under `id`.
---@param id string
---@param factory fun(host: string): octo.Forge
function M.register(id, factory)
  factories[id] = factory
end

---The forge that serves `repo`. One instance per host, created on first use.
---@param repo octo.forge.RepoRef
---@return octo.Forge
function M.get(repo)
  local forge = instances[repo.host]
  if not forge then
    local id = adapter_by_host[repo.host] or "github"
    local factory = factories[id]
    if not factory then
      error(string.format("No forge adapter %q for %s", id, repo.host), 0)
    end
    forge = factory(repo.host)
    instances[repo.host] = forge
  end
  return forge
end

---Serve `host` with `forge` instead of the default adapter; nil restores the default.
---For tests and for plugging in adapters that need configuration.
---@param host string
---@param forge octo.Forge?
function M.set(host, forge)
  instances[host] = forge
end

---@param name_with_owner string "owner/name"
---@param host? string defaults to `github_hostname`, then the current git remote's host
---@return octo.forge.RepoRef
function M.repo(name_with_owner, host)
  local utils = require "octo.utils"
  local owner, name = utils.split_repo(name_with_owner)
  if utils.is_blank(host) then
    local configured = require("octo.config").values.github_hostname
    host = not utils.is_blank(configured) and configured or utils.get_remote_host()
  end
  return { host = host, owner = owner, name = name }
end

---@param name_with_owner string "owner/name"
---@param number integer
---@param host? string defaults as for `repo`
---@return octo.forge.PullRequestRef
function M.ref(name_with_owner, number, host)
  return { repo = M.repo(name_with_owner, host), number = number }
end

return M
