local hooks = require("review.hooks")
local config = require("review.config")

-- Fake codediff.ui.lifecycle (external dependency) serving a configurable
-- buffer pair for the tracked tabpage.
local fake = { orig_buf = nil, mod_buf = nil }

local original_lifecycle = package.loaded["codediff.ui.lifecycle"]

local function install_fake_lifecycle()
  package.loaded["codediff.ui.lifecycle"] = {
    get_buffers = function()
      return fake.orig_buf, fake.mod_buf
    end,
    get_session = function()
      return { modified_win = nil }
    end,
    get_paths = function()
      return nil, nil
    end,
    get_git_context = function()
      return nil
    end,
  }
end

local function buf_opt(bufnr, name)
  return vim.api.nvim_get_option_value(name, { buf = bufnr })
end

describe("readonly state restore", function()
  before_each(function()
    config.setup()
    install_fake_lifecycle()
  end)

  after_each(function()
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose!")
    end
    hooks.on_session_closed()
    config.setup()
    package.loaded["codediff.ui.lifecycle"] = original_lifecycle
    for _, bufnr in ipairs({ fake.orig_buf, fake.mod_buf }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    fake.orig_buf = nil
    fake.mod_buf = nil
  end)

  it("restores a modifiable buffer when the review session closes", function()
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    hooks.on_session_created(tabpage)

    assert.is_false(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_true(buf_opt(fake.orig_buf, "readonly"))
    assert.is_false(buf_opt(fake.mod_buf, "modifiable"))
    assert.is_true(buf_opt(fake.mod_buf, "readonly"))

    vim.cmd("tabclose")
    hooks.on_session_closed()

    assert.is_true(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_false(buf_opt(fake.orig_buf, "readonly"))
    assert.is_true(buf_opt(fake.mod_buf, "modifiable"))
    assert.is_false(buf_opt(fake.mod_buf, "readonly"))
  end)

  it("keeps a buffer unmodifiable after close if it was unmodifiable before the review", function()
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("modifiable", false, { buf = fake.orig_buf })
    vim.api.nvim_set_option_value("readonly", true, { buf = fake.orig_buf })

    vim.cmd("tabnew")
    hooks.on_session_created(vim.api.nvim_get_current_tabpage())
    vim.cmd("tabclose")
    hooks.on_session_closed()

    assert.is_false(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_true(buf_opt(fake.orig_buf, "readonly"))
  end)

  it("keeps buffers readonly when an unrelated tab closes while the review is open", function()
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    hooks.on_session_created(tabpage)

    -- Unrelated tab closes (e.g. user closes another tabpage): TabClosed
    -- fires on_session_closed while the review tabpage is still valid
    vim.cmd("tabnew")
    vim.cmd("tabclose")
    hooks.on_session_closed()

    assert.is_false(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_true(buf_opt(fake.orig_buf, "readonly"))

    -- Closing the review tabpage afterwards still restores
    vim.api.nvim_set_current_tabpage(tabpage)
    vim.cmd("tabclose")
    hooks.on_session_closed()

    assert.is_true(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_false(buf_opt(fake.orig_buf, "readonly"))
  end)

  it("skips a deleted tracked buffer at close and still restores the others", function()
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd("tabnew")
    hooks.on_session_created(vim.api.nvim_get_current_tabpage())

    -- Virtual codediff buffers are deleted before the close hook runs
    vim.api.nvim_buf_delete(fake.mod_buf, { force = true })

    vim.cmd("tabclose")
    hooks.on_session_closed()

    assert.is_true(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_false(buf_opt(fake.orig_buf, "readonly"))
  end)

  it("restores buffers that leave the session pair on file switch and tracks the new pair", function()
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)
    local prev_orig, prev_mod = fake.orig_buf, fake.mod_buf

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    hooks.on_session_created(tabpage)

    -- Navigate to another file: codediff serves a new buffer pair
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)
    hooks.on_session_created(tabpage)

    assert.is_true(buf_opt(prev_orig, "modifiable"))
    assert.is_false(buf_opt(prev_orig, "readonly"))
    assert.is_true(buf_opt(prev_mod, "modifiable"))
    assert.is_false(buf_opt(prev_mod, "readonly"))
    assert.is_false(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_true(buf_opt(fake.orig_buf, "readonly"))

    vim.cmd("tabclose")
    hooks.on_session_closed()

    assert.is_true(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_false(buf_opt(fake.orig_buf, "readonly"))
  end)

  it("leaves both files at their pre-review state after navigating away and back", function()
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)
    local file_a_orig, file_a_mod = fake.orig_buf, fake.mod_buf

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    hooks.on_session_created(tabpage)

    -- Switch to file B, then back to file A
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)
    local file_b_orig, file_b_mod = fake.orig_buf, fake.mod_buf
    hooks.on_session_created(tabpage)

    fake.orig_buf, fake.mod_buf = file_a_orig, file_a_mod
    hooks.on_session_created(tabpage)

    vim.cmd("tabclose")
    hooks.on_session_closed()

    for _, bufnr in ipairs({ file_a_orig, file_a_mod, file_b_orig, file_b_mod }) do
      assert.is_true(buf_opt(bufnr, "modifiable"))
      assert.is_false(buf_opt(bufnr, "readonly"))
    end
  end)

  it("records prior state when toggling an edit-mode session to readonly", function()
    config.setup({ codediff = { readonly = false } })
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd("tabnew")
    hooks.on_session_created(vim.api.nvim_get_current_tabpage())

    -- Edit-mode session leaves options untouched
    assert.is_true(buf_opt(fake.orig_buf, "modifiable"))

    local review = require("review")
    review.toggle_readonly()

    assert.is_false(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_true(buf_opt(fake.orig_buf, "readonly"))
    assert.is_false(buf_opt(fake.mod_buf, "modifiable"))
    assert.is_true(buf_opt(fake.mod_buf, "readonly"))

    vim.cmd("tabclose")
    hooks.on_session_closed()

    assert.is_true(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_false(buf_opt(fake.orig_buf, "readonly"))
    assert.is_true(buf_opt(fake.mod_buf, "modifiable"))
    assert.is_false(buf_opt(fake.mod_buf, "readonly"))
  end)

  it("does not overwrite recorded state when on_session_created re-runs for the same pair", function()
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    hooks.on_session_created(tabpage)

    -- Tab re-entry / CodeDiffOpen re-trigger for the same buffers
    hooks.on_session_created(tabpage)

    vim.cmd("tabclose")
    hooks.on_session_closed()

    assert.is_true(buf_opt(fake.orig_buf, "modifiable"))
    assert.is_false(buf_opt(fake.orig_buf, "readonly"))
    assert.is_true(buf_opt(fake.mod_buf, "modifiable"))
    assert.is_false(buf_opt(fake.mod_buf, "readonly"))
  end)

  it("restores pre-review state after toggle off then on mid-session", function()
    fake.orig_buf = vim.api.nvim_create_buf(false, true)
    fake.mod_buf = vim.api.nvim_create_buf(false, true)

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    hooks.on_session_created(tabpage)

    -- Buffer is now nomodifiable
    assert.is_false(buf_opt(fake.orig_buf, "modifiable"))

    local review = require("review")
    review.toggle_readonly()  -- toggle off
    assert.is_true(buf_opt(fake.orig_buf, "modifiable"))

    review.toggle_readonly()  -- toggle back on
    assert.is_false(buf_opt(fake.orig_buf, "modifiable"))

    vim.cmd("tabclose")
    hooks.on_session_closed()

    assert.is_true(buf_opt(fake.orig_buf, "modifiable"))
  end)
end)
