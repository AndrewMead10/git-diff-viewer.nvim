local uv = vim.uv or vim.loop

local M = {}

local defaults = {
  enable_on_start = true,
  keymap = "<leader>agt",
  watch_interval = 750,
  git_lock_retry_delay = 100,
  git_lock_max_attempts = 50,
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
  enabled = false,
  watchers = {},
  diff_tab = nil,
  diff_bufs = {},
  buf_entries = {},
  prev_buffers = {},
  last_head = {},
  pending_refresh = {},
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

local function head_path(root)
  return root and (root .. "/.git/HEAD") or nil
end

local function read_file(path)
  if not path then
    return nil
  end
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data and data:gsub("\n$", "") or nil
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
    log(msg, vim.log.levels.ERROR)
    return false
  end
  log(string.format("staged %s", relative_path))
  return true
end

local function close_diff_tab()
  for _, buf in ipairs(state.diff_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    state.buf_entries[buf] = nil
  end
  state.diff_bufs = {}
  state.buf_entries = {}
  if state.diff_tab and vim.api.nvim_tabpage_is_valid(state.diff_tab) then
    vim.api.nvim_set_current_tabpage(state.diff_tab)
    vim.cmd("tabclose")
  end
  state.diff_tab = nil
end

local function restore_prev_buffers()
  if vim.tbl_isempty(state.prev_buffers) then
    return
  end
  local current_tab = vim.api.nvim_get_current_tabpage()
  local reopened = false
  for _, path in ipairs(state.prev_buffers) do
    if vim.loop.fs_stat(path) then
      if not reopened then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        reopened = true
      else
        vim.cmd("badd " .. vim.fn.fnameescape(path))
      end
    end
  end
  state.prev_buffers = {}
  if not reopened then
    vim.api.nvim_set_current_tabpage(current_tab)
  end
end

local function collect_and_close_listed_bufs()
  local collected = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        table.insert(collected, name)
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state.prev_buffers = collected
end

local function git_lock_exists(root)
  if not root then
    return false
  end
  local git_dir = vim.fs.joinpath(root, ".git")
  if not uv.fs_stat(git_dir) then
    return false
  end
  local lock_paths = {
    vim.fs.joinpath(git_dir, "index.lock"),
    vim.fs.joinpath(git_dir, "HEAD.lock"),
  }
  for _, lock in ipairs(lock_paths) do
    if uv.fs_stat(lock) then
      return true
    end
  end
  return false
end

local function wait_for_git_idle(root, config, attempt)
  attempt = attempt or 0
  if not state.enabled then
    state.pending_refresh[root] = nil
    return
  end
  if git_lock_exists(root) then
    local max_attempts = config.git_lock_max_attempts or defaults.git_lock_max_attempts
    if attempt >= max_attempts then
      log(string.format("git repository busy (lock present after %d checks); skipping refresh", attempt), vim.log.levels.WARN)
      state.pending_refresh[root] = nil
      return
    end
    local delay = config.git_lock_retry_delay or defaults.git_lock_retry_delay
    vim.defer_fn(function()
      wait_for_git_idle(root, config, attempt + 1)
    end, delay)
    return
  end
  state.pending_refresh[root] = nil
  handle_branch_switch(root, config)
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
    log(string.format("failed to diff %s (%d)", relative_path, code or -1), vim.log.levels.WARN)
    if raw then
      log(table.concat(raw, "\n"), vim.log.levels.DEBUG)
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
        log("not inside a git repository", vim.log.levels.WARN)
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
        log("not inside a git repository", vim.log.levels.WARN)
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

local function open_diff_buffers(root, files, config)
  close_diff_tab()
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
end

local function handle_branch_switch(root, config)
  if not state.enabled then
    return
  end
  collect_and_close_listed_bufs()
  local status, err = system_list(config.status_cmd, root)
  if not status then
    log("unable to read git status: " .. (err or ""), vim.log.levels.ERROR)
    return
  end
  local files = parse_status(status)
  open_diff_buffers(root, files, config)
end

local function on_head_change(root, config)
  if state.pending_refresh[root] then
    return
  end
  state.pending_refresh[root] = true
  vim.schedule(function()
    wait_for_git_idle(root, config, 0)
  end)
end

local function watch_head(root, config)
  if state.watchers[root] then
    return
  end
  local head = head_path(root)
  if not head or not uv.fs_stat(head) then
    return
  end
  local watcher = uv.new_fs_poll()
  if not watcher then
    log("unable to create fs poll watcher", vim.log.levels.ERROR)
    return
  end
  local last = read_file(head)
  state.last_head[root] = last
  watcher:start(head, config.watch_interval, function(_, _)
    local current = read_file(head)
    if current and current ~= state.last_head[root] then
      state.last_head[root] = current
      on_head_change(root, config)
    end
  end)
  state.watchers[root] = watcher
end

local function stop_watches()
  for root, watcher in pairs(state.watchers) do
    watcher:stop()
    watcher:close()
    state.watchers[root] = nil
    state.last_head[root] = nil
  end
  state.pending_refresh = {}
end

local function ensure_watch(config)
  local root = detect_root()
  if not root then
    return
  end
  watch_head(root, config)
end

function M.enable()
  if state.enabled then
    return
  end
  state.enabled = true
  ensure_watch(M.config)
  log("enabled")
end

function M.disable()
  if not state.enabled then
    return
  end
  state.enabled = false
  stop_watches()
  close_diff_tab()
  restore_prev_buffers()
  log("disabled")
end

function M.toggle()
  if state.enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.refresh()
  local root = detect_root()
  if not root then
    log("not inside a git repository", vim.log.levels.WARN)
    return
  end
  handle_branch_switch(root, M.config)
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

  vim.api.nvim_create_autocmd("DirChanged", {
    callback = function()
      if state.enabled then
        ensure_watch(M.config)
      end
    end,
  })

  if M.config.enable_on_start then
    M.enable()
  end
end

return M
