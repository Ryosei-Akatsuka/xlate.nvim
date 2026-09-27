-- Test suite for trans-nvim. Run with:
--   nvim --headless -u NONE -c "luafile tests/run.lua" -c "qa!"

vim.opt.rtp:prepend(vim.fn.getcwd())

local failures = 0
local checks = 0

local function eq(got, want, label)
  checks = checks + 1
  local g = vim.inspect(got)
  local w = vim.inspect(want)
  if g ~= w then
    failures = failures + 1
    print(("FAIL %s\n  want: %s\n  got : %s"):format(label, w, g))
  end
end

local function deq(got, want, label)
  checks = checks + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(("FAIL %s\n  want: %s\n  got : %s"):format(label, vim.inspect(want), vim.inspect(got)))
  end
end

local function ok(cond, label)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

----------------------------------------------------------------------------
-- plugin entry point
----------------------------------------------------------------------------
vim.cmd("runtime plugin/trans.lua")
eq(vim.fn.exists(":Trans"), 2, ":Trans command defined")
eq(vim.fn.exists(":TransClear"), 2, ":TransClear command defined")
eq(vim.fn.exists(":TransToggle"), 2, ":TransToggle command defined")
ok(vim.g.loaded_trans_nvim == 1, "plugin guard flag")

----------------------------------------------------------------------------
-- cache
----------------------------------------------------------------------------
local cache = require("trans.cache")
local key1 = cache.key("hello", ":ja")
eq(cache.key("hello", ":ja"), key1, "cache key is stable")
ok(cache.key("hello", ":en") ~= key1, "cache key includes language")
ok(cache.key("bye", ":ja") ~= key1, "cache key includes text")
cache.set(key1, "こんにちは")
eq(cache.get(key1), "こんにちは", "cache set/get")
cache.clear()
eq(cache.get(key1), nil, "cache clear")

