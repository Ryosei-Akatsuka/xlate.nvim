---@mod trans.renderer Virtual text display (extmark + virt_lines)
---
---Translations are drawn with `virt_lines`, so they never enter the buffer:
---
---* saving the buffer does not write them out
---* yanks and edits never see them
---* clearing only drops extmarks

local M = {}

M.ns = vim.api.nvim_create_namespace("trans.nvim")

---@type table<integer, integer[]> bufnr -> extmark ids
local marks = {}

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
  local ids = marks[bufnr]
  if not ids then
    return false
  end
  marks[bufnr] = nil
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return true
  end
  for _, id in ipairs(ids) do
    vim.api.nvim_buf_del_extmark(bufnr, M.ns, id)
  end
  return #ids > 0
end

---Does the buffer currently show translations?
---@param bufnr integer
---@return boolean
function M.is_rendered(bufnr)
  return marks[bufnr] ~= nil
end

---Forget bookkeeping for a buffer that is going away.
---@param bufnr integer
function M.forget(bufnr)
  marks[bufnr] = nil
end

---Draw translation results.
---@param bufnr integer
---@param entries { unit: trans.Unit, translations: (string|nil)[] }[]
---@param opts { highlight: string }
---@return integer count of rendered blocks
function M.render(bufnr, entries, opts)
  M.clear(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local ids = {} ---@type integer[]
  local rendered = 0

  for _, entry in ipairs(entries) do
    local virt_lines = M.build_lines(entry.unit, entry.translations)
    if #virt_lines > 0 then
      local row = math.min(entry.unit.end_row, line_count - 1)
      if row >= 0 then
        local chunks = {} ---@type string[][]
        for _, text in ipairs(virt_lines) do
          chunks[#chunks + 1] = { { text, opts.highlight } }
        end
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, {
          virt_lines = chunks,
          virt_lines_above = false,
          hl_mode = "combine",
        })
        if ok then
          ids[#ids + 1] = id
          rendered = rendered + 1
        end
      end
    end
  end

  if #ids > 0 then
    marks[bufnr] = ids
  end
  return rendered
end

return M
