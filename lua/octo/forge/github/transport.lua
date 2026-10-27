---How the GitHub adapter reaches GitHub: the gh CLI, with request bodies as JSON on stdin so no
---value is ever reinterpreted as a flag, a number or an @file.

---@class octo.forge.github.RestOpts
---@field body? table JSON request body
---@field paginate? boolean follow pagination and concatenate the pages of an array response

---@class octo.forge.github.Transport
---Run a GraphQL document. `data` is the response's `data` field; GraphQL errors become `err`.
---@field graphql fun(host: string, query: string, variables: table, cb: fun(err?: string, data?: table))
---Call a REST endpoint, e.g. ("GET", "repos/o/n/pulls/1/files").
---@field rest fun(host: string, method: string, path: string, opts: octo.forge.github.RestOpts?, cb: fun(err?: string, data?: any))

local M = {}

---@param s string
---@return any
local function decode(s)
  if s == nil or vim.trim(s) == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if ok then
    return value
  end
end

---@param stderr string
---@param status integer
local function failure(stderr, status)
  stderr = vim.trim(stderr or "")
  return stderr ~= "" and stderr or ("gh exited with status " .. tostring(status))
end

---@param variables table
local function as_object(variables)
  return next(variables) == nil and vim.empty_dict() or variables
end

function M.graphql(host, query, variables, cb)
  require("octo.gh").run {
    args = { "api", "graphql", "--method", "POST", "--input", "-" },
    stdin = vim.json.encode { query = query, variables = as_object(variables) },
    hostname = host,
    cb = function(stdout, stderr, status)
      local resp = decode(stdout)
      if type(resp) == "table" and resp.errors then
        local messages = vim.tbl_map(function(e) ---@param e { message: string }
          return e.message
        end, resp.errors)
        return cb(table.concat(messages, "\n"))
      end
      if status ~= 0 or type(resp) ~= "table" then
        return cb(failure(stderr, status))
      end
      cb(nil, resp.data)
    end,
  }
end

function M.rest(host, method, path, opts, cb)
  opts = opts or {}
  local args = { "api", "--method", method, path }
  local stdin ---@type string?
  if opts.paginate then
    vim.list_extend(args, { "--paginate", "--slurp" })
  end
  if opts.body then
    vim.list_extend(args, { "--input", "-" })
    stdin = vim.json.encode(opts.body)
  end
  require("octo.gh").run {
    args = args,
    stdin = stdin,
    hostname = host,
    -- node ids in the same format GraphQL returns
    headers = { "X-Github-Next-Global-ID: 1" },
    cb = function(stdout, stderr, status)
      local resp = decode(stdout)
      if status ~= 0 then
        local message = type(resp) == "table" and resp.message or nil
        return cb(message or failure(stderr, status))
      end
      if opts.paginate and type(resp) == "table" then
        local items, pages = {}, resp ---@type any[], any[][]
        for _, page in ipairs(pages) do
          vim.list_extend(items, page)
        end
        resp = items
      end
      cb(nil, resp)
    end,
  }
end

return M
