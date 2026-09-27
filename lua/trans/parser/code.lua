---@mod trans.parser.code Comment detection for source code (Tree-sitter)
---
---Pipeline:
---
---```text
---buffer -> Tree-sitter -> comment nodes -> comment blocks (units)
---```
---
---A *unit* is the smallest thing we translate:
---
---* consecutive standalone `//` comments form one "line" unit
---* a `/* ... */` comment is one "block" unit, translated line by line
---
---Units carry everything the renderer needs (indentation, comment markers,
---anchor row), so detection stays independent from translation and display.

local M = {}

---@class trans.UnitLine
---@field row integer 0-indexed buffer row of the original line
---@field prefix string text kept verbatim in front of the translation (e.g. "// ")
---@field text string actual content to translate

---@class trans.Unit
---@field kind "line"|"block"
---@field start_row integer
---@field end_row integer anchor row: the translation is shown below this row
---@field lines trans.UnitLine[]
---@field fence { open: string, mid: string, close: string, single: boolean }|nil

---@type table<string, vim.treesitter.Query>
local query_cache = {}

---Get (and cache) a query that only captures comment nodes.
---@param lang string tree-sitter language
---@return vim.treesitter.Query|nil
local function get_query(lang)
  if query_cache[lang] then
    return query_cache[lang]
  end
  local ok, query = pcall(vim.treesitter.query.parse, lang, "(comment) @comment")
  if not ok or not query then
    return nil
  end
  query_cache[lang] = query
  return query
end

---Raw text of a node, split per line. The end position is clamped to the
---buffer because Tree-sitter nodes may end at column 0 of a virtual line
---past the end of the buffer.
---@param bufnr integer
---@param node TSNode
---@return integer srow, integer scol, integer erow, integer ecol, string[] lines
local function node_text(bufnr, node)
  local srow, scol, erow, ecol = node:range()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if erow >= line_count then
    erow = line_count - 1
    local last = vim.api.nvim_buf_get_lines(bufnr, erow, erow + 1, false)[1] or ""
    ecol = #last
  end
  local lines = vim.api.nvim_buf_get_text(bufnr, srow, scol, erow, ecol, {})
  return srow, scol, erow, ecol, lines
end

