---@mod trans.renderer Virtual text display (extmark + virt_lines)
---
---Translations are drawn with `virt_lines`, so they never enter the buffer:
---
---* saving the buffer does not write them out
---* yanks and edits never see them
---* clearing only drops extmarks
---
---Display is incremental: `begin()` prepares an empty rendering session and
---`show()` upserts the virtual lines of a single unit every time one more
---line is ready, so results appear one by one while the backend is still
---working. Each unit keeps a stable extmark id, so updates happen in place.
---
---Marks are tracked per *unit key* (`key()`), not per detection index, so one
---buffer can hold a full run (`:Trans`) next to individually translated
---blocks (`:TransHere`) and each of them stays hideable on its own.
---`find_in_range()` answers "is this block translated?" by looking at where
---the marks actually sit, which keeps working after the buffer was edited
---because extmarks move along with their text.

local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace("trans.nvim")

---@class trans.RenderState
---@field highlight string
---@field ids table<string, integer> unit key -> extmark id

---@type table<integer, trans.RenderState> bufnr -> state
local states = {}

---Turn a unit plus its translations into virtual lines.
---@param unit trans.Unit
---@param translations (string|nil)[]
---@return string[]
function M.build_lines(unit, translations)
  local out = {} ---@type string[]

  if unit.fence then
    -- Rebuild the comment block with the translated body.
    local texts = {} ---@type string[]
    for i = 1, #unit.lines do
      local tr = translations[i]
      if tr and tr ~= "" then
        texts[#texts + 1] = tr
      end
    end
    if #texts == 0 then
      return out
    end
    if unit.fence.single and #texts == 1 then
      out[1] = unit.fence.open .. texts[1] .. unit.fence.close
    else
      out[1] = unit.fence.open
      for _, tr in ipairs(texts) do
        out[#out + 1] = unit.fence.mid .. tr
      end
      out[#out + 1] = unit.fence.close
    end
    return out
  end

  for i, line in ipairs(unit.lines) do
    local tr = translations[i]
    if tr and tr ~= "" then
      out[#out + 1] = line.prefix .. tr
    end
  end
  return out
end

---Stable identity of a unit, used to tell its virtual lines apart from the
---other translations shown in the same buffer.
---
---The row is part of the key on purpose: two identical comments at different
---places are different units, and sharing one extmark between them would
---move the first translation down to the second one.
---@param unit trans.Unit
---@return string
function M.key(unit)
  local parts = { unit.kind, unit.start_row, unit.end_row }
  for _, line in ipairs(unit.lines) do
    parts[#parts + 1] = line.prefix .. "\1" .. line.text
  end
  return vim.fn.sha256(table.concat(parts, "\0"))
end

---Remove all translation marks from a buffer.
---@param bufnr integer
---@return boolean true when something was removed
function M.clear(bufnr)
  local state = states[bufnr]
  if not state then
    return false
  end
  states[bufnr] = nil
  if not api.nvim_buf_is_valid(bufnr) then
    return true
  end
  local removed = 0
  for _, id in pairs(state.ids) do
    if api.nvim_buf_del_extmark(bufnr, M.ns, id) then
      removed = removed + 1
    end
  end
  return removed > 0
end

---Start a rendering session for a buffer (drops any previous marks).
---@param bufnr integer
---@param opts { highlight: string }|nil
function M.begin(bufnr, opts)
  M.clear(bufnr)
  states[bufnr] = {
    highlight = (opts and opts.highlight) or "TransTranslated",
    ids = {},
  }
end

---Prepare a buffer for drawing single blocks, keeping what is already shown.
---
---Unlike `begin()` this never drops marks, so translated blocks that are not
---part of the current run stay visible.
---@param bufnr integer
---@param opts { highlight: string }|nil
function M.ensure(bufnr, opts)
  if not states[bufnr] then
    states[bufnr] = {
      highlight = (opts and opts.highlight) or "TransTranslated",
      ids = {},
    }
  end
end

---Draw (or redraw) one unit with whatever translations are available so far.
---
---Passing no translation yet removes the unit's marks again, so a partially
---filled unit always shows exactly the lines that are ready.
---@param bufnr integer
---@param key string identity of the unit in this buffer (see `key()`)
---@param unit trans.Unit
---@param translations (string|nil)[]
---@return boolean shown whether the unit is currently visible
function M.show(bufnr, key, unit, translations)
  local state = states[bufnr]
  if not state or not api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local virt_lines = M.build_lines(unit, translations)
  local id = state.ids[key]

  if #virt_lines == 0 then
    if id then
      pcall(api.nvim_buf_del_extmark, bufnr, M.ns, id)
      state.ids[key] = nil
    end
    return false
  end

  local chunks = {} ---@type string[][]
  for _, text in ipairs(virt_lines) do
    chunks[#chunks + 1] = { { text, state.highlight } }
  end

  local row = math.min(unit.end_row, api.nvim_buf_line_count(bufnr) - 1)
  if row < 0 then
    return false
  end

  -- Reusing `id` updates the existing extmark in place instead of creating a
  -- new one on every partial update. The left gravity is what keeps a mark on
  -- the line it was placed on: with the default gravity, rewriting that line
  -- would push the translation one row down and `find_in_range` (used by
  -- `:TransHere`) would lose track of it.
  local ok, new_id = pcall(api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, {
    id = id,
    virt_lines = chunks,
    virt_lines_above = false,
    right_gravity = false,
    hl_mode = "combine",
  })
  if not ok then
    return false
  end
  state.ids[key] = new_id
  return true
end

---Which translated block currently sits inside a row range?
---
---The mark positions are read back from Neovim instead of being remembered,
---so a translated block is still found after the buffer was edited (its
---extmark moved with the text). Only one unit ever anchors on the same row,
---so at most one key can be inside a range.
---@param bufnr integer
---@param start_row integer
---@param end_row integer
---@return string|nil key of the translated block, nil when the range is blank
function M.find_in_range(bufnr, start_row, end_row)
  local state = states[bufnr]
  if not state or not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local best ---@type string|nil
  local best_row = -1
  for key, id in pairs(state.ids) do
    local ok, mark = pcall(api.nvim_buf_get_extmark_by_id, bufnr, M.ns, id, {})
    local row = ok and mark and mark[1]
    if row and row >= start_row and row <= end_row and row >= best_row then
      best = key
      best_row = row
    end
  end
  return best
end

---Drop the translation of a single block, leaving the other ones alone.
---@param bufnr integer
---@param key string
---@return boolean true when a mark was removed
function M.hide(bufnr, key)
  local state = states[bufnr]
  if not state then
    return false
  end
  local id = state.ids[key]
  if not id then
    return false
  end
  state.ids[key] = nil
  if not api.nvim_buf_is_valid(bufnr) then
    return true
  end
  return api.nvim_buf_del_extmark(bufnr, M.ns, id)
end

---Drop translations whose block is gone, e.g. because the comment it
---belonged to was deleted.
---
---Marks follow their text, so a translation of a removed comment would
---otherwise keep floating over whatever code now occupies that row.
---@param bufnr integer
---@param units trans.Unit[] blocks that are still translatable
---@return integer removed
function M.prune(bufnr, units)
  local state = states[bufnr]
  if not state or not api.nvim_buf_is_valid(bufnr) then
    return 0
  end
  local removed = 0
  for key, id in pairs(state.ids) do
    local ok, mark = pcall(api.nvim_buf_get_extmark_by_id, bufnr, M.ns, id, {})
    local row = ok and mark and mark[1]
    local inside = false
    if row then
      for _, unit in ipairs(units) do
        if row >= unit.start_row and row <= unit.end_row then
          inside = true
          break
        end
      end
    end
    if not inside then
      if M.hide(bufnr, key) then
        removed = removed + 1
      end
    end
  end
  return removed
end

---How many units are currently visible?
---@param bufnr integer
---@return integer
function M.count(bufnr)
  local state = states[bufnr]
  return state and vim.tbl_count(state.ids) or 0
end

---Does the buffer currently show translations?
---@param bufnr integer
---@return boolean
function M.is_rendered(bufnr)
  return M.count(bufnr) > 0
end

---Forget bookkeeping for a buffer that is going away.
---@param bufnr integer
function M.forget(bufnr)
  states[bufnr] = nil
end

---Draw a complete set of translation results (convenience wrapper around
---`begin()` + `show()` for one-shot rendering).
---@param bufnr integer
---@param entries { unit: trans.Unit, translations: (string|nil)[] }[]
---@param opts { highlight: string }
---@return integer count of rendered blocks
function M.render(bufnr, entries, opts)
  M.begin(bufnr, opts)
  local rendered = 0
  for i, entry in ipairs(entries) do
    if M.show(bufnr, M.key(entry.unit), entry.unit, entry.translations) then
      rendered = rendered + 1
    end
  end
  return rendered
end

return M
