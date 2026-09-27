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
  max_concurrency = 6,
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

---Translate the buffer and show the results as virtual lines.
---@param bufnr integer|nil default: current buffer
---@return boolean ok
function M.translate(bufnr)
  ensure_setup()
  bufnr = bufnr or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(bufnr) then
    notify("invalid buffer", vim.log.levels.ERROR)
    return false
  end

  local changedtick = api.nvim_buf_get_changedtick(bufnr)

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
  -- each unit starts so results can be mapped back later.
  local texts = {} ---@type string[]
  local spans = {} ---@type { [1]: integer, [2]: integer }[]
  for i, unit in ipairs(units) do
    local start = #texts + 1
    for _, line in ipairs(unit.lines) do
      texts[#texts + 1] = line.text
    end
    spans[i] = { start, #unit.lines }
  end

  require("trans.translator").translate_lines(texts, function(results, stats)
    if not api.nvim_buf_is_valid(bufnr) then
      return
    end
    if api.nvim_buf_get_changedtick(bufnr) ~= changedtick then
      -- The buffer changed while we were waiting for the backend; the
      -- detected units no longer line up, so drop the results instead of
      -- drawing them at the wrong place.
      notify("buffer changed during translation, results dropped", vim.log.levels.WARN)
      return
    end

    local entries = {} ---@type { unit: trans.Unit, translations: (string|nil)[] }[]
    for i, unit in ipairs(units) do
      local span = spans[i]
      local translations = {} ---@type (string|nil)[]
      for j = span[1], span[1] + span[2] - 1 do
        translations[j - span[1] + 1] = results[j]
      end
      entries[#entries + 1] = { unit = unit, translations = translations }
    end

    local renderer = require("trans.renderer")
    local rendered = renderer.render(bufnr, entries, { highlight = M.config.highlight })
    require("trans.cache").save()

    if M.config.notify then
      notify(("%d block(s) shown | %d translated, %d cached, %d failed"):format(
        rendered,
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
  end)

  return true
end

---Remove translations from a buffer.
---@param bufnr integer|nil
---@return boolean had_marks
function M.clear(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
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
