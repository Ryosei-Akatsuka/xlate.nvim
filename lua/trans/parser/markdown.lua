---@mod trans.parser.markdown Meaningful block detection for Markdown
---
---Units are *semantic* blocks, not lines:
---
---* headings
---* paragraphs (wrapped lines are joined before translation)
---* list items (including their nested list)
---* block quotes
---
---Code blocks and other non-text constructs are never captured. A block that
---contains a code block is skipped as well, so code is never sent to the
---backend.

local M = {}

local UNIT_TYPES = {
  atx_heading = true,
  paragraph = true,
  list_item = true,
  block_quote = true,
}

local SKIP_IN_UNIT = {
  fenced_code_block = true,
  indented_code_block = true,
}

local QUERY = [[
[
  (atx_heading) @unit
  (paragraph) @unit
  (list_item) @unit
  (block_quote) @unit
]
]]

---@type vim.treesitter.Query|nil
local query = nil

---@return vim.treesitter.Query|nil
local function get_query()
  if query ~= nil then
    return query
  end
  local ok, q = pcall(vim.treesitter.query.parse, "markdown", QUERY)
  if not ok then
    return nil
  end
  query = q
  return query
end

---Does any ancestor of `node` belong to the unit set?
---@param node TSNode
---@return boolean
local function has_unit_ancestor(node)
  local parent = node:parent()
  while parent do
    if UNIT_TYPES[parent:type()] then
      return true
    end
    parent = parent:parent()
  end
  return false
end

---Does the subtree contain a code block?
---@param node TSNode
---@return boolean
local function contains_code(node)
  for child, _ in node:iter_children() do
    if SKIP_IN_UNIT[child:type()] or contains_code(child) then
      return true
    end
  end
  return false
end

---Split structural markers from one Markdown line.
---
---The marker is kept as the render prefix so the translation reads like the
---original block:
---
---```text
---  # Title    -> "# ",   "Title"
---  - item     -> "- ",   "item"
---  > quote    -> "> ",   "quote"
---```
---@param line string
---@param unit_type string
---@return string prefix, string body
local function split_markers(line, unit_type)
  if unit_type == "atx_heading" then
    return (line:match("^(%s*#+%s*)") or ""), (line:gsub("^%s*#+%s*", ""))
  end
  if unit_type == "block_quote" then
    return (line:match("^(%s*>%s?)") or ""), (line:gsub("^%s*>%s?", ""))
  end
  if unit_type == "list_item" then
    local prefix = line:match("^(%s*[-*+]%s+)")
    if prefix then
      return prefix, (line:gsub("^%s*[-*+]%s+", "", 1))
    end
    prefix = line:match("^(%s*%d+[%.%)]%s+)")
    if prefix then
      return prefix, (line:gsub("^%s*%d+[%.%)]%s+", "", 1))
    end
    return "", line
  end
  return "", line
end

---Compute the row the translation should be displayed below.
---Tree-sitter block nodes usually end at column 0 of the *next* line, and may
---trailing blank lines, so walk back to the last line with actual content.
---@param bufnr integer
---@param node TSNode
---@return integer
local function anchor_row(bufnr, node)
  local srow, _, erow, ecol = node:range()
  local row = erow
  if ecol == 0 and row > srow then
    row = row - 1
  end
  while row > srow do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    if line:match("%S") then
      break
    end
    row = row - 1
  end
  return row
end

---Detect translatable blocks in a Markdown buffer.
---@param bufnr integer
---@return trans.Unit[]|nil units nil on failure
---@return string|nil err
function M.detect(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if not ok or not parser then
    return nil, "no Tree-sitter parser for markdown"
  end
  local q = get_query()
  if not q then
    return nil, "markdown query could not be parsed"
  end
  local parse_ok, trees = pcall(parser.parse, parser)
  if not parse_ok or not trees then
    return nil, "Tree-sitter parse failed"
  end

  ---@type TSNode[]
  local nodes = {}
  for _, tree in ipairs(trees) do
    for _, node in q:iter_captures(tree:root(), bufnr) do
      nodes[#nodes + 1] = node
    end
  end
  table.sort(nodes, function(a, b)
    local asrow, ascol = a:range()
    local bsrow, bscol = b:range()
    if asrow ~= bsrow then
      return asrow < bsrow
    end
    return ascol < bscol
  end)

  local units = {} ---@type trans.Unit[]
  for _, node in ipairs(nodes) do
    if not has_unit_ancestor(node) and not contains_code(node) then
      local unit_type = node:type()
      local srow, scol, erow, ecol = node:range()
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      if erow >= line_count then
        erow = line_count - 1
        local last = vim.api.nvim_buf_get_lines(bufnr, erow, erow + 1, false)[1] or ""
        ecol = #last
      end
      local raw_lines = vim.api.nvim_buf_get_text(bufnr, srow, scol, erow, ecol, {})

      local parts = {} ---@type string[]
      local prefix = ""
      for _, raw in ipairs(raw_lines) do
        local marker, body = split_markers(raw, unit_type)
        body = vim.trim(body)
        if body ~= "" then
          if #parts == 0 then
            prefix = marker
          end
          parts[#parts + 1] = body
        end
      end

      if #parts > 0 then
        units[#units + 1] = {
          kind = "text",
          start_row = srow,
          end_row = anchor_row(bufnr, node),
          lines = {
            { row = srow, prefix = prefix, text = table.concat(parts, " ") },
          },
        }
      end
    end
  end

  return units
end

return M
