local uv = vim.uv or vim.loop

local M = {}

local defaults = {
  keymap = "<leader>agt",
  open_in_tab = true,
  accept_keymap = "<leader>aga",
  refresh_keymap = "<leader>agr",
  full_file_keymap = "<leader>agf",
  full_file_context = 100000,
  diff_cmd = { "git", "diff", "--no-color" },
  status_cmd = { "git", "status", "--porcelain" },
  highlight_deletions = "DiffDelete",
  highlight_additions = "DiffAdd",
}

local state = {
  diff_visible = false,
  diff_tab = nil,
  diff_bufs = {},
  buf_entries = {},
}

local function log(msg, level)
  level = level or vim.log.levels.INFO
  vim.notify(string.format("git-diff-viewer: %s", msg), level)
end

local function merge_tables(user, base)
  if not user then
    return vim.deepcopy(base)
  end
  return vim.tbl_deep_extend("force", vim.deepcopy(base), user)
end

local function detect_root(start_dir)
  local dir = start_dir or vim.loop.cwd() or vim.fn.getcwd()
  local git_dir = vim.fs.find(".git", { upward = true, path = dir, type = "directory" })[1]
  if not git_dir then
    return nil
  end
  return vim.fs.dirname(git_dir)
end

local function with_git_cwd(cmd, cwd)
  if cwd and cmd[1] == "git" then
    local copy = vim.deepcopy(cmd)
    table.insert(copy, 2, "-C")
    table.insert(copy, 3, cwd)
    return copy
  end
  return cmd
end

local function system_list(cmd, cwd)
  local normalized = with_git_cwd(cmd, cwd)
  local output = vim.fn.systemlist(normalized)
  local code = vim.v.shell_error
  if code ~= 0 then
    return nil, code, output
  end
  return output, code
end

local function read_worktree_file(root, relative_path)
  if not root or not relative_path or relative_path == "" then
    return nil
  end
  local absolute = vim.fs.joinpath(root, relative_path)
  if uv.fs_stat(absolute) then
    return vim.fn.readfile(absolute)
  end
  return nil
end

local function read_git_blob(root, relative_path)
  if not relative_path or relative_path == "" then
    return nil
  end
  local spec = string.format("HEAD:%s", relative_path)
  local lines = select(1, system_list({ "git", "show", spec }, root))
  return lines
end

local function strip_diff_headers(lines)
  local filtered = {}
  for _, line in ipairs(lines) do
    local skip = line:match("^diff %-%-git%s")
        or line:match("^index%s")
        or line:match("^%-%-%-")
        or line:match("^%+%+%+")
        or line:match("^new file mode")
        or line:match("^deleted file mode")
        or line:match("^@@")
    if not skip then
      table.insert(filtered, line)
    end
  end
  return filtered
end

local function stage_path(root, relative_path)
  if not root then
    return false
  end
  local output, code, stderr_output = system_list({ "git", "add", "--", relative_path }, root)
  if not output and code ~= 0 then
    local msg = string.format("failed to stage %s", relative_path)
    if stderr_output and #stderr_output > 0 then
      msg = msg .. ": " .. table.concat(stderr_output, "\\n")
    end
    print(string.format("git-diff-viewer: %s", msg))
    return false
  end
  log(string.format("staged %s", relative_path))
  return true
end

local function hide_diff_view()
  -- Clear diff buffer tracking but don't delete the buffers
  -- This allows the files to remain open in the editor
  state.diff_bufs = {}
  state.buf_entries = {}

  -- Close the diff tab if it exists and is valid
  if state.diff_tab and vim.api.nvim_tabpage_is_valid(state.diff_tab) then
    local diff_tab = state.diff_tab
    state.diff_tab = nil

    -- Switch away from the diff tab before closing it
    local tabs = vim.api.nvim_list_tabpages()
    for _, tab in ipairs(tabs) do
      if tab ~= diff_tab then
        vim.api.nvim_set_current_tabpage(tab)
        break
      end
    end

    -- Close the diff tab
    pcall(function()
      vim.api.nvim_set_current_tabpage(diff_tab)
      vim.cmd("tabclose")
    end)
  end

  state.diff_visible = false