----------------------------------------------------------------------------
-- C/C++ comment detection
----------------------------------------------------------------------------
local c_lines = {
  "int main() {",
  "  // hello",
  "  // i am god",
  "  /*",
  "   * hello",
  "   * i am god",
  "   */",
  "  int x; // trailing comment",
  "  return 0;",
  "}",
}
local c_buf = make_buf(c_lines, "c")
local units, err = require("trans.parser").detect(c_buf)
ok(units ~= nil, "c detection returns units (" .. tostring(err) .. ")")
eq(units and #units, 3, "c unit count")

if units and #units == 3 then
  local u1 = units[1]
  eq(u1.kind, "line", "u1 kind")
  deq({ u1.start_row, u1.end_row }, { 1, 2 }, "u1 range")
  eq(#u1.lines, 2, "u1 line count")
  deq(u1.lines[1], { row = 1, prefix = "  // ", text = "hello" }, "u1 line 1")
  deq(u1.lines[2], { row = 2, prefix = "  // ", text = "i am god" }, "u1 line 2")
  eq(u1.fence, nil, "u1 has no fence")

  local u2 = units[2]
  eq(u2.kind, "block", "u2 kind")
  deq({ u2.start_row, u2.end_row }, { 3, 6 }, "u2 range")
  eq(#u2.lines, 2, "u2 content lines (markers stripped)")
  deq(u2.lines[1], { row = 4, prefix = "   * ", text = "hello" }, "u2 line 1")
  deq(u2.lines[2], { row = 5, prefix = "   * ", text = "i am god" }, "u2 line 2")
  deq(u2.fence, { open = "  /*", mid = "   * ", close = "   */", single = false }, "u2 fence")

  local u3 = units[3]
  eq(u3.kind, "line", "u3 kind (trailing comment is its own unit)")
  deq({ u3.start_row, u3.end_row }, { 7, 7 }, "u3 range")
  eq(u3.lines[1].text, "trailing comment", "u3 content")
  eq(u3.lines[1].prefix, "  // ", "u3 prefix")
end

----------------------------------------------------------------------------
-- rendering (pure, no backend)
----------------------------------------------------------------------------
local renderer = require("trans.renderer")

if units and #units == 3 then
  deq(
    renderer.build_lines(units[1], { "こんにちは", "私は神です" }),
    { "  // こんにちは", "  // 私は神です" },
    "render line group"
  )
  deq(
    renderer.build_lines(units[2], { "こんにちは", "私は神です" }),
    { "  /*", "   * こんにちは", "   * 私は神です", "   */" },
    "render block comment"
  )
  deq(
    renderer.build_lines(units[2], { "こんにちは" }),
    { "  /*", "   * こんにちは", "   */" },
    "render block comment with one line"
  )
  deq(
    renderer.build_lines(units[3], { "コメントです" }),
    { "  // コメントです" },
    "render trailing comment"
  )
  deq(renderer.build_lines(units[1], { nil, nil }), {}, "failed translations render nothing")
end

-- single-line block comment
local one_line_block = make_buf({ "int x; /* foo */" }, "c")
local ub = require("trans.parser").detect(one_line_block)
ok(ub ~= nil and #ub == 1, "single-line block detected")
if ub and #ub == 1 then
  eq(ub[1].fence.single, true, "single-line block fence")
  deq(renderer.build_lines(ub[1], { "フォー" }), { "/* フォー */" }, "single-line block render")
end

-- indented single-line block comment keeps its indentation (no doubling)
local ind_block = make_buf({ "  int x; /* foo */" }, "c")
local iu = require("trans.parser").detect(ind_block)
ok(iu ~= nil and #iu == 1, "indented single-line block detected")
if iu and #iu == 1 then
  deq(iu[1].fence, { open = "  /* ", mid = "   * ", close = " */", single = true }, "indented fence")
  deq(renderer.build_lines(iu[1], { "フォー" }), { "  /* フォー */" }, "indented block render")
end

-- C++ parser availability
local cpp_buf = make_buf({ "// hello from cpp" }, "cpp")
local cu, cerr = require("trans.parser").detect(cpp_buf)
ok(cu ~= nil and #cu == 1, "cpp detection (" .. tostring(cerr) .. ")")

-- other languages reuse the code parser with their own comment markers
local py_buf = make_buf({ "# hello python", "# second line", "x = 1  # inline" }, "python")
local pu, perr = require("trans.parser").detect(py_buf)
ok(pu ~= nil and #pu == 2, "python detection (" .. tostring(perr) .. ")")
if pu and #pu == 2 then
  eq(pu[1].kind, "line", "python comments are line units")
  eq(#pu[1].lines, 2, "python comment group")
  eq(pu[1].lines[1].text, "hello python", "python line 1")
  eq(pu[1].lines[1].prefix, "# ", "python prefix")
  deq(renderer.build_lines(pu[1], { "こんにちは", "二行目" }), { "# こんにちは", "# 二行目" }, "python render")
  eq(pu[2].lines[1].text, "inline", "python inline comment")
end

----------------------------------------------------------------------------
-- Markdown detection
----------------------------------------------------------------------------
local md_lines = {
  "# Title",
  "",
  "This is a paragraph",
  "wrapped over two lines.",
  "",
  "- first item",
  "- second item",
  "  - nested item",
  "",
  "> quoted text",
  "",
  "```lua",
  "local x = 1 -- no translate",
  "```",
  "",
  "Last paragraph.",
}
local md_buf = make_buf(md_lines, "markdown")
local md_units, md_err = require("trans.parser").detect(md_buf)
ok(md_units ~= nil, "markdown detection (" .. tostring(md_err) .. ")")

if md_units then
  eq(#md_units, 6, "markdown unit count")
  eq(md_units[1].lines[1].text, "Title", "heading text")
  eq(md_units[1].lines[1].prefix, "# ", "heading marker kept as prefix")
  eq(md_units[1].end_row, 0, "heading anchor")
  eq(md_units[2].lines[1].text, "This is a paragraph wrapped over two lines.", "paragraph joined")
  eq(md_units[2].lines[1].prefix, "", "paragraph has no marker")
  deq({ md_units[2].start_row, md_units[2].end_row }, { 2, 3 }, "paragraph anchor")
  eq(md_units[3].lines[1].text, "first item", "list item 1")
  eq(md_units[3].lines[1].prefix, "- ", "list marker kept as prefix")
  eq(md_units[4].lines[1].text, "second item nested item", "list item 2 (nested folded in)")
  eq(md_units[4].end_row, 7, "list item anchor skips trailing blank line")
  eq(md_units[5].lines[1].text, "quoted text", "block quote")
  eq(md_units[5].lines[1].prefix, "> ", "quote marker kept as prefix")
  eq(md_units[6].lines[1].text, "Last paragraph.", "last paragraph")
  for _, u in ipairs(md_units) do
    ok(not u.lines[1].text:find("no translate"), "code block content excluded")
  end
end

----------------------------------------------------------------------------
-- unknown filetype
----------------------------------------------------------------------------
local no_ft = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(no_ft, 0, -1, false, { "hello" })
local n_units, n_err = require("trans.parser").detect(no_ft)
eq(n_units, nil, "no filetype -> error")
ok(n_err ~= nil, "error message present")

----------------------------------------------------------------------------
-- end-to-end with the real backend
----------------------------------------------------------------------------
local trans = require("trans")
local tmp_cache = vim.fn.tempname() .. ".json"
trans.setup({
  target = "ja",
  cache = { enabled = true, path = tmp_cache },
  notify = true,
})

-- configuration plumbing
local tcfg = require("trans.translator").get_config()
eq(tcfg.target, "ja", "target forwarded to backend")
deq(tcfg.extra_args, { "-b", "-no-ansi" }, "default extra args")
eq(tcfg.max_concurrency, 2, "default parallelism is 2")
eq(trans.config.max_concurrency, 2, "default parallelism visible in config")

trans.setup({ extra_args = { "-b" }, cache = { enabled = false } })
deq(require("trans.translator").get_config().extra_args, { "-b" }, "extra args are replaced")

trans.setup({ max_concurrency = 5, cache = { enabled = false } })
eq(require("trans.translator").get_config().max_concurrency, 5, "parallelism is configurable")
eq(trans.config.max_concurrency, 5, "parallelism kept in config")

trans.setup({ target = "ja", cache = { enabled = true, path = tmp_cache }, notify = true })
eq(require("trans.translator").get_config().max_concurrency, 2, "parallelism restored to default")

local notifications = {}
vim.notify = function(msg)
  notifications[#notifications + 1] = tostring(msg)
end

local e2e_file = vim.fn.tempname() .. ".c"
local e2e_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(e2e_buf, e2e_file)
vim.api.nvim_buf_set_lines(e2e_buf, 0, -1, false, {
  "// hello",
  "// i am god",
  "int main() {",
  "  return 0;",
  "}",
})
vim.bo[e2e_buf].filetype = "c"
local before = vim.api.nvim_buf_get_lines(e2e_buf, 0, -1, false)

ok(trans.translate(e2e_buf), "translate() starts")

local done = vim.wait(30000, function()
  return not trans.is_translating(e2e_buf)
end, 50)
ok(done, "translation finished in time")
ok(require("trans.renderer").is_rendered(e2e_buf), "translation rendered")

local after = vim.api.nvim_buf_get_lines(e2e_buf, 0, -1, false)
eq(after, before, "buffer content is untouched")

local ns = require("trans.renderer").ns
local marks = vim.api.nvim_buf_get_extmarks(e2e_buf, ns, 0, -1, { details = true })
eq(#marks, 1, "one extmark for one unit")
if #marks == 1 then
  local details = marks[1][4]
  ok(details.virt_lines ~= nil, "extmark has virt_lines")
  local shown = {}
  for _, chunk in ipairs(details.virt_lines or {}) do
    shown[#shown + 1] = chunk[1][1]
  end
  eq(shown, { "// こんにちは", "// 私は神です" }, "translated virtual lines")
  eq(marks[1][2], 1, "mark anchored on last comment row")
end

-- saving must not persist virtual lines
local save_ok = pcall(vim.api.nvim_buf_call, e2e_buf, function()
  vim.cmd("silent write!")
end)
ok(save_ok, "buffer writes without errors")
if save_ok then
  local f = io.open(e2e_file, "r")
  local saved = f and f:read("*a") or ""
  if f then
    f:close()
  end
  ok(not saved:find("こんにちは"), "translation is not written to disk")
  eq(vim.api.nvim_buf_get_lines(e2e_buf, 0, -1, false), before, "write does not alter buffer")
end

-- second run must be served from cache (no backend call)
notifications = {}
require("trans.renderer").clear(e2e_buf)
trans.translate(e2e_buf)
local cached = vim.wait(5000, function()
  return require("trans.renderer").is_rendered(e2e_buf)
end, 10)
ok(cached, "second render")
local saw_cached = false
for _, msg in ipairs(notifications) do
  if msg:find("cached") then
    saw_cached = true
  end
end
ok(saw_cached, "second run reports cached lines")

require("trans.cache").save()
local cf = io.open(tmp_cache, "r")
ok(cf ~= nil, "cache file written")
if cf then
  cf:close()
end

trans.clear(e2e_buf)
eq(#vim.api.nvim_buf_get_extmarks(e2e_buf, ns, 0, -1, {}), 0, "clear removes marks")

----------------------------------------------------------------------------
-- Markdown end-to-end (and the :Trans command path)
----------------------------------------------------------------------------
local md_e2e = make_buf({
  "# Greeting",
  "",
  "Hello world, this is a paragraph.",
  "",
  "- first item",
  "- second item",
  "",
  "```lua",
  "print('skip me')",
  "```",
}, "markdown")
local md_before = vim.api.nvim_buf_get_lines(md_e2e, 0, -1, false)

vim.api.nvim_set_current_buf(md_e2e)
vim.cmd("Trans")

local md_done = vim.wait(30000, function()
  return not trans.is_translating(md_e2e)
end, 50)
ok(md_done, "markdown translation finished")

local md_marks = vim.api.nvim_buf_get_extmarks(md_e2e, ns, 0, -1, { details = true })
ok(#md_marks >= 3, "markdown units rendered")

eq(vim.api.nvim_buf_get_lines(md_e2e, 0, -1, false), md_before, "markdown buffer untouched")

local texts = {}
for _, m in ipairs(md_marks) do
  local lines = m[4].virt_lines or {}
  ok(#lines > 0, "markdown block has virtual lines")
  texts[#texts + 1] = lines[1][1][1] or ""
end
ok(not table.concat(texts, "\n"):find("skip me"), "code block never translated")

vim.cmd("TransClear")
eq(#vim.api.nvim_buf_get_extmarks(md_e2e, ns, 0, -1, {}), 0, ":TransClear removes marks")

----------------------------------------------------------------------------
-- streaming: non-blocking + progressive display
----------------------------------------------------------------------------
local nonce = tostring(math.random(1000000, 9999999))
local prog_buf = make_buf({
  "// prog one " .. nonce,
  "int a;",
  "// prog two " .. nonce,
  "int b;",
  "// prog three " .. nonce,
  "int c;",
  "// prog four " .. nonce,
}, "c")

-- Serialise the backend so that arrival order / partial state is observable.
trans.setup({
  target = "ja",
  max_concurrency = 1,
  cache = { enabled = true, path = tmp_cache },
  notify = true,
})

-- A timer that fires while results are still arriving: it can only fire if
-- the event loop is not blocked by the backend call.
local timer_fired_while_busy = false
vim.defer_fn(function()
  timer_fired_while_busy = require("trans.renderer").count(prog_buf) < 4
end, 60)

local started_at = vim.uv.hrtime()
ok(trans.translate(prog_buf), "streaming translate starts")
local return_ms = (vim.uv.hrtime() - started_at) / 1e6
ok(return_ms < 200, ("translate() returns without blocking (%.1fms)"):format(return_ms))

local first_shown = vim.wait(30000, function()
  return require("trans.renderer").count(prog_buf) > 0
end, 10)
ok(first_shown, "first result is displayed while the rest is still running")

local partial = require("trans.renderer").count(prog_buf)
ok(partial < 4, ("progressive display: %d/4 blocks shown first"):format(partial))
ok(timer_fired_while_busy, "event loop keeps running during translation")

local all_shown = vim.wait(60000, function()
  return require("trans.renderer").count(prog_buf) == 4
end, 10)
ok(all_shown, "all blocks are shown eventually")
ok(not trans.is_translating(prog_buf), "streaming run finished")

local prog_lines = vim.api.nvim_buf_get_lines(prog_buf, 0, -1, false)
local prog_marks = vim.api.nvim_buf_get_extmarks(prog_buf, ns, 0, -1, { details = true })
eq(#prog_marks, 4, "one extmark per unit")
for _, m in ipairs(prog_marks) do
  ok(#(m[4].virt_lines or {}) > 0, "every unit ended up with translations")
end
eq(vim.api.nvim_buf_get_lines(prog_buf, 0, -1, false), prog_lines, "streaming does not touch the buffer")

----------------------------------------------------------------------------
-- cancelling while a run is still in flight
----------------------------------------------------------------------------
local cancel_nonce = tostring(math.random(1000000, 9999999))
local cancel_buf = make_buf({
  "// cancel one " .. cancel_nonce,
  "int x;",
  "// cancel two " .. cancel_nonce,
}, "c")

ok(trans.translate(cancel_buf), "cancel run starts")
local partial_cancel = vim.wait(10000, function()
  return require("trans.renderer").count(cancel_buf) > 0
end, 10)
ok(partial_cancel, "something is shown before cancelling")

trans.clear(cancel_buf)
vim.wait(10000, function()
  return not trans.is_translating(cancel_buf)
end, 10)

eq(require("trans.renderer").count(cancel_buf), 0, "cancelled run leaves no marks behind")
ok(not trans.is_translating(cancel_buf), "cancelled run stopped")

----------------------------------------------------------------------------
-- a plain :write during translation must not discard the results
-- (:write bumps the changedtick without moving any row)
----------------------------------------------------------------------------
local write_nonce = tostring(math.random(1000000, 9999999))
local write_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(write_buf, vim.fn.tempname() .. ".c")
vim.api.nvim_buf_set_lines(write_buf, 0, -1, false, {
  "// write one " .. write_nonce,
  "int y;",
  "// write two " .. write_nonce,
})
vim.bo[write_buf].filetype = "c"

ok(trans.translate(write_buf), "write run starts")
vim.wait(10000, function()
  return require("trans.renderer").count(write_buf) > 0
end, 10)
vim.api.nvim_buf_call(write_buf, function()
  vim.cmd("silent write!")
end)
local write_done = vim.wait(30000, function()
  return not trans.is_translating(write_buf)
end, 10)
ok(write_done, "run keeps going through a plain :write")
eq(require("trans.renderer").count(write_buf), 2, "results survive a plain :write")

----------------------------------------------------------------------------
print(("%d checks, %d failures"):format(checks, failures))
if failures > 0 then
  vim.cmd("cquit 1")
end
