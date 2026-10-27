---Coroutine helpers so adapters can be written as straight-line code.
---Internal to adapters: the forge interface itself stays callback-based.
local M = {}

---Run `fn` as a coroutine. `cb(err, result)` gets fn's return value, or the message of the error
---it raised, exactly once and on the main loop. Raise with `error(msg, 0)` to keep positions out
---of user-facing messages.
---@param fn async fun(): any
---@param cb fun(err: string?, result: any)
function M.run(fn, cb)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, yielded = coroutine.resume(co, ...)
    if not ok then
      local err = type(yielded) == "string" and yielded or vim.inspect(yielded)
      vim.schedule(function()
        cb(err, nil)
      end)
    elseif coroutine.status(co) == "dead" then
      vim.schedule(function()
        cb(nil, yielded)
      end)
    else
      yielded(step)
    end
  end
  step()
end

---Inside `run`: call `fn(..., cb)` and wait for its `cb(err, result)`. Raises `err`.
---@async
---@param fn function
---@return any
function M.await(fn, ...)
  local result, err = M.attempt(fn, ...)
  if err ~= nil then
    error(err, 0)
  end
  return result
end

---Inside `run`: like `await`, but returns `nil, err` instead of raising. Use it instead of pcall,
---which can't be yielded across on PUC Lua 5.1.
---@async
---@param fn function
---@return any result
---@return string? err
function M.attempt(fn, ...)
  local args, n = { ... }, select("#", ...) ---@type any[], integer
  local err, result = coroutine.yield(function(resume)
    args[n + 1] = resume
    fn(unpack(args, 1, n + 1))
  end)
  if err ~= nil then
    return nil, err
  end
  return result
end

---Inside `run`: start every thunk at once and wait for them all. Returns their results in order;
---raises the first error.
---@async
---@param thunks (fun(cb: fun(err: string?, result: any)))[]
---@return any[]
function M.all(thunks)
  return M.await(function(cb)
    local results, remaining, failed = {}, #thunks, false ---@type any[], integer, boolean
    if remaining == 0 then
      return cb(nil, results)
    end
    for i, thunk in ipairs(thunks) do
      thunk(function(err, result)
        if failed then
          return
        end
        if err ~= nil then
          failed = true
          return cb(err)
        end
        results[i] = result
        remaining = remaining - 1
        if remaining == 0 then
          cb(nil, results)
        end
      end)
    end
  end)
end

return M
