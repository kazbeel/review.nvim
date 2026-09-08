local M = {}

local config = require("review.config")
local highlights = require("review.highlights")
local hooks = require("review.hooks")
local keymaps = require("review.keymaps")
local storage = require("review.storage")
local store = require("review.store")
local export = require("review.export")
local comments = require("review.comments")

local initialized = false
local augroup = nil

---@param opts? ReviewConfig
function M.setup(opts)
  if initialized then
    return
  end

  config.setup(opts)
  highlights.setup()

  -- Set up autocmd to detect CodeDiff sessions
  augroup = vim.api.nvim_create_augroup("review", { clear = true })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    callback = function()
      vim.defer_fn(function()
        M._check_codediff_session()
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      hooks.on_session_closed()
    end,
  })

  -- Re-setup hooks when codediff recreates buffers (e.g. layout toggle)
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = { "CodeDiffOpen", "CodeDiffFileSelect" },
    callback = function()
      vim.defer_fn(function()
        M._check_codediff_session()
      end, 100)
    end,
  })

  initialized = true
end

-- Check if current tab is a CodeDiff session and set up hooks/keymaps
function M._check_codediff_session()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local sess = lifecycle.get_session(tabpage)
  if not sess then
    return
  end

  -- Set up hooks
  hooks.on_session_created(tabpage)

  -- Set up keymaps (uses codediff's set_tab_keymap internally)
  keymaps.setup_keymaps(tabpage)
end

local function open_codediff_with_revisions(rev1, rev2)
  local ok, _ = pcall(require, "codediff")
  if not ok then
    vim.notify("codediff.nvim is required", vim.log.levels.ERROR, { title = "review.nvim" })
    return
  end

  -- A diff review ends any active plain session (storage key must switch)
  hooks.clear_current_file()
  storage.clear_plain_session()
  require("review.winbar").clear()

  -- Scope storage to revision range for commit reviews
  if rev1 and rev2 then
    storage.set_revisions(rev1, rev2)
  else
    storage.clear_revisions()
  end

  -- Load persisted comments (reset first so we load from the new storage path)
  store.reset()
  store.load()

  -- Open CodeDiff
  if rev1 and rev2 then
    vim.cmd("CodeDiff " .. rev1 .. " " .. rev2)
  else
    vim.cmd("CodeDiff")
  end

  -- Wait for CodeDiff to initialize, then set up our hooks
  local attempts = 0
  local max_attempts = 5
  local function try_setup()
    attempts = attempts + 1
    local lifecycle_ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
    if lifecycle_ok then
      local tabpage = vim.api.nvim_get_current_tabpage()
      local sess = lifecycle.get_session(tabpage)
      if sess then
        M._check_codediff_session()
        return
      end
    end
    if attempts < max_attempts then
      vim.defer_fn(try_setup, 100)
    end
  end
  vim.defer_fn(try_setup, 200)
end

function M.open()
  open_codediff_with_revisions(nil, nil)
end

function M.open_commits(rev1, rev2)
  if rev1 then
    open_codediff_with_revisions(rev2 and rev1 or (rev1 .. "^"), rev2 or rev1)
    return
  end
  local picker = require("review.picker")
  picker.open(function(r1, r2)
    open_codediff_with_revisions(r1, r2)
  end)
end

local function open_plain_review(abs, bufnr)
  -- Start a new plain session, or join the active one (comments accumulate)
  if not hooks.has_plain_session() then
    storage.clear_revisions()
    storage.set_plain_session()
    store.reset()
    store.load()
  end

  hooks.set_current_file(abs, bufnr)

  local cfg = config.get()
  if cfg.codediff.readonly then
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
    vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
  end

  keymaps.setup_plain_keymaps(bufnr)
  if not cfg.plain or cfg.plain.winbar ~= false then
    local winbar = require("review.winbar")
    winbar.start()
    winbar.apply(vim.api.nvim_get_current_win())
  end
  require("review.marks").refresh()
end

---Find an existing buffer for the given absolute path
---@param abs string
---@return number|nil bufnr
local function find_buffer_for(abs)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == abs then
      return b
    end
  end
  return nil
end

---Open a source file in plain (no-diff) review mode
---@param path? string file path; defaults to the current buffer
function M.open_file(path)
  if not path or path == "" then
    return M.open_buffer()
  end

  local abs = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(abs) == 0 then
    vim.notify("File not found: " .. path, vim.log.levels.ERROR, { title = "review.nvim" })
    return
  end

  local bufnr = find_buffer_for(abs)
  if bufnr then
    vim.api.nvim_set_current_buf(bufnr)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
    bufnr = vim.api.nvim_get_current_buf()
  end

  open_plain_review(abs, bufnr)
end

---Open the current buffer in plain (no-diff) review mode
function M.open_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then
    vim.notify("Current buffer is not tied to a file", vim.log.levels.ERROR, { title = "review.nvim" })
    return
  end

  open_plain_review(vim.fn.fnamemodify(name, ":p"), bufnr)
end

function M.close()
  -- Export comments to clipboard before closing
  local count = store.count()
  if count > 0 then
    local markdown = export.generate_markdown()
    pcall(vim.fn.setreg, "+", markdown)
    pcall(vim.fn.setreg, "*", markdown)
    vim.notify(string.format("Exported %d comment(s) to clipboard", count), vim.log.levels.INFO, { title = "review.nvim" })
  end

  -- Plain review session: close session buffers and end the session
  if hooks.has_plain_session() then
    local session_bufs = vim.tbl_keys(hooks.get_plain_buffers())
    hooks.clear_current_file()
    storage.clear_plain_session()
    require("review.keymaps").cleanup()
    require("review.marks").clear_all()
    require("review.winbar").clear()
    for _, bufnr in ipairs(session_bufs) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.cmd, "bdelete " .. bufnr)
      end
    end
    return
  end

  -- Close the tab
  vim.cmd("tabclose")
  hooks.on_session_closed()
  storage.clear_revisions()
