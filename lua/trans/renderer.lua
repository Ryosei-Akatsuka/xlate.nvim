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

local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace("trans.nvim")

---@class trans.RenderState
---@field highlight string
---@field ids table<integer, integer> unit index -> extmark id

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

---Draw (or redraw) one unit with whatever translations are available so far.
---
---Passing no translation yet removes the unit's marks again, so a partially
---filled unit always shows exactly the lines that are ready.
---@param bufnr integer
---@param unit_index integer position of the unit in the detection result
---@param unit trans.Unit
---@param translations (string|nil)[]
---@return boolean shown whether the unit is currently visible
function M.show(bufnr, unit_index, unit, translations)
  local state = states[bufnr]
  if not state or not api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local virt_lines = M.build_lines(unit, translations)
  local id = state.ids[unit_index]

  if #virt_lines == 0 then
    if id then
      pcall(api.nvim_buf_del_extmark, bufnr, M.ns, id)
      state.ids[unit_index] = nil
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

  -- Reusing `id` updates the existing extmark in place instead of
  -- creating a new one on every partial update.
  local ok, new_id = pcall(api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, {
    id = id,
    virt_lines = chunks,
    virt_lines_above = false,
    hl_mode = "combine",
  })
  if not ok then
    return false
  end
  state.ids[unit_index] = new_id
  return true
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
    if M.show(bufnr, i, entry.unit, entry.translations) then
      rendered = rendered + 1
    end
  end
  return rendered
end

return M
