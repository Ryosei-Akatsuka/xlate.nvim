---@mod trans.parser Detection of translatable units
---
---Filetype-specific analysis lives in `trans.parser.*` and is chosen here.
---Detection only *finds* units; it never translates and never renders.

local M = {}

---@class trans.Parser
---@field detect fun(bufnr: integer): trans.Unit[]|nil, string|nil

---filetype -> parser module
---@type table<string, string>
local registry = {
  markdown = "trans.parser.markdown",
}

---@type table<string, trans.Parser>
local loaded = {}

---@param name string
---@return trans.Parser|nil
local function get(name)
  if loaded[name] then
    return loaded[name]
  end
  local ok, mod = pcall(require, name)
  if not ok or type(mod) ~= "table" or type(mod.detect) ~= "function" then
    return nil
  end
  loaded[name] = mod
  return mod
end

---Detect translatable units in a buffer.
---@param bufnr integer
---@return trans.Unit[]|nil units nil on failure
---@return string|nil err
function M.detect(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then
    return nil, "no filetype"
  end

  local parser_name = registry[ft]
  if parser_name then
    local parser = get(parser_name)
    if parser then
      return parser.detect(bufnr)
    end
  end

  -- Default: code comment detection through Tree-sitter.
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local parser = get("trans.parser.code")
  if not parser then
    return nil, "parser module missing"
  end
  return parser.detect(bufnr, lang)
end

return M
