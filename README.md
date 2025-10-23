# git-diff-viewer.nvim

Show unstaged inline diffs whenever you change branches. Designed for AstroNvim but works with any Neovim distribution.

## Features

- Watches `.git/HEAD` and reacts as soon as the branch changes.
- Closes your current listed buffers and opens a fresh tab populated with one scratch buffer per unstaged file (no splits to manage).
- Highlights additions (`DiffAdd`) and deletions (`DiffDelete`) using standard diff syntax; new files show the entire file as additions, deleted files show the full removed contents.
- Toggle on/off with `<leader>ad`, `:GitDiffViewerToggle`, or your own mapping.
- Optional manual refresh via `:GitDiffViewerRefresh`.

## Installation

### Lazy.nvim (AstroNvim default)

```lua
return {
  "yourname/git-diff-viewer.nvim",
  config = function()
    require("git_diff_viewer").setup({
      keymap = "<leader>ad", -- optional override
    })
  end,
}
```

### Packer

```lua
use({
  "yourname/git-diff-viewer.nvim",
  config = function()
    require("git_diff_viewer").setup()
  end,
})
```

## Configuration

```lua
require("git_diff_viewer").setup({
  enable_on_start = true,  -- start enabled
  keymap = "<leader>ad",   -- set to false to skip default mapping
  watch_interval = 750,     -- milliseconds between HEAD checks
  open_in_tab = true,       -- open diffs in their own tab page
  diff_cmd = { "git", "diff", "--no-color" },
  status_cmd = { "git", "status", "--porcelain" },
})
```

## Usage

- Switch branches with `git checkout`, `git switch`, or any tooling. The plugin detects the HEAD change and opens a fresh tab containing one diff buffer per unstaged file (each buffer named after the file).
- Use `<leader>ad` (or `:GitDiffViewerToggle`) to disable the watcher and restore your previous buffers.
- Run `:GitDiffViewerRefresh` if you want to re-render manually.

## Notes

- The plugin only lists files with unstaged modifications (including untracked files). Stage or discard changes to remove them from the view.
- `open_in_tab = false` keeps the diffs in the current tab if you prefer a simpler layout.
- When disabling the plugin we re-add your previous buffers via `:badd` so they reappear in your buffer list; reopen them manually if you need their windows rebuilt.

## Roadmap

- Detect staged-only changes.
- Optionally show the working tree version side-by-side.
- Allow custom diff renderers (Tree-sitter, mini.diff, etc.).
