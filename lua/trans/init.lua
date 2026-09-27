---@mod trans Main entry point
---
---```text
---buffer -> parser (Tree-sitter) -> units -> translator (`trans`) -> renderer (virt_lines)
---```
---
---The buffer itself is never modified: results are only drawn as virtual
---lines, which cannot be saved, yanked or edited.

local api = vim.api

local M = {}

---@class trans.Config
---@field target string target language ("ja", "en:ja", ...)
---@field cmd string translation executable
---@field extra_args string[] extra arguments passed to `cmd`
---@field timeout integer ms per translation call
---@field max_concurrency integer parallel backend processes
---@field cache trans.CacheConfig
---@field highlight string highlight group for translated lines
---@field notify boolean show a summary notification after translation

---@class trans.CacheConfig
---@field enabled boolean
---@field path string|nil where the cache is persisted

M.defaults = {
  target = "ja",
  cmd = "trans",
  extra_args = { "-b", "-no-ansi" },
  timeout = 10000,
  -- Parallel `trans` processes. Measured on 16 lines (3 runs each):
  --   1x -> 12.2s, 2x -> 3.8s (3.2x), 4x -> 2.3s (5.4x),
  --   8x -> 1.6s (7.7x), 16x -> 1.5s (8.2x, no real gain)
  -- 2 is the default: best first-result latency (~300ms) while already
  -- cutting the wall time by ~3x.
  max_concurrency = 2,
  cache = {
    enabled = true,
    path = vim.fn.stdpath("cache") .. "/trans-nvim/cache.json",
  },
  highlight = "TransTranslated",
  notify = true,
}

---@type trans.Config
M.config = vim.deepcopy(M.defaults)

local setup_done = false

---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if opts.extra_args then
    -- Lists must be replaced, not merged index by index.
    M.config.extra_args = opts.extra_args
  end

  local cache = require("trans.cache")
  if M.config.cache.enabled then
    cache.load(M.config.cache.path)
  else
    cache.load(nil)
  end

  require("trans.translator").setup({
    cmd = M.config.cmd,
    target = M.config.target,
    extra_args = M.config.extra_args,
    timeout = M.config.timeout,
    max_concurrency = M.config.max_concurrency,
    use_cache = M.config.cache.enabled,
  })

  vim.api.nvim_set_hl(0, M.config.highlight, { default = true, link = "Comment" })

  local group = api.nvim_create_augroup("trans-nvim", { clear = true })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("trans.cache").save()
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      require("trans.renderer").forget(args.buf)
    end,
  })

  setup_done = true
end

local function ensure_setup()
  if not setup_done then
    M.setup({})
  end
end

---@param msg string
---@param level integer|nil
local function notify(msg, level)
  vim.notify("trans-nvim: " .. msg, level or vim.log.levels.INFO)
end

---@type table<integer, true> bufnr -> a translation run is active
local inflight = {}

---@type table<integer, true> bufnr -> user asked to stop the active run
local cancel_requested = {}

