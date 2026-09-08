local picker = require("review.picker")
local t = picker._test

local commits = {
  { hash = "hash1", short_hash = "h1", author = "Author One", date = "1 hour ago", message = "Commit one" },
  { hash = "hash2", short_hash = "h2", author = "Author Two", date = "2 hours ago", message = "Commit two" },
  { hash = "hash3", short_hash = "h3", author = "Author Three", date = "3 hours ago", message = "Commit three" },
  { hash = "hash4", short_hash = "h4", author = "Author Four", date = "4 hours ago", message = "Commit four" },
  { hash = "hash5", short_hash = "h5", author = "Author Five", date = "5 hours ago", message = "Commit five" },
}

describe("review.picker selection", function()
  describe("press_space", function()
    it("first press on row 5 selects rows 1..5", function()
      local sel = t.press_space(nil, 5, commits)
      assert.same({ from = 1, to = 5 }, sel)
    end)

    it("press on a row without a commit is a no-op", function()
      local sel = t.press_space({ from = 1, to = 2 }, 99, commits)
      assert.same({ from = 1, to = 2 }, sel)
    end)

    it("press on row 3 after selecting 1..5 shrinks to 1..3", function()
      local sel = t.press_space({ from = 1, to = 5 }, 3, commits)
      assert.same({ from = 1, to = 3 }, sel)
    end)

    it("double press on row 5 keeps rows 1..5 selected", function()
      local once = t.press_space(nil, 5, commits)
      local twice = t.press_space(once, 5, commits)
      assert.same({ from = 1, to = 5 }, twice)
    end)

    it("press on row 2 after reset selects rows 1..2", function()
      local reset = nil
      local sel = t.press_space(reset, 2, commits)
      assert.same({ from = 1, to = 2 }, sel)
    end)
  end)

  describe("confirm_revisions", function()
    it("selection 1..5 confirms oldest parent to newest", function()
      local rev1, rev2 = t.confirm_revisions({ from = 1, to = 5 }, 1, commits)
      assert.equals("hash5^", rev1)
      assert.equals("hash1", rev2)
    end)

    it("no selection with cursor on row 3 confirms that commit alone", function()
      local rev1, rev2 = t.confirm_revisions(nil, 3, commits)
      assert.equals("hash3^", rev1)
      assert.equals("hash3", rev2)
    end)

    it("no selection with cursor beyond the list confirms nothing", function()
      local rev1, rev2 = t.confirm_revisions(nil, 99, commits)
      assert.is_nil(rev1)
      assert.is_nil(rev2)
    end)
  end)

  describe("format_line", function()
    local function has_hl(hl, group)
      for _, h in ipairs(hl) do
        if h[1] == group then
          return true
        end
      end
      return false
    end

    it("marks boundary rows inside selection 1..3", function()
      for _, row in ipairs({ 1, 3 }) do
        local line, hl = t.format_line(row, commits[row], { from = 1, to = 3 })
        assert.equals("[x]", line:sub(1, 3))
        assert.is_true(has_hl(hl, "ReviewPickerSelected"))
      end
    end)

    it("unmarks rows outside the selection", function()
      local line, hl = t.format_line(4, commits[4], { from = 1, to = 3 })
      assert.equals("[ ]", line:sub(1, 3))
      assert.is_false(has_hl(hl, "ReviewPickerSelected"))
    end)

    it("unmarks all rows when nothing is selected", function()
      local line, hl = t.format_line(2, commits[2], nil)
      assert.equals("[ ]", line:sub(1, 3))
      assert.is_false(has_hl(hl, "ReviewPickerSelected"))
    end)
  end)
end)