end

function M.export()
  export.to_clipboard()
end

function M.preview()
  export.preview()
end

function M.clear()
  store.clear()
  require("review.marks").clear_all()
  vim.notify("All comments cleared", vim.log.levels.INFO, { title = "review.nvim" })
end

function M.count()
  return store.count()
end

function M.add_note()
  comments.add_at_cursor("note")
end

function M.add_suggestion()
  comments.add_at_cursor("suggestion")
end

function M.add_issue()
  comments.add_at_cursor("issue")
end

function M.add_praise()
  comments.add_at_cursor("praise")
end

function M.toggle_readonly()
  local cfg = config.get()
  cfg.codediff.readonly = not cfg.codediff.readonly

  -- Plain review session: toggle the session buffers directly
  if hooks.has_plain_session() then
    for bufnr in pairs(hooks.get_plain_buffers()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_set_option_value("modifiable", not cfg.codediff.readonly, { buf = bufnr })
        vim.api.nvim_set_option_value("readonly", cfg.codediff.readonly, { buf = bufnr })
        keymaps.setup_plain_keymaps(bufnr)
      end
    end
    require("review.winbar").refresh()

    local mode = cfg.codediff.readonly and "readonly" or "edit"
    vim.notify("Switched to " .. mode .. " mode", vim.log.levels.INFO, { title = "review.nvim" })
    return
  end

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local tabpage = hooks.get_current_tabpage()
  if not tabpage then
    return
  end

  -- Update buffer readonly state (tracked so close restores prior values)
  hooks.set_session_readonly(tabpage, cfg.codediff.readonly)

  -- Re-setup keymaps with new readonly state
  keymaps.clear_keymaps()
  keymaps.setup_keymaps(tabpage)

  local mode = cfg.codediff.readonly and "readonly" or "edit"
  vim.notify("Switched to " .. mode .. " mode", vim.log.levels.INFO, { title = "review.nvim" })
end

return M
