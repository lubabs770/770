-- Tests for the pure-Lua block splitter (M._Streamer).
-- Run headless:  nvim -l test/streamer_spec.lua
--
-- The Streamer turns a stream of text deltas into whole logic blocks. A block
-- closes on a blank line, or when a new column-0 line begins while content is
-- already buffered. These tests feed deltas (sometimes split mid-line, as the
-- real stream does) and assert on the sequence of emitted blocks.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local Streamer = require("770")._Streamer

local passed, failed = 0, 0

local function eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  if #a ~= #b then return false end
  for i = 1, #a do
    if not eq(a[i], b[i]) then return false end
  end
  return true
end

-- Collect the blocks produced by feeding `deltas` in order, then finishing.
local function collect(deltas)
  local blocks = {}
  local s = Streamer.new(function(block)
    -- copy so later mutation of the internal table can't affect us
    local c = {}
    for i, l in ipairs(block) do c[i] = l end
    table.insert(blocks, c)
  end)
  for _, d in ipairs(deltas) do s:feed(d) end
  s:finish()
  return blocks
end

local function test(name, deltas, expected)
  local got = collect(deltas)
  if eq(got, expected) then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("FAIL: " .. name .. "\n")
    io.write("  expected: " .. vim.inspect(expected):gsub("%s+", " ") .. "\n")
    io.write("  got:      " .. vim.inspect(got):gsub("%s+", " ") .. "\n")
  end
end

-- A blank line closes the current block (and is included in it).
test("blank line closes block",
  { "hello\n", "\n", "world\n" },
  { { "hello", "" }, { "world" } })

-- A new column-0 line closes the previous top-level unit.
test("new top-level line closes block",
  { "local a = 1\nlocal b = 2\n" },
  { { "local a = 1" }, { "local b = 2" } })

-- Indented lines stay attached to their top-level line; a column-0 line (even
-- `end`) opens a fresh block.
test("indented continuation stays in block",
  { "function f()\n", "  return 1\n", "end\n", "function g()\n", "  return 2\nend\n" },
  { { "function f()", "  return 1" }, { "end" }, { "function g()", "  return 2" }, { "end" } })

-- Deltas split mid-line must be reassembled before splitting into blocks.
test("delta split mid-line reassembles",
  { "func", "tion f()\n  ret", "urn 1\nend\n" },
  { { "function f()", "  return 1" }, { "end" } })

-- finish() flushes trailing content that has no closing newline.
test("finish flushes unterminated tail",
  { "no newline here" },
  { { "no newline here" } })

-- A trailing carriage return is stripped (CRLF streams).
test("strips trailing CR",
  { "a\r\nb\r\n" },
  { { "a" }, { "b" } })

-- No input yields no blocks.
test("empty input yields nothing",
  {},
  {})

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
