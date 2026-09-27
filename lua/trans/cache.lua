---@mod trans.cache Translation result cache
---
---Keys are generated from the source text (and target language) with SHA-256.
---Results are kept in memory and persisted to disk so that the same text is
---never sent to `trans` twice, even across sessions.

local M = {}

---@type table<string, string>
local memory = {}

---@type string|nil
local path = nil

local dirty = false

---Build a cache key for a piece of source text.
---@param text string source text
---@param lang string target language spec (e.g. "ja", "en:ja")
---@return string key
function M.key(text, lang)
  return vim.fn.sha256(lang .. "\0" .. text)
end

---@param key string
---@return string|nil
function M.get(key)
  return memory[key]
end

---@param key string
---@param value string
function M.set(key, value)
  if not value or value == "" then
    return
  end
  memory[key] = value
  dirty = true
end

---Number of cached entries.
---@return integer
function M.count()
  return vim.tbl_count(memory)
end

---Load the on-disk cache (best effort).
---@param file string|nil
function M.load(file)
  path = file
  if not path then
    return
  end
  local f = io.open(path, "r")
  if not f then
    return
  end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then
    return
  end
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" then
    for k, v in pairs(data) do
      if type(k) == "string" and type(v) == "string" then
        memory[k] = v
      end
    end
    dirty = false
  end
end

---Persist the cache to disk (best effort).
function M.save()
  if not dirty or not path then
    return
  end
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
  local f = io.open(path, "w")
  if not f then
    return
  end
  local ok = pcall(f.write, f, vim.json.encode(memory))
  f:close()
  if ok then
    dirty = false
  end
end

---Drop everything (used by :TransClear / tests).
function M.clear()
  memory = {}
  dirty = true
end

return M
