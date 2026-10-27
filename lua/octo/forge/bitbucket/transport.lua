---How the Bitbucket adapter reaches Bitbucket: curl, with the whole request (credentials
---included) passed as a config on stdin, so no secret ever appears in the process list.
---
---Credentials come from the environment, checked on every request:
---  BITBUCKET_ACCESS_TOKEN                   a repository, project or workspace access token
---  BITBUCKET_EMAIL + BITBUCKET_API_TOKEN    an Atlassian API token with Bitbucket scopes
---Without either, requests go out anonymously, which is enough to read public repositories.

---@alias octo.forge.bitbucket.Auth { bearer: string }|{ basic: string }

---@class octo.forge.bitbucket.RequestOpts
---@field body? table JSON request body
---@field raw? boolean return the body as text instead of decoding JSON
---@field allow_missing? boolean answer a 404 with nil data instead of an error

---@class octo.forge.bitbucket.Transport
---Send a request to an absolute API url. `data` is the decoded JSON body, the raw text with
---`raw`, or nil for an empty response.
---@field request fun(method: string, url: string, opts: octo.forge.bitbucket.RequestOpts?, cb: fun(err?: string, data?: any))

local M = {}

---@return octo.forge.bitbucket.Auth?
local function env_auth()
  local token = vim.env.BITBUCKET_ACCESS_TOKEN ---@type string?
  if token and token ~= "" then
    return { bearer = token }
  end
  local email = vim.env.BITBUCKET_EMAIL ---@type string?
  local api_token = vim.env.BITBUCKET_API_TOKEN ---@type string?
  if email and email ~= "" and api_token and api_token ~= "" then
    return { basic = email .. ":" .. api_token }
  end
end

---A value for curl's config syntax.
---@param value string
local function quote(value)
  local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return '"' .. escaped .. '"'
end

---@param method string
---@param url string
---@param opts octo.forge.bitbucket.RequestOpts
---@param auth octo.forge.bitbucket.Auth?
---@return string
function M.curl_config(method, url, opts, auth)
  local lines = {
    "url = " .. quote(url),
    "request = " .. quote(method),
    -- uuids in urls contain braces, which curl would otherwise expand
    "globoff",
    "header = " .. quote(opts.raw and "Accept: text/plain" or "Accept: application/json"),
  }
  if auth and auth.bearer then
    table.insert(lines, "header = " .. quote("Authorization: Bearer " .. auth.bearer))
  elseif auth and auth.basic then
    table.insert(lines, "user = " .. quote(auth.basic))
  end
  if opts.body then
    table.insert(lines, "header = " .. quote "Content-Type: application/json")
    table.insert(lines, "data-binary = " .. quote(vim.json.encode(opts.body)))
  end
  return table.concat(lines, "\n") .. "\n"
end

---What to tell the user about a failed request.
---@param body string
---@param status integer
function M.failure(body, status)
  local ok, resp = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  local err = ok and type(resp) == "table" and type(resp.error) == "table" and resp.error or {} ---@type { message?: string, detail?: string }
  local message = type(err.message) == "string" and err.message or ("Bitbucket answered HTTP " .. status)
  if type(err.detail) == "string" then
    message = message .. ": " .. err.detail
  end
  if status == 401 then
    message = message .. " (set BITBUCKET_EMAIL and BITBUCKET_API_TOKEN, or BITBUCKET_ACCESS_TOKEN)"
  end
  return message
end

---@param opts? { auth?: fun(): octo.forge.bitbucket.Auth? }
---@return octo.forge.bitbucket.Transport
function M.new(opts)
  local auth = opts and opts.auth or env_auth
  return {
    request = function(method, url, request_opts, cb)
      request_opts = request_opts or {}
      local config = M.curl_config(method, url, request_opts, auth())
      local cmd = { "curl", "--silent", "--show-error", "--location", "--config", "-", "--write-out", "\n%{http_code}" }
      vim.system(cmd, { stdin = config, text = true }, function(result)
        vim.schedule(function()
          if result.code ~= 0 then
            return cb(vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or "curl failed")
          end
          local body, status = (result.stdout or ""):match "^(.*)\n(%d%d%d)$"
          status = tonumber(status) or 0
          if status == 404 and request_opts.allow_missing then
            return cb(nil, nil)
          end
          if status < 200 or status >= 300 then
            return cb(M.failure(body or "", status))
          end
          if request_opts.raw then
            return cb(nil, body)
          end
          if not body or vim.trim(body) == "" then
            return cb(nil, nil)
          end
          local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
          if not ok then
            return cb("Unexpected response from " .. url)
          end
          cb(nil, data)
        end)
      end)
    end,
  }
end

return M
