# git-diff-viewer.nvim

View unstaged inline diffs for your current branch on demand. Designed for AstroNvim but works with any Neovim distribution.

## Features

- Toggle diff view on/off with `<leader>agt`, `:GitDiffViewerToggle`, or your own mapping.
- Opens a fresh tab populated with one buffer per unstaged file (no splits to manage).
- Highlights additions (`DiffAdd`) and deletions (`DiffDelete`) using standard diff syntax; new files show the entire file as additions, deleted files show the full removed contents.
- When toggled off, diff buffers are closed but files remain open in the editor.
- Stage the current file directly from the diff buffer with `<leader>aga` (configurable).
- Switch to a whole-file diff view (headers stripped) with `<leader>agf`.
- Manual refresh via `:GitDiffViewerRefresh` or `<leader>agr`.

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
  keymap = "<leader>agt",   -- set to false to skip default toggle mapping
  open_in_tab = true,       -- open diffs in their own tab page
  accept_keymap = "<leader>aga", -- buffer-local mapping to stage the file
  refresh_keymap = "<leader>agr", -- global mapping to refresh the view
  full_file_keymap = "<leader>agf", -- buffer-local mapping to show whole-file diff
  full_file_context = 100000, -- line context for whole-file diff rendering
  diff_cmd = { "git", "diff", "--no-color" },
  status_cmd = { "git", "status", "--porcelain" },
})
```

## Usage

- Press `<leader>agt` (or `:GitDiffViewerToggle`) to show diffs for unstaged changes on your current branch. A new tab opens with one diff buffer per unstaged file (each buffer named after the file).
- While focused on a diff buffer, press `<leader>aga` to stage the file and refresh the view.
- Press `<leader>agr` (or `:GitDiffViewerRefresh`) anytime to re-render the diffs after external changes.
- Press `<leader>agf` inside a diff buffer to swap into a whole-file diff (without the `diff --git`/`index` headers) for easier reading.
- Use `<leader>agt` (or `:GitDiffViewerToggle`) again to hide the diff view. The diff tab is closed, but file buffers remain open in the editor.

## Notes

- The plugin only lists files with unstaged modifications (including untracked files). Stage or discard changes to remove them from the view.
- `open_in_tab = false` keeps the diffs in the current tab if you prefer a simpler layout.
- When hiding the diff view, the diff tab is closed but all file buffers remain available in your buffer list for easy access.

## Roadmap

- Detect staged-only changes.
- Optionally show the working tree version side-by-side.
- Allow custom diff renderers (Tree-sitter, mini.diff, etc.).
