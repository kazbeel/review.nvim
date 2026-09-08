local M = {}

local config = require("review.config")
local hooks = require("review.hooks")

---@type table<number, string> winid -> previous window-local winbar value
local saved_winbars = {}

---@type number|nil Autocmd group re-applying the marker on BufEnter
local augroup = nil

---Build the marker text for the current readonly/edit state
---@return string
local function marker_text()
  local readonly = config.get().codediff.readonly
  return "%#ReviewWinbar#● Review" .. (readonly and "" or " (edit)")
end

---Apply (or update) the review marker on a window
---@param win number winid
function M.apply(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not saved_winbars[win] then
    saved_winbars[win] = vim.wo[win].winbar
  end
  vim.wo[win].winbar = marker_text()
end

---Re-apply the marker on all windows currently showing a session buffer
function M.refresh()
  if not hooks.has_plain_session() then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local win_config = vim.api.nvim_win_get_config(win)
      if not (win_config.relative and win_config.relative ~= "") then
        local bufnr = vim.api.nvim_win_get_buf(win)
        if hooks.get_plain_buffers()[bufnr] then
          M.apply(win)
        end
      end
    end
  end
end

---Start tracking BufEnter so the marker follows session buffers into new windows
function M.start()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("review_plain_winbar", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function()
      local cfg = config.get()
      if not cfg.plain or cfg.plain.winbar == false then
        return
      end
      if not hooks.get_plain_buffers()[vim.api.nvim_get_current_buf()] then
        return
      end
      local win_config = vim.api.nvim_win_get_config(0)
      if win_config.relative and win_config.relative ~= "" then
        return
      end
      M.apply(vim.api.nvim_get_current_win())
    end,
  })
end

---Restore previous winbar values and stop tracking
function M.clear()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  for win, prev in pairs(saved_winbars) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winbar = prev
    end
  end
  saved_winbars = {}
end

return M
