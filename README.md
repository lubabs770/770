# 770

Tag `@claude` inside any buffer. The local `claude` CLI reads the whole buffer
plus your instruction and streams its reply back into the buffer — **one logic
block at a time** (a function, a variable, an object, a statement), not token by
token. Inspired by [ThePrimeagen/99](https://github.com/ThePrimeagen/99).

## How it works

1. Put `@claude <instruction>` on a line in your buffer.
2. Run `:Run770` (or `<leader>cc`).
3. The `@claude` line is replaced and Claude's output streams in, block by block.

The buffer is sent as context; `@claude`'s line marks the insertion point. Under
the hood it runs:

```
claude -p --output-format stream-json --include-partial-messages --verbose --append-system-prompt <sys>
```

with your prompt on stdin. The `content_block_delta` / `text_delta` events are
buffered and flushed whenever a complete logic block is seen — a new top-level
line (column 0) or a blank line closes the current block. Markdown code fences
(```` ``` ````) are stripped defensively.

> First token can take a few seconds — the buffer stays empty until then, that's
> normal, not a hang.

## Requirements

- Neovim 0.7+
- The `claude` CLI on your `PATH`, already authenticated.

## Install (lazy.nvim)

```lua
{
  dir = "~/770",
  config = function()
    require("770").setup({
      -- model = "claude-opus-4-8",  -- optional; defaults to CLI's model
      -- keymap = "<leader>cc",
    })
  end,
}
```

## Usage

```lua
local function add(a, b)
  @claude make this handle nil args, and add a `mul` function
end
```

`:Run770` → the `@claude` line vanishes and the generated code streams in.

## Config

| key      | default        | meaning                                   |
|----------|----------------|-------------------------------------------|
| `cli`    | `"claude"`     | binary to invoke                          |
| `model`  | `nil`          | `--model` value; nil = CLI default        |
| `tag`    | `"@claude"`    | marker scanned for in the buffer          |
| `keymap` | `"<leader>cc"` | normal-mode mapping (set `false` to skip) |
| `system` | (see source)   | appended system prompt                    |

## Command name

Vim user commands can't start with a digit, so it's `:Run770`, not `:770`.
