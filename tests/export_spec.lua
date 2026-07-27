local store = require("review.store")
local export = require("review.export")

describe("review.export", function()
  before_each(function()
    store.clear()
  end)

  describe("generate_markdown", function()
    it("returns empty message when no comments", function()
      local md = export.generate_markdown()
      assert.matches("No comments yet", md)
    end)

    it("includes file and comment in output", function()
      store.add("src/main.lua", 10, "issue", "Fix this bug")

      local md = export.generate_markdown()
      assert.matches("src/main.lua:10", md)
      assert.matches("%[ISSUE%]", md)
      assert.matches("Fix this bug", md)
    end)

    it("formats comments as numbered list", function()
      store.add("a.lua", 1, "note", "Note A")
      store.add("b.lua", 1, "issue", "Issue B")
      store.add("a.lua", 5, "suggestion", "Suggestion A")

      local md = export.generate_markdown()
      assert.matches("1%. %*%*%[NOTE%]%*%*", md)
      assert.matches("2%. %*%*%[SUGGESTION%]%*%*", md)
      assert.matches("3%. %*%*%[ISSUE%]%*%*", md)
    end)

    it("uses tilde notation for old-side comments", function()
      store.add("src/main.lua", 10, "issue", "Removed bug", nil, "old")

      local md = export.generate_markdown()
      assert.matches("src/main.lua:~10", md)
    end)

    it("uses tilde on both ends for old-side range", function()
      store.add("src/main.lua", 10, "issue", "Old range", 15, "old")

      local md = export.generate_markdown()
      assert.matches("src/main.lua:~10%-~15", md)
    end)

    it("uses normal notation for new-side comments", function()
      store.add("src/main.lua", 10, "issue", "New side", nil, "new")

      local md = export.generate_markdown()
      assert.matches("src/main.lua:10", md)
      assert.not_matches("~10", md)
    end)
  end)

  describe("to_avante", function()
    local asked, saved_avante

    before_each(function()
      asked = nil
      -- Inject a fake avante.api module
      saved_avante = package.loaded["avante.api"]
      package.loaded["avante.api"] = {
        ask = function(opts) asked = opts end,
      }
    end)

    after_each(function()
      package.loaded["avante.api"] = saved_avante
    end)

    it("does nothing when no comments", function()
      export.to_avante()
      assert.is_nil(asked)
    end)

    it("sends generated markdown as question to avante", function()
      store.add("src/main.lua", 10, "issue", "Fix this bug")

      export.to_avante()

      assert.is_not_nil(asked)
      assert.matches("src/main.lua:10", asked.question)
      assert.matches("%[ISSUE%]", asked.question)
    end)
  end)
end)
