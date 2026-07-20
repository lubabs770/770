-- 770: tag @claude in a buffer, the local `claude` CLI reads the buffer and
-- streams a reply back one *logic block* at a time (fn / var / obj), not token
-- by token. Inspired by ThePrimeagen/99.

local M = {}

M.config = {
  cli = "claude",       -- local Claude Code binary
  model = nil,          -- nil = CLI default; else passed as --model
  tag = "@claude",      -- pattern to look for in the buffer
  keymap = "<leader>cc", -- manual trigger (set false to disable)
  auto = true,          -- fire automatically on InsertLeave when a @claude line has an instruction
  notify = true,        -- info/status messages (errors always show)
  spinner = true,       -- inline spinner while generating
  system = [[You are embedded in a text editor buffer. The user tagged you with @claude.
Output ONLY the content that should be inserted into the buffer to satisfy the
instruction. Do NOT wrap output in markdown code fences (```). No explanations,
no preamble. Write in the buffer's language. Emit complete logical units (a full
function, variable, object, or statement) so the editor can stream your output
block by block.]],
}

local ns = vim.api.nvim_create_namespace("claude770")
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Manual trigger (command name can't start with a digit → Run770).
  vim.api.nvim_create_user_command("Run770", function()
    M.run()
  end, { desc = "Read @claude tag, stream reply block by block" })

  if M.config.keymap then
    vim.keymap.set("n", M.config.keymap, M.run, { desc = "770: run @claude tag" })
  end

  if M.config.auto then
    local grp = vim.api.nvim_create_augroup("claude770", { clear = true })
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = grp,
      callback = function()
        M.maybe_run()
      end,
    })
  end
end

local function notify(msg, level)
  level = level or vim.log.levels.INFO
  if level >= vim.log.levels.ERROR or M.config.notify then
    vim.notify("770: " .. msg, level)
  end
end

--------------------------------------------------------------------------------
-- Streamer: turns a stream of text deltas into whole logic blocks.
--
-- A block boundary is declared when either:
--   * a blank line appears (paragraph / statement separator), or
--   * a new line starts at column 0 while we already have buffered content
--     (a new top-level construct — fn/var/obj/class — is beginning).
-- Everything indented under the current top-level line stays in the same block.
--------------------------------------------------------------------------------
local Streamer = {}
Streamer.__index = Streamer

function Streamer.new(on_block)
  return setmetatable({ buf = "", block = {}, on_block = on_block }, Streamer)
end

function Streamer:_flush()
  if #self.block > 0 then
    self.on_block(self.block)
    self.block = {}
  end
end

function Streamer:_line(line)
  if line:match("^%s*$") then          -- blank: close current block
    table.insert(self.block, line)
    self:_flush()
  elseif line:match("^%S") and #self.block > 0 then
    self:_flush()                      -- new top-level unit: flush previous
    table.insert(self.block, line)
  else
    table.insert(self.block, line)     -- continuation of current unit
  end
end

function Streamer:feed(text)
  self.buf = self.buf .. text
  while true do
    local nl = self.buf:find("\n")
    if not nl then break end
    local line = self.buf:sub(1, nl - 1):gsub("\r$", "")
    self.buf = self.buf:sub(nl + 1)
    self:_line(line)
  end
end

function Streamer:finish()
  if self.buf ~= "" then
    self:_line((self.buf:gsub("\r$", "")))
    self.buf = ""
  end
  self:_flush()
end

--------------------------------------------------------------------------------
-- Buffer scan: find the @claude tag, its instruction, and where to write.
--------------------------------------------------------------------------------
local function find_tag(bufnr, tag)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pat = vim.pesc(tag)
  for i, line in ipairs(lines) do
    local s, e = line:find(pat)
    if s then
      return {
        row = i - 1,                             -- 0-indexed line of the tag
        instruction = vim.trim(line:sub(e + 1)), -- text after @claude on that line
        lines = lines,
      }
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- JSONL line from `claude --output-format stream-json`.
--------------------------------------------------------------------------------
local function handle_json_line(line, streamer, on_error)
  local ok, obj = pcall(vim.json.decode, line)
  if not ok or type(obj) ~= "table" then return end

  if obj.type == "stream_event" and obj.event then
    local ev = obj.event
    if ev.type == "content_block_delta" and ev.delta and ev.delta.type == "text_delta" then
      streamer:feed(ev.delta.text)
    end
  elseif obj.type == "result" and obj.is_error then
    on_error(obj.result or obj.subtype or "CLI reported an error")
  elseif obj.type == "error" then
    on_error(obj.message or "unknown error")
  end
end

--------------------------------------------------------------------------------
-- Auto-trigger guard: fire only when a @claude line carries an instruction and
-- nothing is already running in this buffer.
--------------------------------------------------------------------------------
function M.maybe_run()
  if not M.config.auto then return end
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].claude770_running then return end
  local tag = find_tag(bufnr, M.config.tag)
  if not tag or tag.instruction == "" then return end
  M.run()
end

--------------------------------------------------------------------------------
-- Main entrypoint.
--------------------------------------------------------------------------------
function M.run()
  local cfg = M.config

  if vim.fn.executable(cfg.cli) ~= 1 then
    notify("'" .. cfg.cli .. "' not found on PATH", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].claude770_running then return end

  local tag = find_tag(bufnr, cfg.tag)
  if not tag then
    notify("no " .. cfg.tag .. " tag found in buffer", vim.log.levels.WARN)
    return
  end

  vim.b[bufnr].claude770_running = true

  local filetype = vim.bo[bufnr].filetype
  local buffer_text = table.concat(tag.lines, "\n")
  local instruction = tag.instruction ~= "" and tag.instruction
    or "Do what the @claude tag implies from surrounding context."

  local prompt = table.concat({
    "Filetype: " .. (filetype ~= "" and filetype or "plaintext"),
    "",
    "Current buffer (the " .. cfg.tag .. " line is where your output goes):",
    "----",
    buffer_text,
    "----",
    "",
    "Instruction: " .. instruction,
  }, "\n")

  -- Remove the @claude line; generated blocks are inserted in its place and the
  -- spinner rides at the END of the last written line (no dedicated blank line,
  -- so it never occupies a buffer line of its own).
  vim.api.nvim_buf_set_lines(bufnr, tag.row, tag.row + 1, false, {})
  local insert_row = tag.row
  local first_block = true

  ------------------------------------------------------------------------------
  -- Inline spinner: an extmark at the EOL of the last generated line.
  ------------------------------------------------------------------------------
  local mark_id, timer
  local spin_i = 1
  local function spinner_draw()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local last = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)
    -- sit on the last written output line; before any output exists, fall back
    -- to the line just above the insertion point.
    local row = insert_row > tag.row and (insert_row - 1) or math.max(0, tag.row - 1)
    row = math.min(row, last)
    local opts = {
      virt_text = { { spinner_frames[spin_i] .. " claude", "Comment" } },
      virt_text_pos = "eol",
    }
    if mark_id then opts.id = mark_id end
    mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, opts)
  end
  local function spinner_stop()
    if timer then vim.fn.timer_stop(timer) end
    if mark_id then pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark_id) end
    mark_id, timer = nil, nil
  end
  if cfg.spinner then
    spinner_draw()
    timer = vim.fn.timer_start(90, function()
      spin_i = spin_i % #spinner_frames + 1
      spinner_draw()
    end, { ["repeat"] = -1 })
  end

  local function strip_fences(lines)
    local out = {}
    for _, l in ipairs(lines) do
      if not l:match("^%s*```") then table.insert(out, l) end
    end
    return out
  end

  -- Insert one block above the placeholder spinner line, so the placeholder
  -- (and its spinner) stays at insert_row, trailing the output.
  local function on_block(lines)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    lines = strip_fences(lines)
    if first_block then
      while #lines > 0 and lines[1]:match("^%s*$") do
        table.remove(lines, 1)
      end
      first_block = false
    end
    if #lines == 0 then return end
    vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, lines)
    insert_row = insert_row + #lines
    if cfg.spinner then spinner_draw() end
  end

  local streamer = Streamer.new(on_block)
  local had_error = false
  local function on_error(msg)
    had_error = true
    notify(msg, vim.log.levels.ERROR)
  end

  local partial = ""
  local cmd = {
    cfg.cli, "-p",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--append-system-prompt", cfg.system,
  }
  if cfg.model then
    table.insert(cmd, "--model")
    table.insert(cmd, cfg.model)
  end

  local jobid = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data, _)
      if not data then return end
      partial = partial .. table.concat(data, "\n")
      while true do
        local nl = partial:find("\n")
        if not nl then break end
        local line = partial:sub(1, nl - 1):gsub("\r$", "")
        partial = partial:sub(nl + 1)
        if line ~= "" then
          handle_json_line(line, streamer, on_error)
        end
      end
    end,
    on_exit = function(_, code, _)
      streamer:finish()
      spinner_stop()
      if vim.api.nvim_buf_is_valid(bufnr) then
        -- trim a single trailing blank line the model may have emitted
        if insert_row > tag.row then
          local prev = vim.api.nvim_buf_get_lines(bufnr, insert_row - 1, insert_row, false)[1]
          if prev == "" then
            vim.api.nvim_buf_set_lines(bufnr, insert_row - 1, insert_row, false, {})
            insert_row = insert_row - 1
          end
        end
        vim.b[bufnr].claude770_running = false
      end
      if code ~= 0 and not had_error then
        notify(cfg.cli .. " exited " .. code, vim.log.levels.ERROR)
      else
        notify("done")
      end
    end,
  })

  if jobid <= 0 then
    spinner_stop()
    vim.b[bufnr].claude770_running = false
    notify("failed to start " .. cfg.cli, vim.log.levels.ERROR)
    return
  end

  vim.fn.chansend(jobid, prompt)
  vim.fn.chanclose(jobid, "stdin")
end

return M