---Split one physical comment line into (prefix, content).
---
---```text
---  // hello        -> "  // ",  "hello"
---  * i am god      -> "  * ",   "i am god"
---  /* hi */        -> "  /* ",  "hi"
---  */              -> "  ",     ""   (structural line, skipped)
---```
---@param raw string
---@param strip_close boolean drop a trailing "*/" (block comments only)
---@return string prefix, string content
local function split_line(raw, strip_close)
  local indent = raw:match("^(%s*)") or ""
  local rest = raw:sub(#indent + 1)

  if strip_close then
    -- Drop a trailing block-comment closer ("hello */" -> "hello").
    rest = rest:gsub("%s*%*/%s*$", "")
  end

  local marker, spacing, body = rest:match("^(%p+)(%s*)(.*)$")
  if marker then
    body = vim.trim(body)
    if body == "" then
      return indent, ""
    end
    -- Keep the original spacing after the marker, add one if it was missing
    -- ("//hello" -> "// hello").
    local sep = spacing ~= "" and spacing or " "
    return indent .. marker .. sep, body
  end

  -- No marker at all (unusual comment body): keep the indent only.
  local plain = vim.trim(rest)
  if plain == "" then
    return indent, ""
  end
  return indent, plain
end

---Is only whitespace present before the comment on this line?
---@param bufnr integer
---@param row integer
---@param col integer byte column where the comment starts
---@return boolean
local function is_standalone(bufnr, row, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return false
  end
  return line:sub(1, col):match("^%s*$") ~= nil
end

---Is this a C-style block comment ("/* ... */")?
---
---Everything else (`//`, `#`, `--`, ...) renders line by line using the
---original markers, only block comments are rebuilt with a fence.
---@param bufnr integer
---@param node TSNode
---@return boolean
local function is_block_comment(bufnr, node)
  local srow, scol = node:range()
  local line = vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1]
  if not line then
    return false
  end
  return line:sub(scol + 1):match("^/%*") ~= nil
end

---Append the translatable lines of a node to a unit.
---@param bufnr integer
---@param node TSNode
---@param unit trans.Unit
---@param strip_close boolean whether the node may end with a "*/" closer
local function fill_unit(bufnr, node, unit, strip_close)
  local srow, _, _, _, raw_lines = node_text(bufnr, node)
  for offset, raw in ipairs(raw_lines) do
    local row = srow + offset - 1
    local full = raw
    if offset == 1 then
      -- Node text starts at the comment itself, so re-attach the indentation
      -- of the line to be able to mirror it in the rendered translation.
      local buf_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      local indent = buf_line:match("^(%s*)") or ""
      full = indent .. raw
    end
    local prefix, content = split_line(full, strip_close)
    if content ~= "" then
      unit.lines[#unit.lines + 1] = {
        row = row,
        prefix = prefix,
        text = content,
      }
    end
  end
end

---Build a fence describing how to re-open/close a block comment for display.
---
---The opener/closer of a single-line block sit on the *same* rendered line, so
---only the opener carries the indentation.
---@param unit trans.Unit
---@param first_raw string
local function build_fence(unit, first_raw)
  local indent = first_raw:match("^(%s*)") or ""
  local single = unit.start_row == unit.end_row
  if single then
    unit.fence = {
      open = indent .. "/* ",
      mid = indent .. " * ",
      close = " */",
      single = true,
    }
  else
    unit.fence = {
      open = indent .. "/*",
      mid = indent .. " * ",
      close = indent .. " */",
      single = false,
    }
  end
end

---Detect comment units in a buffer.
---@param bufnr integer
---@param lang string tree-sitter language (e.g. "c", "cpp", "rust")
---@return trans.Unit[]|nil units nil on failure
---@return string|nil err
function M.detect(bufnr, lang)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then
    return nil, ("no Tree-sitter parser for %q"):format(lang)
  end
  local query = get_query(lang)
  if not query then
    return nil, ("%q has no `comment` node"):format(lang)
  end

  ---@type TSNode[]
  local nodes = {}
  local parse_ok, trees = pcall(parser.parse, parser)
  if not parse_ok or not trees then
    return nil, "Tree-sitter parse failed"
  end
  for _, tree in ipairs(trees) do
    local root = tree:root()
    for _, node in query:iter_captures(root, bufnr) do
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

  ---@type { kind: "line"|"block", nodes: TSNode[], start_row: integer, end_row: integer, standalone: boolean }[]
  local groups = {}
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for _, node in ipairs(nodes) do
    local srow, scol, erow = node:range()
    erow = math.min(erow, line_count - 1)
    local kind = is_block_comment(bufnr, node) and "block" or "line"
    local standalone = is_standalone(bufnr, srow, scol)
    local prev = groups[#groups]
    if
      prev
      and prev.kind == "line"
      and kind == "line"
      and prev.standalone
      and standalone
      and prev.end_row + 1 == srow
    then
      prev.nodes[#prev.nodes + 1] = node
      prev.end_row = erow
    else
      groups[#groups + 1] = {
        kind = kind,
        nodes = { node },
        start_row = srow,
        end_row = erow,
        standalone = standalone,
      }
    end
  end

  local units = {} ---@type trans.Unit[]
  for _, group in ipairs(groups) do
    local unit = {
      kind = group.kind,
      start_row = group.start_row,
      end_row = group.end_row,
      lines = {},
    }
    for _, node in ipairs(group.nodes) do
      fill_unit(bufnr, node, unit, group.kind == "block")
    end
    if #unit.lines > 0 then
      if group.kind == "block" then
        local first_raw =
          vim.api.nvim_buf_get_lines(bufnr, unit.start_row, unit.start_row + 1, false)[1] or ""
        build_fence(unit, first_raw)
      end
      units[#units + 1] = unit
    end
  end

  return units
end

return M
