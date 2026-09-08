local M = {}

---@class Commit
---@field hash string
---@field short_hash string
---@field message string
---@field author string
---@field date string

---@type Commit[]
local commits = {}
---@type number|nil
local range_start = nil
---@type number|nil
local range_end = nil
---@type any
local popup = nil

local function get_git_root()
  local result = vim.fn.systemlist("git rev-parse --show-toplevel")
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result[1]
end

local function fetch_commits(limit)
  limit = limit or 50
  local git_root = get_git_root()
  if not git_root then
    return {}
  end

  -- Format: hash|short_hash|author|relative_date|subject
  local format = "%H|%h|%an|%cr|%s"
  local cmd = string.format("git -C %s log --format='%s' -n %d", vim.fn.shellescape(git_root), format, limit)
  local result = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 then
    return {}
  end

  local parsed = {}
  for _, line in ipairs(result) do
    local parts = vim.split(line, "|", { plain = true })
    if #parts >= 5 then
      table.insert(parsed, {
        hash = parts[1],
        short_hash = parts[2],
        author = parts[3],
        date = parts[4],
        message = table.concat({ unpack(parts, 5) }, "|"), -- message may contain |
      })
    end
  end

  return parsed
end

local ns_id = nil

local function current_selection()
  if range_start and range_end then
    return { from = range_start, to = range_end }
  end
  return nil
end

--- Compute the selection resulting from a `<Space>` press at row `idx`.
--- Row 1 is the newest commit, so the selection is always the prefix 1..idx.
local function press_space(selection, idx, commit_list)
  if not commit_list[idx] then
    return selection
  end
  return { from = 1, to = idx }
end

--- Map the selection (or cursor fallback) to codediff revisions.
--- Returns `oldest.hash .. "^", newest.hash`, or nil, nil when nothing to review.
local function confirm_revisions(selection, cursor_idx, commit_list)
  local lo, hi

  if selection then
    lo = math.min(selection.from, selection.to)
    hi = math.max(selection.from, selection.to)
  elseif commit_list[cursor_idx] then
    lo = cursor_idx
    hi = cursor_idx
  end

  if not lo then
    return nil, nil
  end

  -- Git log returns newest first, so lower index = newer commit
  local newest = commit_list[lo]
  local oldest = commit_list[hi]
  return oldest.hash .. "^", newest.hash
end

local function is_in_range(idx, selection)
  if not selection then
    return false
  end
  local lo = math.min(selection.from, selection.to)
  local hi = math.max(selection.from, selection.to)
  return idx >= lo and idx <= hi
end

local function format_line(idx, commit, selection)
  local in_range = is_in_range(idx, selection)
  local marker = in_range and "[x]" or "[ ]"
  local hash = commit.short_hash
  local meta = string.format("(%s, %s)", commit.author, commit.date)
  local line = string.format("%s %s %s %s", marker, hash, commit.message, meta)

  local marker_len = #marker
  local hash_start = marker_len + 1
  local hash_end = hash_start + #hash
  local meta_start = #line - #meta

  if #line > 120 then
    line = line:sub(1, 117) .. "..."
  end

  local line_len = #line
  local hl = {}

  if in_range then
    table.insert(hl, { "ReviewPickerSelected", 0, math.min(marker_len, line_len) })
  end
  if hash_start < line_len then
    table.insert(hl, { "ReviewPickerHash", hash_start, math.min(hash_end, line_len) })
  end
  if meta_start < line_len then
    table.insert(hl, { "ReviewPickerMeta", meta_start, line_len })
  end

  return line, hl
end

local function apply_line_hl(buf, row, highlights)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns_id, row, hl[2], {
      end_col = hl[3],
      hl_group = hl[1],
      priority = 200,
    })
  end
end

local function render_lines()
  if not popup then
    return
  end

  local buf = popup.bufnr
  local lines = {}
  local line_data = {}
  local selection = current_selection()

  for i, commit in ipairs(commits) do
    local line, hl = format_line(i, commit, selection)
    table.insert(lines, line)
    table.insert(line_data, { hl = hl })
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  ns_id = vim.api.nvim_create_namespace("review_picker")
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
  for i, data in ipairs(line_data) do
    apply_line_hl(buf, i - 1, data.hl)
  end
end

local function select_range()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local idx = cursor[1]
  local sel = press_space(current_selection(), idx, commits)
  if not sel then
    return
  end
  range_start = sel.from
  range_end = sel.to
  render_lines()
end

local function select_none()
  range_start = nil
  range_end = nil
  render_lines()
end

local function close_picker()
  if popup then
    popup:unmount()
    popup = nil
  end
  commits = {}
  range_start = nil
  range_end = nil
end

local function confirm_selection(callback)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local rev1, rev2 = confirm_revisions(current_selection(), cursor[1], commits)
  close_picker()
  callback(rev1, rev2)
end

function M.open(callback)
  local git_root = get_git_root()
  if not git_root then
    vim.notify("Not in a git repository", vim.log.levels.ERROR, { title = "review.nvim" })
    return
  end

  commits = fetch_commits(50)
  range_start = nil
  range_end = nil

  if #commits == 0 then
    vim.notify("No commits found", vim.log.levels.WARN, { title = "review.nvim" })
    return
  end

  local width = math.min(120, vim.o.columns - 10)
  local height = math.min(20, #commits + 2, vim.o.lines - 10)

  local Popup = require("nui.popup")
  popup = Popup({
    position = "50%",
    size = {
      width = width,
      height = height,
    },
    border = {
      style = "rounded",
      text = {
        top = " Select commits to review ",
        top_align = "center",
        bottom = " <Space> select newest to cursor | r reset | <CR> confirm | q quit ",
        bottom_align = "center",
      },
    },
    buf_options = {
      modifiable = false,
      buftype = "nofile",
    },
    win_options = {
      cursorline = true,
      cursorlineopt = "line",
    },
  })

  popup:mount()
  render_lines()

  -- Focus the popup window and lock cursor to column 2 (middle of [ ])
  vim.api.nvim_set_current_win(popup.winid)
  vim.api.nvim_win_set_cursor(popup.winid, { 1, 1 })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = popup.bufnr,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      vim.api.nvim_win_set_cursor(0, { row, 1 })
    end,
  })

  -- Keymaps using nui's map method
  local map_opts = { noremap = true, nowait = true }
  popup:map("n", "<Space>", select_range, map_opts)
  popup:map("n", "<CR>", function() confirm_selection(callback) end, map_opts)
  popup:map("n", "q", close_picker, map_opts)
  popup:map("n", "<Esc>", close_picker, map_opts)
  popup:map("n", "r", select_none, map_opts)
end

M._test = {
  press_space = press_space,
  confirm_revisions = confirm_revisions,
  is_in_range = is_in_range,
  format_line = format_line,
}

return M
