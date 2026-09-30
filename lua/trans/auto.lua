---@mod trans.auto Debounced automatic re-translation
---
---While translations are shown in a buffer, edits schedule a debounced
---re-translation so the virtual lines never go stale:
---
---* opt-in: only buffers the user translated at least once participate, and
---  only while `auto.enabled` is set in the config
---* `:TransClear` stops updates for that buffer again
---* one timer per buffer: a burst of edits collapses into a single run
---* unchanged buffers (undo back to the translated text) are skipped

local api = vim.api

local M = {}

---@type table<integer, true> bufnr -> automatic updates are on
local enabled = {}

---@type table<integer, uv.uv_timer_t> bufnr -> debounce timer
local timers = {}

---@type table<integer, string[]> bufnr -> text rendered by the last run
local last_text = {}

---@return trans.AutoConfig
local function auto_cfg()
  return require("trans").config.auto
end

---Is a debounced update waiting for this buffer?
---@param bufnr integer
---@return boolean
function M.is_pending(bufnr)
  local timer = timers[bufnr]
  return timer ~= nil and timer:is_active()
end

---How many debounce timers exist (diagnostics / tests).
---@return integer
function M.timer_count()
  return vim.tbl_count(timers)
end

---Turn automatic updates on (or off) for a buffer.
---
---Enabling is a no-op while `auto.enabled` is false in the config, so the
---plugin never starts backend calls on its own unless it was opted in.
---@param bufnr integer
---@param on boolean
function M.set_enabled(bufnr, on)
  if on then
    if not auto_cfg().enabled then
      return
    end
    enabled[bufnr] = true
  else
    enabled[bufnr] = nil
    M.cancel(bufnr)
  end
end

---Are automatic updates on for this buffer?
---@param bufnr integer
---@return boolean
function M.is_enabled(bufnr)
  return enabled[bufnr] == true
end

---Record the buffer text that the last completed run has rendered.
---@param bufnr integer
---@param lines string[]
function M.mark_updated(bufnr, lines)
  last_text[bufnr] = lines
end

---Run a scheduled update right away.
---
---Called by the debounce timer (and indirectly by `schedule`).
---@param bufnr integer
local function fire(bufnr)
  if not auto_cfg().enabled or not enabled[bufnr] then
    return
  end
  if not api.nvim_buf_is_valid(bufnr) or not api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local trans = require("trans")
  if trans.is_translating(bufnr) then
    -- The running translation sees the edit itself (the text snapshot no
    -- longer matches) and reschedules when it finishes; nothing to do here.
    return
  end

  local last = last_text[bufnr]
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if last and vim.deep_equal(lines, last) then
    -- e.g. undo back to the text that is already displayed.
    return
  end
  trans.translate(bufnr, { silent = true })
end

---Schedule a debounced re-translation of the buffer.
---
---Calling this repeatedly restarts the timer, so edits arriving faster than
---`auto.debounce` collapse into a single run. Never blocks.
---@param bufnr integer
---@return boolean scheduled false when automatic updates are off for this buffer
function M.schedule(bufnr)
  local cfg = auto_cfg()
  if not cfg.enabled or not enabled[bufnr] then
    return false
  end
  if not api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local timer = timers[bufnr]
  if not timer then
    timer = vim.uv.new_timer()
    timers[bufnr] = timer
  end
  timer:stop()
  timer:start(cfg.debounce, 0, vim.schedule_wrap(function()
    fire(bufnr)
  end))
  return true
end

---Stop a pending debounced update (the buffer keeps its state).
---@param bufnr integer
function M.cancel(bufnr)
  local timer = timers[bufnr]
  if timer then
    timer:stop()
  end
end

---Drop every trace of a buffer that is going away.
---@param bufnr integer
function M.forget(bufnr)
  enabled[bufnr] = nil
  last_text[bufnr] = nil
  local timer = timers[bufnr]
  if timer then
    -- Unhook first: a closed handle must never be looked up again.
    timers[bufnr] = nil
    timer:stop()
    timer:close()
  end
end

return M
