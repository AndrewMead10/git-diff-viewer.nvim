# git-diff-viewer.nvim

Show unstaged inline diffs whenever you change branches. Designed for AstroNvim but works with any Neovim distribution.

## Features

- Watches `.git/HEAD` and reacts as soon as the branch changes.
- Closes your current listed buffers and opens a fresh tab populated with one scratch buffer per unstaged file (no splits to manage).
- Highlights additions (`DiffAdd`) and deletions (`DiffDelete`) using standard diff syntax; new files show the entire file as additions, deleted files show the full removed contents.
- Stage the current file directly from the diff buffer with `<leader>ada` (configurable).
- Switch to a whole-file diff view (headers stripped) with `<leader>adf`.
- Toggle on/off with `<leader>ag`, `:GitDiffViewerToggle`, or your own mapping.
- Optional manual refresh via `:GitDiffViewerRefresh`.

## Installation

### Lazy.nvim (AstroNvim default)

```lua
return {
  "yourname/git-diff-viewer.nvim",
  config = function()
    require("git_diff_viewer").setup()
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
  keymap = "<leader>ag",   -- set to false to skip default toggle mapping
  watch_interval = 750,     -- milliseconds between HEAD checks
  open_in_tab = true,       -- open diffs in their own tab page
  accept_keymap = "<leader>ada", -- buffer-local mapping to stage the file
  refresh_keymap = "<leader>adr", -- global mapping to refresh the view
  full_file_keymap = "<leader>adf", -- buffer-local mapping to show whole-file diff
  full_file_context = 100000, -- line context for whole-file diff rendering
  diff_cmd = { "git", "diff", "--no-color" },
  status_cmd = { "git", "status", "--porcelain" },
})
```

## Usage

- Switch branches with `git checkout`, `git switch`, or any tooling. The plugin detects the HEAD change and opens a fresh tab containing one diff buffer per unstaged file (each buffer named after the file).
- While focused on a diff buffer, press `<leader>ada` to stage the file and refresh the view.
- Press `<leader>adr` (or `:GitDiffViewerRefresh`) anytime to re-render the diffs after external changes.
- Press `<leader>adf` inside a diff buffer to swap into a whole-file diff (without the `diff --git`/`index` headers) for easier reading.
- Use `<leader>ag` (or `:GitDiffViewerToggle`) to disable the watcher and restore your previous buffers.

## Notes

- The plugin only lists files with unstaged modifications (including untracked files). Stage or discard changes to remove them from the view.
- `open_in_tab = false` keeps the diffs in the current tab if you prefer a simpler layout.
- When disabling the plugin we re-add your previous buffers via `:badd` so they reappear in your buffer list; reopen them manually if you need their windows rebuilt.

## Roadmap

- Detect staged-only changes.
- Optionally show the working tree version side-by-side.
- Allow custom diff renderers (Tree-sitter, mini.diff, etc.).