---Translate the buffer and show the results as virtual lines.
---
---Non-blocking: the backend is called asynchronously and every line is drawn
---as soon as it is ready, so the editor stays usable and the translation
---"streams in" progressively.
---@param bufnr integer|nil default: current buffer
---@return boolean ok
function M.translate(bufnr)
  ensure_setup()
  bufnr = bufnr or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(bufnr) then
    notify("invalid buffer", vim.log.levels.ERROR)
    return false
  end
  if inflight[bufnr] then
    notify("translation already in progress")
    return false
  end

  local changedtick = api.nvim_buf_get_changedtick(bufnr)
  -- Snapshot of the buffer text: `changedtick` also moves on a plain `:write`,
  -- so only a real text change may invalidate the detected rows.
  local snapshot = api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local units, err = require("trans.parser").detect(bufnr)
  if not units then
    notify(err or "detection failed", vim.log.levels.WARN)
    return false
  end
  if #units == 0 then
    if M.config.notify then
      notify("nothing to translate")
    end
    return true
  end

  -- Flatten the units into a single list of source lines, remembering where
  -- each unit starts so results can be mapped back as they arrive.
  local texts = {} ---@type string[]
  local spans = {} ---@type { [1]: integer, [2]: integer }[]
  local index_to_unit = {} ---@type table<integer, integer>
  local unit_trans = {} ---@type table<integer, (string|nil)[]>
  for i, unit in ipairs(units) do
    local start = #texts + 1
    for _, line in ipairs(unit.lines) do
      texts[#texts + 1] = line.text
      index_to_unit[#texts] = i
    end
    spans[i] = { start, #unit.lines }
    unit_trans[i] = {}
  end

  local renderer = require("trans.renderer")

  ---Has the buffer changedtick moved (rows might be stale)?
  local function tick_changed()
    return not api.nvim_buf_is_valid(bufnr)
      or api.nvim_buf_get_changedtick(bufnr) ~= changedtick
  end

  ---Did the *text* really change? A plain `:write` bumps the changedtick but
  ---keeps every row in place, so such a run must not be discarded.
  local function text_changed()
    return not api.nvim_buf_is_valid(bufnr)
      or not vim.deep_equal(api.nvim_buf_get_lines(bufnr, 0, -1, false), snapshot)
  end

  local function cancelled()
    return cancel_requested[bufnr] == true
  end

  cancel_requested[bufnr] = nil
  inflight[bufnr] = true
  renderer.begin(bufnr, { highlight = M.config.highlight })

  require("trans.translator").translate_lines(texts, {
    -- Only an explicit cancel (or a gone buffer) stops launching backend
    -- calls; everything else is reconciled when the run finishes.
    should_stop = function()
      return cancelled() or not api.nvim_buf_is_valid(bufnr)
    end,

    -- Called per line: draw this unit again with everything ready so far.
    on_result = function(index, text)
      if not text or cancelled() then
        return
      end
      local unit_index = index_to_unit[index]
      local span = spans[unit_index]
      -- Always keep the result, even when it cannot be drawn right now.
      unit_trans[unit_index][index - span[1] + 1] = text
      if tick_changed() then
        -- Rows may be stale right now; the final pass below re-renders once
        -- we know the text is still intact.
        return
      end
      renderer.show(bufnr, unit_index, units[unit_index], unit_trans[unit_index])
    end,

    -- Called exactly once, when everything is ready or the run was stopped.
    on_done = function(_, stats)
      inflight[bufnr] = nil
      local was_cancelled = cancelled()
      cancel_requested[bufnr] = nil

      if not api.nvim_buf_is_valid(bufnr) then
        renderer.forget(bufnr)
        return
      end
      if was_cancelled then
        renderer.clear(bufnr)
        return
      end
      if text_changed() then
        renderer.clear(bufnr)
        notify("buffer changed during translation, results dropped", vim.log.levels.WARN)
        return
      end

      -- Final pass: make sure every unit reflects the complete result set
      -- (units whose lines all failed simply stay hidden).
      for i, unit in ipairs(units) do
        renderer.show(bufnr, i, unit, unit_trans[i])
      end
      require("trans.cache").save()

      if M.config.notify then
        notify(("%d block(s) shown | %d translated, %d cached, %d failed"):format(
          renderer.count(bufnr),
          stats.translated,
          stats.cached,
          stats.failed
        ))
      end
      if stats.failed > 0 then
        notify(
          ("%d line(s) could not be translated via %q"):format(stats.failed, M.config.cmd),
          vim.log.levels.WARN
        )
      end
    end,
  })

  return true
end

---Is a translation run still active for this buffer?
---@param bufnr integer|nil
---@return boolean
function M.is_translating(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  return inflight[bufnr] == true
end

---Remove translations from a buffer.
---
---When a translation run is still active it is cancelled as well, so results
---cannot reappear after the user cleared them.
---@param bufnr integer|nil
---@return boolean had_marks
function M.clear(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if inflight[bufnr] then
    cancel_requested[bufnr] = true
  end
  return require("trans.renderer").clear(bufnr)
end

---Translate the buffer, or clear it when translations are already shown.
---@param bufnr integer|nil
function M.toggle(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if require("trans.renderer").is_rendered(bufnr) then
    M.clear(bufnr)
  else
    M.translate(bufnr)
  end
end

return M
