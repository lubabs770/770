-- Tests for the JSONL parser (M._handle_json_line) that turns lines from
-- `claude --output-format stream-json` into streamer feeds and error reports.
-- Run headless:  nvim -l test/json_line_spec.lua
--
-- handle_json_line(line, streamer, on_error):
--   * text_delta events feed the streamer,
--   * a result with is_error, or an error event, call on_error,
--   * anything else (including malformed JSON) is ignored, never throws.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local handle = require("770")._handle_json_line

local passed, failed = 0, 0

-- A stub standing in for the real Streamer: records everything it's fed.
local function stub_streamer()
  local s = { fed = {} }
  function s:feed(text) table.insert(self.fed, text) end
  return s
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("FAIL: " .. name .. "\n  " .. tostring(err) .. "\n")
  end
end

local function assert_eq(got, want, msg)
  if got ~= want then
    error((msg or "mismatch") .. ": got " .. vim.inspect(got) .. ", want " .. vim.inspect(want))
  end
end

-- A text_delta inside a stream_event feeds the streamer.
test("text_delta feeds streamer", function()
  local s = stub_streamer()
  handle(vim.json.encode({
    type = "stream_event",
    event = { type = "content_block_delta", delta = { type = "text_delta", text = "hi" } },
  }), s, function() error("on_error should not fire") end)
  assert_eq(#s.fed, 1, "one feed")
  assert_eq(s.fed[1], "hi", "fed text")
end)

-- A non-text delta (e.g. thinking) is ignored.
test("non-text delta ignored", function()
  local s = stub_streamer()
  handle(vim.json.encode({
    type = "stream_event",
    event = { type = "content_block_delta", delta = { type = "thinking_delta", thinking = "x" } },
  }), s, function() error("on_error should not fire") end)
  assert_eq(#s.fed, 0, "no feed")
end)

-- A result event with is_error reports the result string.
test("result error reports message", function()
  local got
  handle(vim.json.encode({ type = "result", is_error = true, result = "boom" }),
    stub_streamer(), function(m) got = m end)
  assert_eq(got, "boom", "error message")
end)

-- A result with is_error but no result falls back to subtype.
test("result error falls back to subtype", function()
  local got
  handle(vim.json.encode({ type = "result", is_error = true, subtype = "max_turns" }),
    stub_streamer(), function(m) got = m end)
  assert_eq(got, "max_turns", "fallback message")
end)

-- A top-level error event reports its message.
test("error event reports message", function()
  local got
  handle(vim.json.encode({ type = "error", message = "nope" }),
    stub_streamer(), function(m) got = m end)
  assert_eq(got, "nope", "error message")
end)

-- A successful result (is_error absent/false) is not an error.
test("successful result is not an error", function()
  handle(vim.json.encode({ type = "result", is_error = false, result = "ok" }),
    stub_streamer(), function() error("on_error should not fire") end)
end)

-- Malformed JSON is ignored, never throws.
test("malformed json ignored", function()
  handle("{not json", stub_streamer(), function() error("on_error should not fire") end)
end)

-- A JSON value that isn't an object is ignored.
test("non-object json ignored", function()
  handle("42", stub_streamer(), function() error("on_error should not fire") end)
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
