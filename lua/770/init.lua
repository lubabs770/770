-- 770: tag @claude in a buffer, the local `claude` CLI runs as an *agent* on that
-- file — reading it with its own tools and editing it directly — then the buffer
-- refreshes in place. Inspired by ThePrimeagen/99.
--
-- Two modes, chosen by the agent from your instruction:
--   * prose / question ask  -> reply is written as COMMENT lines below @claude
--     (the @claude line is kept)
--   * code / edit / git ask -> the code is edited directly and the executed
--     @claude directive line is removed
-- 770 itself never inserts text into the buffer; the agent owns every edit.

local M = {}

M.config = {
  cli = "claude",           -- local Claude Code binary
  model = nil,              -- nil = CLI default; else passed as --model
  tag = "@claude",          -- pattern to look for in the buffer
  keymap = "<leader>cc",    -- manual trigger (set false to disable)
  auto = true,              -- fire automatically on InsertLeave when a @claude line has an instruction
  notify = true,            -- info/status messages (errors always show)
  spinner = true,           -- inline status spinner while the agent works
  permission_mode = "acceptEdits", -- --permission-mode (use "bypassPermissions" for anything)
  -- Tools the agent may use without an (impossible, headless) permission prompt.
  -- Listing Bash auto-approves it so git operations run un-prompted.
  allowed_tools = { "Read", "Edit", "Write", "MultiEdit", "Bash", "Grep", "Glob" },
  add_dir = nil,            -- optional extra --add-dir (e.g. a repo root outside cwd)
  system = [[You are invoked by a Neovim plugin ("770") on a single open file. A
comment in that file tags you: `@claude <instruction>`. Respond by EDITING THE
FILE DIRECTLY with your tools — never just print an answer, printed text is
discarded and never reaches the user.

Decide from the instruction which mode applies:
(a) Question / explanation / prose request -> write your reply as COMMENT lines
    (using the buffer's comment syntax, given in the prompt) inserted directly
    BELOW the @claude line, and KEEP the @claude line.
(b) Code change / edit / refactor / git task -> make the change directly in the
    file and REMOVE the executed @claude directive line.

Never leave uncommented prose anywhere in the file — it is a syntax error and
breaks the language server. Prefer minimal, correct edits. Use git via Bash only
if the instruction requires it. Work only within this file and its repository.]],
}

local ns = vim.api.nvim_create_namespace("claude770")
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Manual trigger (command name can't start with a digit → Run770).
  vim.api.nvim_create_user_command("Run770", function()
    M.run()
  end, { desc = "Run the @claude agent on this file" })

  if M.config.keymap then
    vim.keymap.set("n", M.config.keymap, M.run, { desc = "770: run @claude agent" })
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
-- Buffer scan: find the @claude tag and its instruction.
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
      }
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- One JSONL line from `claude --output-format stream-json`. We only care about
-- surfacing which tool the agent is running (for the status spinner) and errors.
--------------------------------------------------------------------------------
local function tool_hint(name, input)
  local hint = name or "tool"
  if type(input) == "table" then
    if input.file_path then
      hint = hint .. " " .. vim.fn.fnamemodify(input.file_path, ":t")
    elseif input.command then
      hint = hint .. " " .. tostring(input.command):gsub("%s+", " "):sub(1, 32)
    elseif input.pattern then
      hint = hint .. " " .. tostring(input.pattern):sub(1, 24)
    end
  end
  return hint
end

local function handle_json_line(line, on_status, on_error)
  local ok, obj = pcall(vim.json.decode, line)
  if not ok or type(obj) ~= "table" then return end

  if obj.type == "stream_event" and obj.event then
    local ev = obj.event
    -- quick status the moment a tool block opens (input may still be streaming)
    if ev.type == "content_block_start" and ev.content_block
        and ev.content_block.type == "tool_use" then
      on_status(tool_hint(ev.content_block.name, ev.content_block.input))
    end
  elseif obj.type == "assistant" and obj.message and obj.message.content then
    -- full (non-partial) assistant message: tool_use carries complete input
    for _, c in ipairs(obj.message.content) do
      if c.type == "tool_use" then on_status(tool_hint(c.name, c.input)) end
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
  -- The @claude line may be kept after a run (prose asks), so guard against
  -- re-firing on every InsertLeave: skip if we already answered this exact
  -- instruction. Editing the instruction changes the signature and re-runs it.
  if vim.b[bufnr].claude770_last == tag.instruction then return end
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

  -- Agentic mode edits a file on disk, so we need a real, named file buffer.
  if vim.bo[bufnr].buftype ~= "" then
    notify("agentic mode needs a normal file buffer", vim.log.levels.WARN)
    return
  end
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if fname == "" then
    notify("agentic mode needs a saved file (name/write the buffer first)", vim.log.levels.WARN)
    return
  end

  local tag = find_tag(bufnr, cfg.tag)
  if not tag then
    notify("no " .. cfg.tag .. " tag found in buffer", vim.log.levels.WARN)
    return
  end
  local instruction = tag.instruction ~= "" and tag.instruction
    or "Do what the " .. cfg.tag .. " tag implies from surrounding context."

  vim.b[bufnr].claude770_running = true

  -- Save so the agent reads current content; enable autoread so the in-place
  -- refresh on completion is silent.
  if vim.bo[bufnr].modified then
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent keepalt write") end)
  end
  vim.o.autoread = true

  local filetype = vim.bo[bufnr].filetype
  local cs = vim.bo[bufnr].commentstring
  local comment_hint = (cs and cs ~= "")
      and ("Comment syntax for this buffer: `" .. (cs:gsub("%%s", "<text>")) .. "`")
    or "This buffer has no comment syntax (treat as plain text)."

  -- Run from the git root (fall back to the file's dir) so relative paths + git
  -- resolve correctly.
  local dir = vim.fn.fnamemodify(fname, ":h")
  local root = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })[1]
  local cwd = (vim.v.shell_error == 0 and root and root ~= "") and root or dir

  local prompt = table.concat({
    "File: " .. fname,
    "Filetype: " .. (filetype ~= "" and filetype or "plaintext"),
    comment_hint,
    "The " .. cfg.tag .. " tag is on line " .. (tag.row + 1) .. ".",
    "",
    "Instruction: " .. instruction,
  }, "\n")

  ------------------------------------------------------------------------------
  -- Inline status spinner: an extmark at the EOL of the @claude line, showing
  -- what the agent is currently doing.
  ------------------------------------------------------------------------------
  local status = "thinking…"
  local mark_id, timer, spin_i = nil, nil, 1
  local function spinner_draw()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local last = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)
    local row = math.min(tag.row, last)
    local opts = {
      virt_text = { { spinner_frames[spin_i] .. " claude: " .. status, "Comment" } },
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

  local had_error = false
  local function on_error(msg)
    had_error = true
    notify(msg, vim.log.levels.ERROR)
  end
  local function on_status(s)
    status = s
    if cfg.spinner then spinner_draw() end
  end

  local cmd = {
    cfg.cli, "-p",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--permission-mode", cfg.permission_mode,
    "--append-system-prompt", cfg.system,
  }
  if cfg.allowed_tools and #cfg.allowed_tools > 0 then
    table.insert(cmd, "--allowedTools")
    for _, t in ipairs(cfg.allowed_tools) do table.insert(cmd, t) end
  end
  if cfg.add_dir then
    table.insert(cmd, "--add-dir")
    table.insert(cmd, cfg.add_dir)
  end
  if cfg.model then
    table.insert(cmd, "--model")
    table.insert(cmd, cfg.model)
  end

  local partial = ""
  local jobid = vim.fn.jobstart(cmd, {
    cwd = cwd,
    on_stdout = function(_, data, _)
      if not data then return end
      partial = partial .. table.concat(data, "\n")
      while true do
        local nl = partial:find("\n")
        if not nl then break end
        local line = partial:sub(1, nl - 1):gsub("\r$", "")
        partial = partial:sub(nl + 1)
        if line ~= "" then
          handle_json_line(line, on_status, on_error)
        end
      end
    end,
    on_exit = function(_, code, _)
      spinner_stop()
      if vim.api.nvim_buf_is_valid(bufnr) then
        -- Refresh the SAME buffer from disk in place — never close/replace it.
        -- checktime silently reloads an unmodified buffer whose file changed.
        if not vim.bo[bufnr].modified then
          vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! checktime") end)
        else
          notify("buffer edited in nvim during run; not reloading (claude edited the file on disk)", vim.log.levels.WARN)
        end
        -- Remember this instruction so auto mode doesn't re-fire on every
        -- InsertLeave when the @claude line is kept (prose asks).
        if not had_error and code == 0 then
          vim.b[bufnr].claude770_last = instruction
        end
        vim.b[bufnr].claude770_running = false
      end
      if code ~= 0 and not had_error then
        notify(cfg.cli .. " exited " .. code, vim.log.levels.ERROR)
      elseif not had_error then
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
