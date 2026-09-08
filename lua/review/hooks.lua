local M = {}

local marks = require("review.marks")
local config = require("review.config")
local normalize_path = require("review.utils").normalize_path

---@type number|nil Current tabpage with active codediff session
local current_tabpage = nil

---@type table<number, string> bufnr -> absolute path of buffers in the plain (no-diff) review session
local plain_buffers = {}

---@type number|nil Autocmd group for buffer events
local buf_augroup = nil

---@type table<number, {modifiable: boolean, readonly: boolean}> Pre-review option values per tracked buffer
local readonly_saved = {}

---@type {original: number|nil, modified: number|nil} Last pair review readonly was applied to
local session_pair = { original = nil, modified = nil }

---@type table<number, {modifiable: boolean, readonly: boolean}> Pre-review option values per plain-session buffer
local plain_saved = {}

---Record a buffer's current options and apply review readonly state
---@param bufnr number
local function apply_readonly_tracked(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if readonly_saved[bufnr] == nil then
    readonly_saved[bufnr] = {
      modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr }),
      readonly = vim.api.nvim_get_option_value("readonly", { buf = bufnr }),
    }
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
end

---Restore a buffer's recorded pre-review options and stop tracking it
---@param bufnr number
local function restore_buffer_state(bufnr)
  local saved = readonly_saved[bufnr]
  readonly_saved[bufnr] = nil
  if saved and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_set_option_value(
      "modifiable",
      saved.modifiable,
      { buf = bufnr }
    )
    vim.api.nvim_set_option_value("readonly", saved.readonly, { buf = bufnr })
  end
end

---Register a buffer as part of the plain review session.
---Records the buffer's pre-review options (once) and applies the configured
---review readonly state.
---@param abs_path string absolute file path
---@param bufnr number
function M.set_current_file(abs_path, bufnr)
  plain_buffers[bufnr] = abs_path
  if
    vim.api.nvim_buf_is_valid(bufnr)
    and plain_saved[bufnr] == nil
  then
    plain_saved[bufnr] = {
      modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr }),
      readonly = vim.api.nvim_get_option_value("readonly", { buf = bufnr }),
    }
  end

  local readonly = config.get().codediff.readonly
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_set_option_value("modifiable", not readonly, { buf = bufnr })
    vim.api.nvim_set_option_value("readonly", readonly, { buf = bufnr })
  end
end

---End the plain review session: restore each session buffer's pre-review
---options and release them from the session
function M.clear_current_file()
  for bufnr in pairs(plain_buffers) do
    local saved = plain_saved[bufnr]
    if saved and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_set_option_value("modifiable", saved.modifiable, { buf = bufnr })
      vim.api.nvim_set_option_value("readonly", saved.readonly, { buf = bufnr })
    end
  end
  plain_saved = {}
  plain_buffers = {}
end

---@return boolean true when a plain review session is active
function M.has_plain_session()
  return next(plain_buffers) ~= nil
end

---@return table<number, string> bufnr -> absolute path mapping
function M.get_plain_buffers()
  return plain_buffers
end

---@return string|nil git root from the current working directory
local function get_git_root()
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result and result ~= "" then
      return result:gsub("%s+$", "")
    end
  end
  return nil
end

---Relativize a plain-session path against the git root (or cwd outside a repo)
---@param path string
---@return string
local function relativize_plain(path)
  local root = get_git_root()
  if root then
    local abs = vim.fn.fnamemodify(path, ":p")
    return normalize_path(abs:gsub("^" .. vim.pesc(root) .. "/", ""))
  end
  return normalize_path(vim.fn.fnamemodify(path, ":."))
end

---Public wrapper for plain-session path relativization (used by marks rendering)
---@param path string
---@return string
function M.relativize_plain_path(path)
  return relativize_plain(path)
end