end


local function parse_status(lines)
  local results = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      local staged = line:sub(1, 1)
      local unstaged = line:sub(2, 2)
      local path = vim.trim(line:sub(4))
      if path:find(" -> ", 1, true) then
        local _, new_path = path:match("(.+)%s->%s(.+)")
        if new_path and new_path ~= "" then
          path = new_path
        end
      end
      if unstaged ~= " " or staged == "?" then
        local kind = "modified"
        if staged == "?" and unstaged == "?" then
          kind = "new"
        elseif unstaged == "D" then
          kind = "deleted"
        end
        table.insert(results, { path = path, kind = kind })
      end
    end
  end
  return results
end

local function build_new_file_diff(root, relative_path, opts)
  local lines = read_worktree_file(root, relative_path)
  if not lines then
    return {
      string.format("diff --git a/%s b/%s", relative_path, relative_path),
      string.format("new file %s missing from working tree", relative_path),
    }
  end
  local count = #lines
  local header
  if count > 0 then
    header = string.format("@@ -0,0 +1,%d @@", count)
  else
    header = "@@ -0,0 +0,0 @@"
  end
  local diff_lines = {
    string.format("diff --git a/%s b/%s", relative_path, relative_path),
    string.format("new file mode 100644"),
    "--- /dev/null",
    string.format("+++ b/%s", relative_path),
    header,
  }
  for _, line in ipairs(lines) do
    table.insert(diff_lines, "+" .. line)
  end
  if opts and opts.full then
    diff_lines = strip_diff_headers(diff_lines)
  end
  return diff_lines
end

local function build_deleted_file_diff(root, relative_path, opts)
  local lines = read_git_blob(root, relative_path)
  if not lines then
    return {
      string.format("diff --git a/%s b/%s", relative_path, relative_path),
      string.format("--- a/%s", relative_path),
      string.format("+++ /dev/null"),
      string.format("@@ -0,0 +0,0 @@"),
      string.format("-unable to read deleted file %s", relative_path),
    }
  end
  local count = #lines
  local header
  if count > 0 then
    header = string.format("@@ -1,%d +0,0 @@", count)
  else
    header = "@@ -0,0 +0,0 @@"
  end
  local diff_lines = {
    string.format("diff --git a/%s b/%s", relative_path, relative_path),
    string.format("deleted file mode 100644"),
    string.format("--- a/%s", relative_path),
    "+++ /dev/null",
    header,
  }
  for _, line in ipairs(lines) do
    table.insert(diff_lines, "-" .. line)
  end
  if opts and opts.full then
    diff_lines = strip_diff_headers(diff_lines)
  end
  return diff_lines
end

local function build_modified_diff(root, relative_path, config, opts)
  local cmd = vim.deepcopy(config.diff_cmd)
  if opts and opts.full then
    table.insert(cmd, string.format("--unified=%d", config.full_file_context or 100000))
  end
  table.insert(cmd, "--")
  table.insert(cmd, relative_path)
  local output, code, raw = system_list(cmd, root)
  if not output then
    print(string.format("git-diff-viewer: failed to diff %s (%d)", relative_path, code or -1))
    if raw then
      print(string.format("git-diff-viewer: %s", table.concat(raw, "\n")))
    end
    return nil
  end
  if vim.tbl_isempty(output) then
    output = { string.format("No diff for %s", relative_path) }
  end
  if opts and opts.full then
    output = strip_diff_headers(output)
  end
  return output
end

local function build_diff_lines(root, entry, config, opts)
  local diff_lines
  if entry.kind == "new" then
    diff_lines = build_new_file_diff(root, entry.path, opts)
  elseif entry.kind == "deleted" then
    diff_lines = build_deleted_file_diff(root, entry.path, opts)
  else
    diff_lines = build_modified_diff(root, entry.path, config, opts)
  end
  return diff_lines
end

