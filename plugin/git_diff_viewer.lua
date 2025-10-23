if vim.g.loaded_git_diff_viewer then
  return
end
vim.g.loaded_git_diff_viewer = true

require("git_diff_viewer").setup()