---Set filetype for a buffer based on file path
---@param bufnr number
---@param path string|nil
local function set_buffer_filetype(bufnr, path)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not path or path == "" then
    return
  end

  -- Use Neovim's built-in filetype detection
  local ft = vim.filetype.match({ filename = path, buf = bufnr })
  if ft then
    vim.api.nvim_set_option_value("filetype", ft, { buf = bufnr })
  end
end

---@return number|nil tabpage id
function M.get_current_tabpage()
  return current_tabpage
end

---@return table|nil codediff lifecycle module
local function get_lifecycle()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return nil
  end
  return lifecycle
end

---@return table|nil codediff session
function M.get_session()
  if not current_tabpage then
    return nil
  end
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return nil
  end
  return lifecycle.get_session(current_tabpage)
end

---Coerce a path value to a plain string.
---@param path string|table|nil
---@return string|nil
local function to_path_string(path)
  if type(path) ~= "table" then
    return path
  end
  if path.absolute and path.absolute ~= "" then
    return path.absolute
  end
  return path.relative
end

---Relativize a path against the git root for consistent storage/lookup
---@param path string|table|nil
---@param lifecycle table
---@param tabpage number
---@return string|nil
local function relativize_path(path, lifecycle, tabpage)
  path = to_path_string(path)
  if not path then
    return nil
  end
  local git_ctx = lifecycle.get_git_context(tabpage)
  if git_ctx and git_ctx.git_root then
    local abs = vim.fn.fnamemodify(path, ":p")
    return normalize_path(
      abs:gsub("^" .. vim.pesc(git_ctx.git_root) .. "/", "")
    )
  end
  return normalize_path(vim.fn.fnamemodify(path, ":."))
end

---@return string|nil file path
---@return number|nil line number
---@return "old"|"new"|"plain"|nil side
function M.get_cursor_position()
  -- Plain review session: resolve file and line from the tracked buffer
  if not current_tabpage then
    local plain_path = plain_buffers[vim.api.nvim_get_current_buf()]
    if plain_path then
      local cursor = vim.api.nvim_win_get_cursor(0)
      return relativize_plain(plain_path), cursor[1], "plain"
    end
  end

  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil, nil
  end

  local sess = lifecycle.get_session(current_tabpage)
  if not sess then
    return nil, nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_buf = vim.api.nvim_get_current_buf()

  -- Get paths from session
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  local orig_buf, mod_buf = lifecycle.get_buffers(current_tabpage)

  -- Determine which file we're on based on buffer
  local file_path
  local side
  if current_buf == orig_buf then
    file_path = orig_path
    side = "old"
  elseif current_buf == mod_buf then
    file_path = mod_path
    side = "new"
  else
    -- Try to get path from buffer name
    local bufname = vim.api.nvim_buf_get_name(current_buf)
    if bufname and bufname ~= "" then
      -- Strip codediff:// prefix if present
      if bufname:match("^codediff://") then
        file_path = mod_path or orig_path
      else
        file_path = vim.fn.fnamemodify(bufname, ":.")
      end
    end
  end

  if not file_path then
    return nil, nil, nil
  end

  return relativize_path(file_path, lifecycle, current_tabpage), cursor[1], side
end

---@return string|nil file path
---@return number|nil start line
---@return number|nil end line
---@return "old"|"new"|nil side
function M.get_visual_range()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local file, _, side = M.get_cursor_position()
  if not file then
    return nil, nil, nil, nil
  end

  return file, start_line, end_line, side
end

---@return number|nil original buffer
---@return number|nil modified buffer
function M.get_buffers()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  return lifecycle.get_buffers(current_tabpage)
end

---@return string|nil original path
---@return string|nil modified path
function M.get_paths()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  return relativize_path(orig_path, lifecycle, current_tabpage),
    relativize_path(mod_path, lifecycle, current_tabpage)
end