local function build_diff_buffer(root, entry, config, opts)
  local diff_lines = build_diff_lines(root, entry, config, opts)
  if not diff_lines then
    return nil
  end

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, entry.path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines)
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = true

  state.buf_entries[buf] = { path = entry.path, kind = entry.kind, full = opts and opts.full or false }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      state.buf_entries[buf] = nil
    end,
  })

  if config.accept_keymap then
    local repo_root = root
    vim.keymap.set("n", config.accept_keymap, function()
      if not repo_root then
        print("git-diff-viewer: not inside a git repository")
        return
      end
      if stage_path(repo_root, entry.path) then
        M.refresh()
      end
    end, { buffer = buf, desc = "Stage file with git diff viewer" })
  end

  if config.full_file_keymap then
    local repo_root = root
    vim.keymap.set("n", config.full_file_keymap, function()
      if not repo_root then
        print("git-diff-viewer: not inside a git repository")
        return
      end
      local current_entry = state.buf_entries[buf]
      if not current_entry then
        return
      end
      current_entry.full = not current_entry.full
      local lines = build_diff_lines(repo_root, current_entry, M.config, { full = current_entry.full })
      if not lines then
        return
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
    end, { buffer = buf, desc = "Show full diff (git diff viewer)" })
  end

  return buf
end

local function show_diff_view(root, files, config)
  if config.open_in_tab then
    vim.cmd("tabnew")
    state.diff_tab = vim.api.nvim_get_current_tabpage()
  else
    vim.cmd("enew")
  end

  if vim.tbl_isempty(files) then
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No unstaged changes." })
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    state.diff_visible = true
    return
  end

  local first = true
  for _, entry in ipairs(files) do
    local buf = build_diff_buffer(root, entry, config)
    if buf then
      if first then
        vim.api.nvim_win_set_buf(0, buf)
        first = false
      else
        vim.fn.bufload(buf)
      end
      table.insert(state.diff_bufs, buf)
    end
  end
  if state.diff_tab and vim.api.nvim_tabpage_is_valid(state.diff_tab) and not vim.tbl_isempty(state.diff_bufs) then
    vim.api.nvim_set_current_buf(state.diff_bufs[1])
  end
  state.diff_visible = true
end

function M.toggle()
  if state.diff_visible then
    hide_diff_view()
    log("diff view hidden")
  else
    local root = detect_root()
    if not root then
      print("git-diff-viewer: not inside a git repository")
      return
    end
    local status, err = system_list(M.config.status_cmd, root)
    if not status then
      print(string.format("git-diff-viewer: unable to read git status: %s", err or ""))
      return
    end
    local files = parse_status(status)
    show_diff_view(root, files, M.config)
    log("diff view shown")
  end
end

function M.refresh()
  if not state.diff_visible then
    print("git-diff-viewer: diff view is not visible. Use toggle to show it first.")
    return
  end

  local root = detect_root()
  if not root then
    print("git-diff-viewer: not inside a git repository")
    return
  end

  -- Hide the current diff view
  hide_diff_view()

  -- Show a new one
  local status, err = system_list(M.config.status_cmd, root)
  if not status then
    print(string.format("git-diff-viewer: unable to read git status: %s", err or ""))
    return
  end
  local files = parse_status(status)
  show_diff_view(root, files, M.config)
  log("diff view refreshed")
end

function M.setup(opts)
  M.config = merge_tables(opts, defaults)
  if M.config.keymap then
    vim.keymap.set("n", M.config.keymap, M.toggle, { desc = "Toggle git diff viewer" })
  end

  vim.api.nvim_create_user_command("GitDiffViewerToggle", function()
    M.toggle()
  end, { desc = "Toggle git diff viewer" })

  vim.api.nvim_create_user_command("GitDiffViewerRefresh", function()
    M.refresh()
  end, { desc = "Manually refresh git diff viewer" })

  if M.config.refresh_keymap then
    vim.keymap.set("n", M.config.refresh_keymap, function()
      M.refresh()
    end, { desc = "Refresh git diff viewer" })
  end
end

return M
