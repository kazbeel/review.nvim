local hooks = require("review.hooks")
local storage = require("review.storage")
local store = require("review.store")
local config = require("review.config")

local ns_id = vim.api.nvim_create_namespace("review")

local sample_rel = "tests/fixtures/plain/sample.lua"
local other_rel = "tests/fixtures/plain/other.lua"

local function open_fixture(rel_path)
  local abs = vim.fn.fnamemodify(rel_path, ":p")
  local bufnr
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == abs then
      bufnr = b
      break
    end
  end
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, abs)
    local lines = {}
    for line in io.lines(abs) do
      table.insert(lines, line)
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

describe("plain review", function()
  before_each(function()
    store.clear()
    storage.clear_plain_session()
    storage.clear_revisions()
    hooks.clear_current_file()
    config.setup()
  end)

  after_each(function()
    hooks.clear_current_file()
    storage.clear_revisions()
    -- Remove the plain session storage file regardless of session state
    storage.set_plain_session()
    storage.clear()
    storage.clear_plain_session()
    store.reset()
    require("review.marks").clear_all()
    require("review.keymaps").clear_keymaps()
    require("review.winbar").clear()
    vim.wo[0].winbar = ""
  end)

  describe("hooks.get_cursor_position", function()
    it("returns repo-relative file, cursor line and plain side for session buffer", function()
      local bufnr = open_fixture(sample_rel)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      hooks.set_current_file(vim.fn.fnamemodify(sample_rel, ":p"), bufnr)

      local file, line, side = hooks.get_cursor_position()

      assert.equals(sample_rel, file)
      assert.equals(3, line)
      assert.equals("plain", side)
    end)

    it("returns nil for a buffer outside the plain session", function()
      open_fixture(sample_rel)
      local outsider = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(outsider, "not_in_session.lua")
      vim.api.nvim_set_current_buf(outsider)
      hooks.set_current_file(vim.fn.fnamemodify(sample_rel, ":p"), 1)

      local file, line, side = hooks.get_cursor_position()

      assert.is_nil(file)
      assert.is_nil(line)
      assert.is_nil(side)
      vim.api.nvim_buf_delete(outsider, { force = true })
    end)
  end)

  describe("init.open_file", function()
    local review = require("review")

    it("opens the file readonly with plain review keymaps and session state", function()
      review.open_file(sample_rel)

      local bufnr = vim.api.nvim_get_current_buf()
      assert.equals(vim.fn.fnamemodify(sample_rel, ":p"), vim.api.nvim_buf_get_name(bufnr))
      assert.is_false(vim.bo[bufnr].modifiable)
      assert.is_true(vim.bo[bufnr].readonly)
      assert.is_true(hooks.has_plain_session())
      assert.truthy(storage.get_storage_path():match("%-plain%.json$"))

      local lhs = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        lhs[m.lhs] = true
      end
      assert.truthy(lhs["i"], "add keymap present")
      assert.truthy(lhs["e"], "edit keymap present")
      assert.truthy(lhs["d"], "delete keymap present")
      assert.truthy(lhs["]n"], "next comment keymap present")
      assert.truthy(lhs["[n"], "prev comment keymap present")
      assert.truthy(lhs["q"], "close keymap present")
      assert.truthy(lhs["c"], "list keymap present")
      assert.truthy(lhs["C"], "export keymap present")
    end)

    it("skips codediff-dependent file navigation keymaps", function()
      review.open_file(sample_rel)

      local lhs = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do
        lhs[m.lhs] = true
      end
      assert.is_nil(lhs["<Tab>"], "next_file not mapped")
      assert.is_nil(lhs["<S-Tab>"], "prev_file not mapped")
      assert.is_nil(lhs["f"], "toggle_file_panel not mapped")
    end)

    it("notifies an error and stays out of review mode for a missing file", function()
      local orig_notify = vim.notify
      local notified
      vim.notify = function(msg, level)
        notified = { msg = msg, level = level }
      end

      local ok = pcall(review.open_file, "tests/fixtures/plain/does_not_exist.lua")

      vim.notify = orig_notify
      assert.is_true(ok)
      assert.is_not_nil(notified)
      assert.equals(vim.log.levels.ERROR, notified.level)
      assert.matches("File not found", notified.msg)
      assert.is_false(hooks.has_plain_session())
    end)
  end)

  describe("comment flow", function()
    local review = require("review")
    local comments = require("review.comments")
    local popup = require("review.popup")

    it("adds a plain-side comment at the cursor and renders the comment box", function()
      review.open_file(sample_rel)
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      local orig_open = popup.open
      popup.open = function(_, _, on_submit)
        on_submit("issue", "Missing error handling")
      end

      comments.add_at_cursor()

      popup.open = orig_open

      local comment = store.get_at_line(sample_rel, 3, "plain")
      assert.is_not_nil(comment)
      assert.equals("issue", comment.type)
      assert.equals("Missing error handling", comment.text)

      local rendered = vim.wait(1000, function()
        return #vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {}) >= 1
      end)
      assert.is_true(rendered)
      local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
      assert.equals(2, extmarks[1][2])
      assert.is_not_nil(extmarks[1][4].virt_lines)
    end)
  end)

  describe("session lifecycle", function()
    local review = require("review")
    local export = require("review.export")
    local popup = require("review.popup")

    local function add_comment_at(ctype, text)
      local orig_open = popup.open
      popup.open = function(_, _, on_submit)
        on_submit(ctype, text)
      end
      require("review.comments").add_at_cursor()
      popup.open = orig_open
    end

    it("a second file joins the active session and comments co-export", function()
      review.open_file(sample_rel)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      add_comment_at("issue", "Sample issue")

      review.open_file(other_rel)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      add_comment_at("note", "Other note")

      assert.is_not_nil(store.get_at_line(sample_rel, 2, "plain"))
      assert.is_not_nil(store.get_at_line(other_rel, 2, "plain"))

      local md = export.generate_markdown()
      assert.matches("tests/fixtures/plain/sample.lua:2", md)
      assert.matches("tests/fixtures/plain/other.lua:2", md)
    end)

    it("close exports all session comments to clipboard and ends the session", function()
      review.open_file(sample_rel)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      add_comment_at("issue", "Sample issue")

      review.close()

      assert.matches("tests/fixtures/plain/sample.lua:2", vim.fn.getreg("+"))
      assert.is_false(hooks.has_plain_session())
      assert.is_nil(storage.get_storage_path():match("%-plain%.json$"))
    end)

    it("comments persist and reload when the file is reopened", function()
      review.open_file(sample_rel)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      add_comment_at("suggestion", "Rename value")

      review.close()

      review.open_file(sample_rel)

      local comment = store.get_at_line(sample_rel, 3, "plain")
      assert.is_not_nil(comment)
      assert.equals("Rename value", comment.text)
    end)
  end)

  describe("init.open_buffer", function()
    local review = require("review")

    it("activates review mode on the current buffer", function()
      local bufnr = open_fixture(other_rel)

      review.open_buffer()

      assert.equals(bufnr, vim.api.nvim_get_current_buf())
      assert.is_true(hooks.has_plain_session())
      assert.is_true(vim.bo[bufnr].readonly)

      local lhs = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        lhs[m.lhs] = true
      end
      assert.truthy(lhs["i"])
      assert.truthy(lhs["e"])
      assert.truthy(lhs["d"])
      assert.truthy(lhs["q"])
    end)

    it("notifies an error for a buffer with no file", function()
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(scratch)

      local orig_notify = vim.notify
      local notified
      vim.notify = function(msg, level)
        notified = { msg = msg, level = level }
      end
      review.open_buffer()
      vim.notify = orig_notify

      assert.is_not_nil(notified)
      assert.equals(vim.log.levels.ERROR, notified.level)
      assert.is_false(hooks.has_plain_session())
      vim.api.nvim_buf_delete(scratch, { force = true })
    end)
  end)

  describe(":Review command router", function()
    it("Review file <path> dispatches to a plain review session", function()
      vim.cmd("runtime plugin/review.lua")
      vim.cmd("Review file tests/fixtures/plain/sample.lua")

      assert.equals(
        vim.fn.fnamemodify(sample_rel, ":p"),
        vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
      )
      assert.is_true(hooks.has_plain_session())
    end)

    it("Review buffer dispatches on the current buffer", function()
      vim.cmd("runtime plugin/review.lua")
      open_fixture(other_rel)

      vim.cmd("Review buffer")

      assert.is_true(hooks.has_plain_session())
      assert.is_true(vim.bo[vim.api.nvim_get_current_buf()].readonly)
    end)

    it("Review file without an argument falls back to the current buffer", function()
      vim.cmd("runtime plugin/review.lua")
      open_fixture(other_rel)
      local bufnr = vim.api.nvim_get_current_buf()

      vim.cmd("Review file")

      assert.is_true(hooks.has_plain_session())
      assert.equals(bufnr, vim.api.nvim_get_current_buf())
    end)
  end)

  describe("winbar session indicator", function()
    local review = require("review")

    it("shows the review marker in the winbar while a session is active", function()
      review.open_file(sample_rel)

      assert.matches("● Review", vim.wo[0].winbar)
    end)

    it("restores the previous winbar value when the session closes", function()
      vim.wo[0].winbar = "MY STATUSLINE"
      review.open_file(sample_rel)
      assert.matches("● Review", vim.wo[0].winbar)

      review.close()

      assert.equals("MY STATUSLINE", vim.wo[0].winbar)
    end)

    it("restores an empty winbar to inherit from the global value", function()
      vim.wo[0].winbar = ""
      review.open_file(sample_rel)

      review.close()

      assert.equals("", vim.wo[0].winbar)
    end)

    it("leaves the winbar untouched when disabled in config", function()
      config.setup({ plain = { winbar = false } })
      vim.wo[0].winbar = "MY STATUSLINE"

      review.open_file(sample_rel)

      assert.equals("MY STATUSLINE", vim.wo[0].winbar)
    end)

    it("re-applies the marker when returning to a session buffer", function()
      review.open_file(sample_rel)
      local session_buf = vim.api.nvim_get_current_buf()
      vim.wo[0].winbar = ""

      local outsider = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(outsider, "winbar_clobber.lua")
      vim.cmd("buffer " .. outsider)
      assert.not_equals(session_buf, vim.api.nvim_get_current_buf())
      vim.cmd("buffer " .. session_buf)

      assert.matches("● Review", vim.wo[0].winbar)
      vim.api.nvim_buf_delete(outsider, { force = true })
    end)
  end)

  describe("toggle_readonly", function()
    local review = require("review")

    local function normal_lhs(bufnr)
      local lhs = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        lhs[m.lhs] = true
      end
      return lhs
    end

    it("switches plain buffers between readonly and edit mode with matching keymaps", function()
      review.open_file(sample_rel)
      local bufnr = vim.api.nvim_get_current_buf()
      assert.is_true(vim.bo[bufnr].readonly)
      assert.truthy(normal_lhs(bufnr)["i"])

      review.toggle_readonly()

      assert.is_false(vim.bo[bufnr].readonly)
      assert.is_true(vim.bo[bufnr].modifiable)
      local edit_lhs = normal_lhs(bufnr)
      assert.is_nil(edit_lhs["i"], "readonly add keymap removed")
      local has_edit_add = vim.iter(vim.tbl_keys(edit_lhs)):any(function(k)
        return k:find("cc", 1, true)
      end)
      assert.is_true(has_edit_add, "edit-mode add keymap present (leader-expanded)")

      review.toggle_readonly()

      assert.is_true(vim.bo[bufnr].readonly)
      assert.truthy(normal_lhs(bufnr)["i"], "readonly-mode add keymap restored")
    end)

    it("reflects edit mode in the winbar marker", function()
      review.open_file(sample_rel)
      assert.not_matches("%(edit%)", vim.wo[0].winbar)

      review.toggle_readonly()

      assert.matches("● Review %(edit%)", vim.wo[0].winbar)

      review.toggle_readonly()

      assert.not_matches("%(edit%)", vim.wo[0].winbar)
    end)
  end)
end)