---Apply review readonly to the session's buffers (recording prior option
---values on first touch) or apply edit-mode values
---@param tabpage number
---@param enabled boolean readonly mode
function M.set_session_readonly(tabpage, enabled)
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end
  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)

  if enabled then
    apply_readonly_tracked(orig_buf)
    apply_readonly_tracked(mod_buf)
    session_pair = { original = orig_buf, modified = mod_buf }
  else
    if orig_buf and vim.api.nvim_buf_is_valid(orig_buf) then
      vim.api.nvim_set_option_value("modifiable", true, { buf = orig_buf })
      vim.api.nvim_set_option_value("readonly", false, { buf = orig_buf })
    end
    if mod_buf and vim.api.nvim_buf_is_valid(mod_buf) then
      vim.api.nvim_set_option_value("modifiable", true, { buf = mod_buf })
      vim.api.nvim_set_option_value("readonly", false, { buf = mod_buf })
    end
  end
end

-- Called when codediff session is created
function M.on_session_created(tabpage)
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)

  -- Set filetype for syntax highlighting (needed for commit reviews)
  local raw_orig_path, raw_mod_path = lifecycle.get_paths(tabpage)
  set_buffer_filetype(orig_buf, to_path_string(raw_orig_path))
  set_buffer_filetype(mod_buf, to_path_string(raw_mod_path))

  -- Restore buffers that left the session's pair (file navigation, layout
  -- toggle) before applying readonly to the new pair
  local prev = session_pair
  if
    prev.original
    and prev.original ~= orig_buf
    and prev.original ~= mod_buf
  then
    restore_buffer_state(prev.original)
  end
  if
    prev.modified
    and prev.modified ~= orig_buf
    and prev.modified ~= mod_buf
  then
    restore_buffer_state(prev.modified)
  end
  session_pair = { original = nil, modified = nil }

  -- Make buffers readonly if configured
  local cfg = config.get()
  if cfg.codediff.readonly then
    M.set_session_readonly(tabpage, true)
  end

  -- Clear old autocmds
  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
  end
  buf_augroup =
    vim.api.nvim_create_augroup("review_buf_marks", { clear = true })

  -- Set up BufEnter autocmd to render marks when entering codediff buffers
  -- This ensures marks are rendered even if buffers weren't ready initially
  vim.api.nvim_create_autocmd("BufEnter", {
    group = buf_augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= current_tabpage then
        return
      end
      local bufnr = vim.api.nvim_get_current_buf()
      local ob, mb = lifecycle.get_buffers(current_tabpage)
      if bufnr ~= ob and bufnr ~= mb then
        return
      end
      marks.refresh()
    end,
  })

  -- Initial render with delay for buffers to be ready
  vim.defer_fn(function()
    marks.refresh()
  end, 100)

  -- Focus the modified (right) pane
  vim.defer_fn(function()
    M._focus_modified_pane(lifecycle, tabpage)
  end, 150)
end

function M._focus_modified_pane(lifecycle, tabpage)
  local cur_cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
  if cur_cfg.relative ~= "" then
    return
  end
  local sess = lifecycle.get_session(tabpage)
  if
    sess
    and sess.modified_win
    and vim.api.nvim_win_is_valid(sess.modified_win)
  then
    vim.api.nvim_set_current_win(sess.modified_win)
  end
end

-- Called when codediff session is closed
function M.on_session_closed()
  -- Only restore when the tracked session's tabpage is gone; TabClosed fires
  -- for unrelated tabs too
  local session_gone = current_tabpage == nil
    or not vim.api.nvim_tabpage_is_valid(current_tabpage)
  if session_gone then
    for bufnr in pairs(readonly_saved) do
      restore_buffer_state(bufnr)
    end
    session_pair = { original = nil, modified = nil }
  end
  current_tabpage = nil
  -- Clean up autocmds
  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
    buf_augroup = nil
  end
  require("review.keymaps").cleanup()
end

-- Called when file changes in explorer mode
function M.on_file_changed(tabpage)
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  -- Re-render comments
  vim.defer_fn(function()
    marks.refresh()
  end, 50)
end

return M
