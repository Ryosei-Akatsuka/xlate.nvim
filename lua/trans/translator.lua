---@mod trans.translator Backend adapter (translate-shell)
---
---All interaction with the `trans` CLI lives here. The rest of the plugin only
---sees `translate_lines()`, so the backend can be swapped out later.

local cache = require("trans.cache")

local M = {}

---@class trans.TranslatorConfig
---@field cmd string executable used for translation
---@field target string target language spec passed to `trans` (":ja", "en:ja", ...)
---@field extra_args string[] extra CLI arguments
---@field timeout integer milliseconds before a `trans` call is killed
---@field max_concurrency integer maximum number of parallel `trans` processes
---@field use_cache boolean

---@type trans.TranslatorConfig
local config = {
  cmd = "trans",
  target = ":ja",
  extra_args = { "-b", "-no-ansi" },
  timeout = 10000,
  -- Kept in sync with trans.Config.default (see trans.init): 2 parallel
  -- processes gave the best first-result latency in our benchmark.
  max_concurrency = 2,
  use_cache = true,
}

---@param opts table
function M.setup(opts)
  opts = opts or {}
  local extra_args = opts.extra_args
  config = vim.tbl_deep_extend("force", config, opts)
  if extra_args then
    -- Lists must be replaced, not merged index by index.
    config.extra_args = extra_args
  end
end

---Current backend configuration (handy for introspection and tests).
---@return trans.TranslatorConfig
function M.get_config()
  return config
end

---Normalise the user facing target ("ja") into a `trans` language spec (":ja").
---@param target string
---@return string
local function lang_spec(target)
  if target:find(":", 1, true) then
    return target
  end
  return ":" .. target
end

---Run a single `trans` invocation, reading the source text from stdin so that
---no shell escaping / argument injection can happen.
---@param text string
---@param cb fun(result: string|nil)
local function run(text, cb)
  local args = { config.cmd }
  vim.list_extend(args, config.extra_args)
  table.insert(args, lang_spec(config.target))

  local ok = pcall(vim.system, args, {
    stdin = text,
    timeout = config.timeout,
    text = true,
  }, function(out)
    local result
    if out.code == 0 and type(out.stdout) == "string" then
      result = vim.trim(out.stdout)
      if result == "" then
        result = nil
      end
    end
    -- vim.system callbacks may run in a fast event context.
    vim.schedule(function()
      cb(result)
    end)
  end)

  if not ok then
    vim.schedule(function()
      cb(nil)
    end)
  end
end

---@class trans.TranslateHandlers
---@field on_result? fun(index: integer, text: string|nil, from_cache: boolean)
---  Called as soon as *one* line is ready (cache hit or backend reply), so
---  callers can display partial results immediately.
---@field on_done? fun(results: string[], stats: trans.TranslateStats, cancelled: boolean)
---  Called exactly once when everything finished or the run was cancelled.
---@field should_stop? fun(): boolean
---  Polled before every new backend call and before every `on_result`, so a
---  cancel stops launching further work.

---@class trans.TranslateStats
---@field cached integer
---@field translated integer
---@field failed integer

---Translate a list of source lines, streaming results as they arrive.
---
---This never blocks the caller: work is dispatched asynchronously (at most
---`max_concurrency` parallel processes) and each completion is reported
---through `on_result` individually. Cached lines are reported synchronously
---before the function returns.
---@param lines string[]
---@param handlers trans.TranslateHandlers
function M.translate_lines(lines, handlers)
  handlers = handlers or {}
  local on_result = handlers.on_result
  local on_done = handlers.on_done
  local should_stop = handlers.should_stop or function()
    return false
  end

  local results = {} ---@type string[]
  local stats = { cached = 0, translated = 0, failed = 0 }
  local stopped = false
  local finished_jobs = 0
  local done = false

  local function finish(cancelled)
    if done then
      return
    end
    done = true
    if on_done then
      on_done(results, stats, cancelled)
    end
  end

  ---@return boolean
  local function stop_requested()
    if stopped then
      return true
    end
    if should_stop() then
      stopped = true
      return true
    end
    return false
  end

  local function report(index, text, from_cache)
    if on_result and not stopped then
      on_result(index, text, from_cache)
    end
  end

  ---@type { [1]: integer, [2]: string }[]
  local queue = {}
  for i, line in ipairs(lines) do
    local key = cache.key(line, lang_spec(config.target))
    local hit = config.use_cache and cache.get(key) or nil
    if hit then
      results[i] = hit
      stats.cached = stats.cached + 1
      report(i, hit, true)
    else
      queue[#queue + 1] = { i, key }
    end
  end

  local total = #queue
  if total == 0 then
    finish(false)
    return
  end
  if stop_requested() then
    finish(true)
    return
  end

  local running = 0
  local next_job = 1

  local pump ---@type fun()

  pump = function()
    if done or stopped then
      return
    end
    while running < (config.max_concurrency or 1) and next_job <= total do
      if stop_requested() then
        finish(true)
        return
      end

      local job = queue[next_job]
      next_job = next_job + 1
      running = running + 1

      local index, key = job[1], job[2]
      run(lines[index], function(result)
        running = running - 1
        if done then
          return
        end
        finished_jobs = finished_jobs + 1
        if result then
          results[index] = result
          stats.translated = stats.translated + 1
          if config.use_cache then
            cache.set(key, result)
          end
        else
          stats.failed = stats.failed + 1
        end

        if stop_requested() then
          finish(true)
          return
        end
        report(index, result, false)

        pump()
        if finished_jobs >= total then
          finish(false)
        end
      end)
    end
    if finished_jobs >= total then
      finish(false)
    end
  end

  pump()
end

return M
