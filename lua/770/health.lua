-- `:checkhealth 770` — verify the plugin's runtime prerequisites.
-- Kept dependency-free and read-only so it can't disturb a running session.

local M = {}

-- vim.health.{start,ok,warn,error} landed in 0.10; older Neovim (we support
-- 0.7+) exposes the same calls as vim.health.report_*. Bridge both.
local health = vim.health or {}
local h_start = health.start or health.report_start
local h_ok = health.ok or health.report_ok
local h_warn = health.warn or health.report_warn
local h_error = health.error or health.report_error

function M.check()
  h_start("770")

  if vim.fn.has("nvim-0.7") == 1 then
    h_ok("Neovim 0.7+")
  else
    h_error("Neovim 0.7+ required")
  end

  local ok, mod = pcall(require, "770")
  if not ok then
    h_error("could not load the 770 module: " .. tostring(mod))
    return
  end

  local cfg = mod.config
  if vim.fn.executable(cfg.cli) == 1 then
    h_ok("'" .. cfg.cli .. "' found on PATH")
  else
    h_error("'" .. cfg.cli .. "' not found on PATH", {
      "Install the Claude Code CLI and make sure it is authenticated.",
    })
  end

  if cfg.model then
    h_ok("model override: " .. cfg.model)
  else
    h_ok("model: CLI default")
  end
end

return M
